# herdr Zig rewrite - PORTING guide

## Summary

Mechanical translation rules from herdr's Rust to Zig 0.15.2, one rule per recurring construct, grounded in a three-agent inventory of all of `src/` (~189k lines, 91+77+ remaining files).
The port preserves architecture, module layout, and names 1:1; idiomatic Zig comes later.
Rules are ordered by translator priority, which follows the codebase's actual shape: threads carry the transport and PTY IO (~40 `std::thread::spawn` sites), while the TUI app loop, the input-dispatch layer, the pane runtime, and the server loop are async (`.await` ×146, hottest in `app/mod.rs` ×37, `pane.rs` ×25, `app/input/*` ×40+; `tokio::select!` loops ×5).
Channels are mpsc plus one watch; oneshot and broadcast are unused.
Both halves need first-class rules: the blocking-thread model AND the de-async of the select loops.

Ground truth for Zig 0.15.2 style: the vendored `vendor/libghostty-vt/src` tree - when in doubt, imitate it.

## Details

### 0. Priority order for translator rules

1. Threads + blocking queues (transport and PTY backbone).
2. De-async of the app/input/pane/server layer: the 5 `select!` loops become poll/timer/wake loops (or libxev, per ticket #7); `async fn` bodies become plain calls.
3. bincode-standard encoding + u32-LE framing (byte-exact wire compat, highest risk).
4. Option/Result/match/collections (the bulk of every file).
5. Atomics with explicit orderings (×150).
6. Per-OS syscall shims (libc, windows-sys).
7. Compat layers: ratatui-shaped renderer, crossterm-shaped key model + terminal lifecycle, tracing shim.

### 1. Concurrency

| Rust | Zig 0.15.2 | Notes |
|---|---|---|
| `std::thread::spawn(move \|\| ...)` (~40 sites) | `std.Thread.spawn(.{}, worker, .{args})` | captured state becomes an explicit context struct |
| `tokio::sync::mpsc` bounded/unbounded (backbone; oneshot/broadcast = 0) | in-house `Channel(T)`: mutex + condvar + ring buffer, with `send`/`trySend`/`recv`/`tryRecv` | must expose BOTH blocking ends (`blocking_send`/`blocking_recv` bridge, e.g. `client_transport.rs:560`) and a pollable end for the event loop |
| `tokio::sync::watch` (×1: PTY resize channel, `pane.rs:951`, `watch::channel` at `pane.rs:2793`) | single-slot latest-value cell: mutex + condvar + generation counter, `store` overwrites, `waitNewer(gen)` returns the newest value | watch coalesces intermediate values - do NOT map it to the mpsc `Channel(T)`, resize must observe only the latest size |
| `std::sync::mpsc` (pty control) | same `Channel(T)` | two channel systems in Rust collapse to one |
| `Arc<Mutex<T>>` (×10 Mutex, ×56 Arc) | single owner + `std.Thread.Mutex` guarding the field; `*T` handles for sharers | per OWNERSHIP.tsv; refcount only where lifetime is genuinely dynamic |
| `Arc<AtomicBool>` (×90) | `std.atomic.Value(bool)` field, shared by pointer | |
| `Ordering::Relaxed/Acquire/Release/AcqRel` (×60 explicit) | `.monotonic` / `.acquire` / `.release` / `.acq_rel` on `@atomicLoad`/`@atomicStore`/`fetchAdd` | translate orderings verbatim, never "upgrade" to seq_cst |
| `tokio::sync::Notify` (×6, render wakeup) | `std.Thread.ResetEvent` (or eventfd/pipe wake integrated with the poll loop) | the render-notify path must wake the select loop, so it becomes a wake-pipe write once the loop is poll-based |
| `rt.block_on(async {...})` (5 runtimes, always sync entry) | plain function call into the event-loop `run()` | the runtime object disappears |
| `tokio::select!` (5 loops: `app/mod.rs:1085` main app loop, `server/headless.rs:671`, `pane.rs:606`, `pane.rs:2022`, `client/mod.rs:1369`) | explicit loop over `poll(2)` (or libxev, ticket #7): socket fds + wake pipe + earliest-deadline timer | each `select!` arm becomes a readiness dispatch case; preserve arm priority and cancellation semantics; the app and pane loops are as load-bearing as the server loop |
| `tokio::time::sleep_until` in loops | deadline arithmetic feeding the poll timeout | |
| `async fn` bodies (×231 in the UI slice alone - `app/mod.rs`, `app/input/*`, `pane.rs`, `app/runtime.rs`, `pty/actor`, api layer, `headless.rs`) | ordinary functions called from the dispatch cases | mechanical de-async: no suspension points survive except the 5 loops themselves; every awaited channel op becomes a blocking or polled call |
| `tokio::spawn` (live: `pane.rs:580,1984`; `spawn_blocking`/`task::spawn` in the pty layer; further `spawn` hits are test-only abort-handle placeholders) | `std.Thread.spawn` or a job enqueued on the owning loop | classify each site: fire-and-forget thread vs loop-owned job |
| `OnceLock` (×11) | comptime const where possible, else a `std.once`-guarded global | |

### 2. Option and Result

`Option<T>` (×815) → `?T`.
Combinator table - laziness must be preserved exactly (Bun's `unwrap_or` bug class, mirrored):

| Rust | Zig |
|---|---|
| `opt.map(f)` | `if (opt) \|v\| f(v) else null` |
| `opt.and_then(f)` | `if (opt) \|v\| f(v) else null` (f returns optional) |
| `opt.unwrap_or(x)` — **eager arg** | `opt orelse x` (safe: Zig's `orelse` operand is lazy, but if the Rust arg had side effects, hoist it BEFORE the `orelse` to keep eager evaluation) |
| `opt.unwrap_or_else(f)` — **lazy** | `opt orelse f()` |
| `opt.unwrap_or_default()` | `opt orelse .{}` / zero value |
| `opt.ok_or(e)?` | `opt orelse return error.E` |
| `opt.take()` | `blk: { const v = opt; opt = null; break :blk v; }` |
| `opt.is_some()` / `is_none()` | `opt != null` / `opt == null` |
| `let Some(x) = o else { return ... }` (×571) | `const x = o orelse return ...;` |
| `.as_ref()/.as_deref()/.cloned()` (×698) | usually vanish: Zig optionals of slices/pointers need no ref-shuffling; clone only where the Rust `.cloned()` produced an owned value that outlives the source |

`Result<T, E>` (×657, `?` ×1067 across slices) → `E!T` error unions.

| Rust | Zig |
|---|---|
| `f()?` | `try f()` |
| `return Err(MyError::X)` | `return error.X` |
| `.map_err(\|e\| io::Error::other(e.to_string()))` (×139, stringify pattern) | `f() catch \|err\| return error.Y` plus a diagnostic sink for the message (error unions carry no payload; use an out-param `*Diagnostics` where the string is actually consumed) |
| hand-written error enums (~4, e.g. `FramingError`) + `From<io::Error>` | named `error{...}` sets; `From` impls vanish (error sets merge structurally) |
| `fn main() -> io::Result<()>` + `process::exit(0/1/2)` | `pub fn main() !void` + `std.process.exit(code)` |

Panics: production code has no `unwrap()` (herdr convention); test `unwrap()/expect()` (×1976) stay panics via `catch unreachable` / `orelse unreachable`, never become error returns.

### 3. Enums, match, structs

- Data-carrying enums (×43+, e.g. `AppEvent` in `events.rs:56` mixing struct/tuple/unit variants) → `union(enum)` with struct payloads; unit-only enums → `enum`.
- `match` → `switch`; or-patterns `A | B` → `.a, .b =>`; `..` rest patterns → destructure only the used fields; `matches!(x, P1 | P2)` (×173) → `switch (x) { .p1, .p2 => true, else => false }`.
- `if let` chains (×746) → `if (x == .variant)` + payload capture `if (x) |v|` forms; nested chains flatten to early-return guards.
- Newtype IDs (`pub struct PaneId(u32)` + `static NEXT_PANE_ID: AtomicU32`, `layout.rs:11`) → `pub const PaneId = enum(u32) { _ }` (non-exhaustive enum gives type safety without cost) + `std.atomic.Value(u32)` generator.
- `impl` blocks (×126+) → methods in the struct declaration; free functions stay free.
- `Deref/DerefMut` on `Workspace`→`Tab` (`workspace.rs:172`) - Zig has no Deref: generate an explicit `activeTab()`/`activeTabMut()` accessor and rewrite call sites mechanically (`ws.panes` → `ws.activeTab().panes`).
- `Drop` impls (×2 here + FFI handles) → `deinit()` called via `defer`/`errdefer` at the owner, per OWNERSHIP.tsv.

### 4. Derives

| Derive | Zig rule |
|---|---|
| `Debug` (×161) | `pub fn format(self: T, writer: *std.Io.Writer) std.Io.Writer.Error!void` (the 0.15 writergate signature - no fmt-string/options params; see `vendor/libghostty-vt/src/input/Binding.zig:1166`) only where Debug output is actually consumed (logs, tests); else drop |
| `Clone` (×151) | `pub fn clone(self: *const T, allocator: Allocator) !T` deep-copy where heap-owning; plain copy (`const b = a;`) for POD |
| `PartialEq/Eq` (×119) | `std.meta.eql` for POD; hand-written `eql` where slices/maps need deep compare |
| `Hash` | custom `hash(self, hasher)` only for HashMap key types |
| `Default` (×28) | field defaults in the struct decl (`field: T = .{}`), constructed via `.{}` |
| `PartialOrd/Ord` (derived in `pane/terminal.rs`, `config/io.rs`, `headless.rs`, `update.rs`; used for sorting) | hand-written `order(a, b) std.math.Order` compare fn (`std.math.order` / `std.mem.order` per field, lexicographic) passed to `std.sort` |
| `Serialize/Deserialize` (×197 repo-wide) | comptime-reflection serialization layer (section 7) |

### 5. Closures, generics, iterators

- Closures (~1910) are overwhelmingly combinator arguments or `impl Fn`/`F: FnOnce` generic params (×143 + ×15); stored type-erased callables exist in exactly 4 places: the 3 FFI trampolines, `Box<dyn PrefixInputSource>` (`app/mod.rs:149`), and the PTY actor's `ReadCallback = Box<dyn FnMut(&[u8]) -> PtyReadResult + Send>` / `ReaderExitCallback = Box<dyn FnOnce() + Send>` fields (`pty/actor.rs:22-23,42-43`, mirrored in `actor/unix.rs:43-44`).
  Rule: combinator closures dissolve into the explicit loop that replaces the combinator; generic function params become `comptime f: anytype` (imitating `std.sort` style); the stored callables become context-struct + function-pointer pairs (`*anyopaque` ctx + fn ptr, ghostty-vt callback style).
- Iterator chains (`.iter` ×471, `.collect` ×197, `.filter/.filter_map/.find/.position/.any/.all/...`) → explicit `for`/`while` loops with an `ArrayList` accumulator when collecting.
  Preserve laziness-observable behavior: short-circuit order of `.any/.find`, side effects inside `.map` before a short-circuiting stage, `.rev()` iteration direction.
- `impl Iterator` return types → return an explicit iterator struct with `next()` (imitate `std.mem.tokenizeScalar`), or refactor the one caller to a loop - mechanical choice per site.
- The two function-local `macro_rules!` (`finish!`, `fallback!` in `pane/terminal.rs:1987,2010`) → local inline functions or labeled-block `break` patterns.

### 6. Strings, collections, arithmetic

- `String` (×953) → `[]u8` owned per OWNERSHIP.tsv (freed by owner) or `std.ArrayList(u8)` when built incrementally; `&str` (×342) → `[]const u8`.
  **Zig 0.15.2 note: `std.ArrayList` is unmanaged** - it does not store the allocator; every `append` takes `allocator` explicitly.
- `format!` (×350) → `std.fmt.allocPrint(allocator, "...", .{...})`; `.to_string()` on numbers → `allocPrint`/`std.fmt.bufPrint`.
- UTF-8: Rust `String` is validation-backed, Zig `[]u8` is not.
  Insert `std.unicode.utf8ValidateSlice` exactly where bytes cross from PTY/socket input into string-typed state; grapheme width stays with `ghostty_unicode_grapheme_width` → native ghostty-vt call.
- `Vec<T>` (×407) → `std.ArrayList(T)` (unmanaged; pass allocator); `vec![...]` in tests → array literals or `try list.appendSlice(alloc, &.{...})`.
- `HashMap` (×265) → `std.AutoHashMapUnmanaged(K, V)`; string keys → `std.StringHashMapUnmanaged` (decide key-ownership per OWNERSHIP.tsv); `BTreeMap/BTreeSet` (×12, detect slice only) → `std.ArrayList` kept sorted + binary search (herdr uses them only for deterministic iteration order); `.entry()` API (×8) → `getOrPut`.
- Casts: `as` (×295) → `@intCast` (asserts fit - matches Rust debug behavior; where Rust `as` intentionally truncates, use `@truncate` and say so in a comment), `usize`↔`u16` geometry math is the hot zone.
- Bounded arithmetic (×552 - load-bearing in layout/geometry): `saturating_add/sub` → `a +\| b` / `a -\| b`; `wrapping_*` → `a +% b`; `checked_*` → `std.math.add(T, a, b)` (error) or explicit compare-first.
  Plain Rust `+` on release wraps ONLY in the `wrapping_` forms; Zig safe builds panic on overflow - this direction is safe-by-default, but any Rust site relying on release-mode wrap without `wrapping_` is a pre-existing bug to flag, not to reproduce.

Misc std rules (each recurring enough to need one):

| Rust | Zig 0.15.2 | Notes |
|---|---|---|
| `Duration` / `Instant` / `SystemTime` (~867 sites, deadline math for the poll loops) | `Duration` → integer nanoseconds (`std.time.ns_per_ms` etc.); `Instant` → `std.time.Instant` / `std.time.Timer`; `SystemTime`/`UNIX_EPOCH` → `std.time.timestamp()`/`milliTimestamp()` | keep monotonic (Instant) vs wall-clock (SystemTime) distinct - deadlines must stay monotonic |
| `Path`/`PathBuf` (~695 sites) | `[]const u8` / owned `[]u8` per OWNERSHIP.tsv | `.join/.push` → `std.fs.path.join` (allocates, owner frees); `.extension/.file_name` → `std.fs.path` helpers; Windows separators handled by `std.fs.path`, never by hand |
| `env::var` / `env::var_os` (~100+ sites, large `HERDR_*` namespace) | `std.process.getEnvVarOwned` (allocates; `error.EnvironmentVariableNotFound`) / `std.posix.getenv` for borrow-only unix paths | `var_os` non-UTF8 semantics differ - validate where the value crosses into string state |
| `mem::take` / `mem::replace` / `mem::swap` (~10+ sites: `osc.rs`, `layout.rs`, `terminal.rs`, `raw_input.rs`) | read-then-assign-default / labeled block returning the old value / `std.mem.swap` | |
| `Cow<str>` (×4: `pane/osc.rs`, `ui/keybind_help.rs`, `popup_size.rs`) | small tagged union `{ borrowed: []const u8, owned: []u8 }` with `deinit` freeing only owned | borrow path is the common case |
| `Vec::drain` (~15 sites: `app/agent_resume.rs` ×7, `ui/sidebar.rs`, `app/actions.rs`, input modules) | full-range drain → `toOwnedSlice()` + reuse, or iterate then `clearRetainingCapacity()`; range drain → explicit copy-out + `replaceRange` | range-drain shift semantics are a footgun - never leave a gap |
| `char` handling (~195 sites: `.chars()`, `char::`, `is_alphanumeric`) | `u21` scalar via `std.unicode.Utf8Iterator`; byte-level ops stay `u8`; classification via `std.ascii` where the Rust call was ASCII-only, ghostty-vt unicode tables otherwise | Rust `char` is a validated scalar - decode, don't index |
| `.parse::<T>()` / `from_str_radix` (~97 sites) | `std.fmt.parseInt(T, s, 10)` / `parseInt(T, s, radix)` / `std.fmt.parseFloat` | error-union instead of `Result<_, ParseError>` |
| format specifiers (`{:>8}`, `{:.2}`, `{:x}`) | `std.fmt` equivalents (`{d:>8}`, `{d:.2}`, `{x}`) | translate per-site; Zig fmt strings are comptime-checked so drift fails the build |

### 7. Serialization (three formats, two byte-compat contracts)

**bincode over the TUI socket** (`protocol/wire.rs`, PROTOCOL_VERSION 17, ×50 call sites, 185 derive structs feeding it; second consumer: `ui/tab_surface.rs:256` encodes frames with the same `config::standard()` - include it in the byte-compat fixture inventory).
Framing: `[u32 LE length][payload]`, 2 MB cap, decoder must consume exactly the claimed length.
Payload: bincode v2 `config::standard()` = little-endian, **varint** integer encoding, enum discriminants as varint u32 in declaration order, `Vec`/`String` as varint length + elements, `Option` as u8 0/1 + value.
bincode's varint is NOT LEB128 - it is the 251-marker scheme (value < 251 = single byte; else marker byte 251/252/253/254 followed by u16/u32/u64/u128 LE); signed integers are ZigZag-encoded before the varint; collection/string lengths are u64-as-varint.
In-house Zig `bincode.zig` must reproduce this bit-for-bit; the ledger test is: Rust-encoded fixture bytes decode in Zig and re-encode identically (fixtures generated from the Rust build before the swap).

**JSON** - two consumers: the public API (`serde_json` ×294, schemas in `src/api/schema/*`, schemars-generated `herdr-api.schema.json`) and persisted state (`src/persist/`, `SNAPSHOT_VERSION 3`, pretty-printed, atomic temp+rename writes, `serde_json::Value` passthrough fields for forward compat).
Zig layer: comptime-reflection `json.zig` over `std.json`, supporting the used attribute set: `rename`, `rename_all` (snake_case/lowercase/kebab-case), `default`, `skip_serializing_if="Option::is_none"` (emit-if-set), untagged-value passthrough (`std.json.Value` mirrors `serde_json::Value`).
Key order and pretty format of snapshots should match to keep diffs clean, but only field/value fidelity is a gate.

**TOML** - config + 21 detection manifests.
Needs an in-house TOML parser (stdlib has none) with: `deny_unknown_fields` per-struct, defaults, rename_all, and the `serde_ignored` behavior (`config/io.rs:424`): a two-phase parse that collects unknown keys **with their full paths** as diagnostics instead of failing.
This is the hardest serde behavior to reproduce - design the parser callback-first (report every unmatched key + path) so both `deny` and `collect` modes fall out.

### 8. FFI collapse (the rewrite's biggest win)

Delete `src/ghostty/bindings.rs` (4,240 lines of bindgen, 173 extern fns, ~222 repr(C) types) and the unsafe layer in `src/ghostty/mod.rs` (149 unsafe blocks, 216 call sites).
Replace with `@import` of `vendor/libghostty-vt/src` module (build.zig dependency; `build.rs`'s `zig build -Demit-lib-vt` step disappears).
`build.rs` does NOT fully disappear: it also injects build metadata (`HERDR_BUILD_CHANNEL`/`HERDR_BUILD_ID`/`HERDR_BUILD_COMMIT` via `rerun-if-env-changed`, read at compile time by `src/build_info.rs` through `option_env!` plus `CARGO_PKG_VERSION`).
That becomes a build.zig `Options` step - a generated options module imported at comptime - feeding the version/channel/update logic.
Mapping rules:
- `GhosttyResultExt::into_result()` → the Zig API's native error unions.
- Opaque handle + `Drop` → the Zig struct + `deinit()`.
- The 3 `extern "C"` trampolines (`write_pty`, `pwd_changed`, `decode_png`) → direct Zig callbacks, no userdata boxing.
- Two-call length-then-fill allocation patterns → direct slice returns from the Zig API.
- `slice::from_raw_parts(..).to_vec()` copies → decide per site: borrow the ghostty-owned slice or dupe with the owner's allocator (OWNERSHIP.tsv row required).
- Patch 0001 (grapheme clustering default): call the mode-setting Zig API directly at terminal init; verify the patch can be dropped (ticket #11).
- png decoding currently routed THROUGH the FFI trampoline → call ghostty-vt's Zig decoder directly; the Rust `png` crate dependency drops out.

### 9. Compat layers (in-house, API-shaped like the crates)

- **render.zig (ratatui-shaped)**: `Rect` (×917 - most-used type in the UI slice), `Style`/`Color`/`Modifier`, `Span`/`Line`, `Paragraph`, `Block`, `Constraint`+`Layout` splits, `Frame`, cell `Buffer` with double-buffer diffing.
  Port ratatui's buffer-diff core mechanically; widget surface is what herdr uses: `Paragraph` (×109, including `Wrap { trim }` in `keybind_help.rs`, `release_notes.rs`, `dialogs.rs`), `Clear` (heavily - popup/modal clearing in `status.rs`, `panes.rs`, `mobile.rs`, `dialogs.rs`, `menus.rs`), `List`/`ListItem`/`ListState` (`ui/menus.rs`), `Block` + `Borders` (×8), direct `Buffer` writes (×4).
  herdr also relies on the `unstable-rendered-line-info` feature (wrapped-line measurement for scrolling) - the in-house Paragraph must expose rendered-line counts.
  Table/Gauge/Scrollbar/Tabs/Canvas are confirmed unused.
  Final in-house-vs-libvaxis call is ticket #8.
- **input.zig (crossterm-shaped)**: herdr already wraps events in its own key model (`src/input/model.rs`; bare crossterm `Event` ×0), so only `KeyCode` (×965), `KeyModifiers` (×585), `MouseEvent` (×374), `KeyEvent` (×302) shapes plus the terminal-input decoder need porting; Windows console input (`ReadConsoleInputW`) is a separate per-OS path.
- **term.zig (terminal lifecycle, crossterm command path)**: `main.rs` drives ~48 `execute!`/`queue!` command sites that must be reproduced byte-for-byte as ANSI/CSI writes: `enable_raw_mode`/`disable_raw_mode` (termios on unix, console modes on Windows), `EnterAlternateScreen`/leave, `EnableMouseCapture`/`DisableMouseCapture`, `EnableBracketedPaste`, `EnableFocusChange`, and `PushKeyboardEnhancementFlags`/`PopKeyboardEnhancementFlags` (Kitty keyboard protocol).
  Teardown ordering on panic/exit is part of the contract (terminal must be restored).
- **log.zig (tracing-shaped)**: flat structured logging only (×226 sites, no spans, no `#[instrument]`) → `log.debug(.{ .pane_id = pane_id, .err = err }, "msg")` over `std.log` with an env-filter (`HERDR_LOG`) writer setup mirroring `logging.rs`.
- **CLI**: dispatch is hand-rolled `match` over argv (`cli.rs:62`) - ports directly to `switch` over `args`. clap exists ONLY to emit shell completions (`cli/completion.rs`); replace with committed completion scripts generated once, drop clap entirely.
- **Subprocess**: `std::process::Command` (×102) → `std.process.Child`; curl-subprocess HTTP (`update.rs`), git-subprocess (`worktree.rs`), and the sound player (`sound.rs`: afplay on macOS, MediaPlayer on Windows, decoder-capable player on Linux, on a spawned thread, gated by `HERDR_DISABLE_SOUND` and skipped under nextest) port as-is - no HTTP, git, or audio library needed.
- **Assets**: `include_str!/include_bytes!` (sounds, integration hooks) → `@embedFile`.

### 10. Platform layer

- `#[cfg(unix)]` ×92 / `#[cfg(windows)]` ×39 / `target_os` gates → per-OS source files under `src/platform/` (same layout) selected in `platform/mod.zig` via `switch (builtin.os.tag)`; `cfg!()` policy constants → plain `const` on `builtin.os.tag`.
- libc calls (~50 unique symbols: proc introspection, sysctl KERN_PROCARGS2, signals, rlimit, poll, setsid, ioctl TIOCSWINSZ) → `std.posix` where covered, direct `std.c` externs otherwise.
- windows-sys calls (ReadConsoleInputW, PeekNamedPipe, WaitForSingleObject, job objects) → `std.os.windows` + hand-declared externs for gaps.
- SCM_RIGHTS fd passing (`server/handoff.rs:377`: hand-rolled msghdr/CMSG) → `std.posix.sendmsg` for the send side; recvmsg is NOT in std.posix on 0.15.2 (upstream ziglang/zig#20660), so use `std.c.recvmsg` (or `std.os.linux.recvmsg` on Linux). Build the cmsg buffer by hand - std.posix exposes no CMSG_* helpers. Port the byte layout carefully, this is the server-restart handoff.
- portable-pty (vendored) → in-house `pty.zig`: openpty/forkpty per OS, `PtySize`, reader clone / writer take / resize, spawn with env+cwd; the actor thread model (reader thread, writer queue, control channel per pane) ports 1:1.
- `ctrlc` crate → `std.posix.sigaction` (SIGINT/SIGTERM) setting the same AtomicBool + channel send; Windows: `SetConsoleCtrlHandler`.
- The one real unsafe block (`pane.rs:1714`, `OwnedFd::from_raw_fd`) → plain `std.posix.fd_t` field.

### 11. Tests

- `#[cfg(test)] mod tests` (58 modules, 2,788 fns repo-wide) → `test "name" {}` blocks in the same file; `cargo nextest` filters → `zig build test` filters.
- `assert_eq!/assert!/assert_ne!` (×3965 in UI slice alone) → `try std.testing.expectEqual` / `expect` / `expectEqualSlices` / `expectEqualStrings` - pick the deep-comparing form matching the Rust semantics.
- Every test allocates via `std.testing.allocator` (leak-checked by default - this is the borrow-checker replacement's front line).
- Test seams port as-is: `AppState.testNew()`, `Workspace.testNew()`, `assertInvariantsForTest()`, adversarial-state constructors - same names, camelCased.
- `#[should_panic]` → `std.testing.expectPanic` is unavailable in 0.15; restructure those few tests to expect an error or use a check function returning error.
- The Rust integration suite (`tests/`) is NOT ported - it is the oracle (see ORACLE.md); it hand-implements the wire protocol (`tests/support/mod.rs:111-306`), which doubles as an independent spec of the bincode framing.

### 12. Semantic-drift trap list (reviewer checklist source)

The EXECUTION.md checklist is derived from this section; keep the two in sync.
Traps specific to this codebase: eager-vs-lazy `unwrap_or` args with side effects; `Deref`-hidden `Workspace→Tab` field access rewritten to explicit accessors at every site; atomic-ordering fidelity; `as`-cast truncation vs assertion intent; iterator short-circuit order; drop/defer ordering for locks and PTY handles; UTF-8 validation points; bincode varint fidelity; `debug_assert!` side effects (Rust erases in release, `std.debug.assert` erases in ReleaseFast - hoist side effects in BOTH directions); JSON field presence (`skip_serializing_if`) affecting the public API contract.
