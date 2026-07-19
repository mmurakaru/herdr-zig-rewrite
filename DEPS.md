# Dependency Disposition for the Zig Port

Research output for issue #6 (map: #3).
Policy: vendored minimalism - Zig stdlib first, in-house compat layers second, vendored proven Zig libraries only when clearly better.
All vendored candidates were checked against Zig 0.15.2 (the version ghostty and the vendored libghostty-vt pin today).
Async runtime (tokio, #7) and terminal/UI stack (ratatui/crossterm, #8) are decided in their own tickets and only listed here for completeness.

Evidence base: every disposition below is grepped from the current Rust source; representative call sites are cited as `path:line`.
There are no `[dev-dependencies]` or `[build-dependencies]` in Cargo.toml; `build.rs` itself only shells out to `zig build` for the vendored libghostty-vt (build.rs:32-60) and disappears into `build.zig` in the rewrite.

## Disposition table

| Dependency | How herdr uses it (representative call sites) | Disposition | Effort | Risk notes |
|---|---|---|---|---|
| base64 0.22 | STANDARD alphabet encode/decode: kitty graphics payload chunking (src/kitty_graphics.rs:990), OSC 52 clipboard (src/selection.rs:268, src/pane/osc.rs:749), pane-graphics API (src/app/api/pane_graphics.rs:78) | zig-stdlib: `std.base64.standard` | S | Low. Same RFC 4648 alphabet with padding; add decode-error mapping. |
| bincode 2 (serde) | Socket wire protocol only: `[u32 LE length][bincode payload]` framing with `bincode::config::standard()` (src/protocol/wire.rs:812, 822, 864); also a process-local frame hash (src/ui/tab_surface.rs:256) | in-house layer (comptime codec) | M | Byte-compat with PROTOCOL_VERSION 17 required; bincode upstream is now unmaintained, so exiting it is a win. See deep dive. |
| bytes 1 | `Bytes` as cheaply cloneable byte buffers for pty output and input fan-out (src/pane.rs:9, src/app/mod.rs:3404) | drops-out (`[]const u8` slices + explicit ownership; small refcounted buffer type only if profiling demands it) | S | Ownership must be made explicit where Rust relied on refcounting; mostly mechanical. |
| clap 4.5 (builder, no derive) | CLI spec built with the builder API only (src/cli/spec.rs:1); actual arg handling is already largely hand-rolled matching (src/cli.rs:776) | in-house layer (arg spec + parser over `std.process.args`) | M | Help text and error wording will change slightly; herdr already hand-parses many subcommands so the gap is smaller than it looks. |
| clap_complete 4.5 | Shell completion generation from the clap spec (src/cli/completion.rs, src/cli/spec.rs:970) | in-house layer (completion emitters driven by the same in-house CLI spec) | M | bash/zsh/fish/powershell emitters are fiddly but well-understood; snapshot-test the generated scripts. |
| crossterm 0.29 | Input events, raw mode, terminal control (src/raw_input.rs, src/main.rs; 388 `crossterm::event` references) | decided elsewhere (#8) | - | - |
| ctrlc 3 | Two handlers: headless server shutdown (src/server/headless.rs:4090) and client interrupt (src/client/mod.rs:1226) | drops-out into platform layer (`std.posix.sigaction` for SIGINT/SIGTERM; `SetConsoleCtrlHandler` on Windows) | S | Windows console ctrl handler runs on its own thread; keep the handler as flag-set + wakeup, same as today. |
| interprocess 2.4 | Local sockets for server/client/API IPC: unix domain sockets via `GenericFilePath`, Windows named pipes via `GenericNamespaced` (src/ipc.rs:32-62, src/api/client.rs:6, src/server/client_transport.rs) | in-house layer (unix: `std.net`/`std.posix` unix sockets; windows: `CreateNamedPipeW`/`ConnectNamedPipe` bindings) | M | Windows named-pipe accept loop, instance limits, and security descriptor defaults need care; unix side is trivial. |
| libc 0.2 | Raw unix syscalls in platform code: fcntl/poll/ioctl/kill, SCM_RIGHTS fd passing via `msghdr`/`CMSG_*` (src/pty/fd.rs, src/server/handoff.rs, src/platform/macos.rs `KERN_PROCARGS2`) | drops-out (`std.posix` / `std.c`) | S | `CMSG_*` fd-passing has no high-level stdlib wrapper; write the cmsg math once in the platform layer and unit-test it. |
| portable-pty =0.9.0 (vendored, patched) | PTY open/spawn/resize on unix + ConPTY on Windows; local patch forces system conpty.dll (vendor/portable-pty.patches.md, vendor/patches/portable-pty/0001-force-system-conpty.patch) | in-house layer (posix `openpty`+fork/exec; Windows `CreatePseudoConsole` bindings) | L | Highest platform risk: ConPTY resize/EOF/exit-code semantics and the system-conpty behavior the patch exists for must be reproduced. Upstream ghostty has Zig pty code to crib from (not part of the vendored vt subset). |
| png 0.17 | Decode-only, one site: kitty-graphics PNG payloads decoded with EXPAND+STRIP_16 into RGBA8 (src/ghostty/mod.rs:543-576) | vendored zig lib: zigimg (tag `zigimg_zig_0.15.1` / `zig-0.15` branch) | S | Only critical-chunk decode to 8-bit RGBA is needed; if zigimg is too heavy, an in-house decoder on `std.compress.flate` is a viable M fallback. Indexed color is rejected today (src/ghostty/mod.rs:576). |
| ratatui 0.30 | TUI rendering | decided elsewhere (#8) | - | - |
| regex 1 | Runtime-compiled user-supplied patterns in 4 subsystems (see deep dive): detection manifests, plugin link handlers, API wait, API subscriptions | in-house layer (subset engine, Rust-regex-compatible syntax) | L | User-facing syntax compatibility; needs Unicode classes, `\p{Alphabetic}`, case-insensitive matching. See deep dive. |
| serde 1 (derive) | Derives on config, persistence, wire, and API types; heavy attribute usage (260x `default+skip_serializing_if`, 122x `rename`, 5x `untagged`, ...) | in-house layer (comptime reflection serialization core) | L | The keystone dependency. See deep dive. |
| serde_ignored 0.1 | Unknown-key path reporting when loading config, to warn users about typos (src/config/io.rs:499, 424-438) | in-house layer (feature of the serialization core: unknown-field callback with path) | S (on top of the core) | Path segments (map key / seq index) must survive through nested tables. |
| serde_json 1 | Persisted session state as pretty JSON (src/persist/io.rs:53), plugin registry (src/persist/plugin_registry.rs:17), the whole JSON API request/response surface (src/api/*) | zig-stdlib `std.json` + the in-house reflection layer on top | M | Persisted state compat is JSON field-name level, not byte level - much softer than the bincode wire. `std.json` handles tokens; the layer handles naming/enum/default semantics. |
| sha2 0.10 | SHA-256 only: update checksum verification (src/checksum.rs:30), frame hashing (src/ui/tab_surface.rs:257), plugin digests (src/api/schema/plugins.rs:151) | zig-stdlib: `std.crypto.hash.sha2.Sha256` | S | None. |
| tokio 1 (rt-multi-thread, macros, sync, time) | mpsc channels (92x unbounded), timers, select, spawn (grep counts in src) | decided elsewhere (#7) | - | Note for #7: libxev master now pins `minimum_zig_version = 0.16.0` and has no tags; a 0.15.2-compatible commit must be pinned (ghostty's own pin is the reference). |
| toml 0.8 | Parse: user config (src/config/io.rs), detection manifests (src/detect/manifest.rs), plugin manifests (src/app/api/plugins/manifest.rs). Serialize: keybindings profile (src/config.rs:123), manifest update status (src/detect/manifest_update.rs:371) | vendored zig lib: sam701/zig-toml (v0.3.0, `minimum_zig_version = 0.15.1`, TOML 1.1) for parsing, feeding the in-house reflection layer; tiny in-house TOML writer for the two serialize sites | M | zig-toml parses into its own value tree/structs; bridge it to the reflection layer so rename/default/unknown-key semantics stay in one place. Writer output ordering should be snapshot-tested. |
| tracing 0.1 | Structured key-value logging, ~150 call sites (src/logging.rs:28 `event=..., subsystem=..., outcome=...` style) | in-house layer over `std.log` (custom logFn, key-value formatting) | M | Log format feeds human debugging, not machines; keep field ordering stable anyway for grep-ability. |
| tracing-subscriber 0.3 (env-filter) | `EnvFilter` from `HERDR_LOG` with `herdr=info` default, file writer with rotation (src/logging.rs:23-30) | in-house layer (env-filter subset parser: `target=level` comma list; size-based file rotation already exists as parameters DEFAULT_MAX_LOG_BYTES) | S | Only the directive subset herdr documents needs to parse; span support is unused. |
| unicode-width 0.2 | Display-cell width for UI truncation/layout (src/ui/text.rs:4,46, src/pane/terminal.rs:13, src/protocol/render_ansi.rs:32) | drops-out into vendored libghostty-vt unicode tables (already in-tree: vendor/libghostty-vt/src/unicode/, vendor/libghostty-vt/src/simd/codepoint_width.zig) | S | Ghostty's width tables differ slightly from the unicode-width crate (mode-2027-aware, terminal-accurate). That is a feature - UI width finally matches the terminal cells - but characterization-test sidebar/title truncation for visible diffs. |
| schemars 1.2 (derive) | `schema_for!` over ~158 `JsonSchema` API types; generated draft 2020-12 schema is pinned at docs/next/api/herdr-api.schema.json and embedded via `include_str!` (src/cli/api.rs:1); a test regenerates and compares (src/api/schema/tests.rs:6,133) | in-house layer (comptime JSON-schema generator sharing type info with the serialization core) | M | Only needs to reproduce the constructs the API types use: refs, enums, `schemars(skip/range/schema_with)` overrides (2/5/6 uses). Keep the checked-in schema as the compat oracle. |
| windows-sys 0.61 | Raw Win32 in platform code: console, pipes, job objects, toolhelp, clipboard (src/platform/windows.rs, src/client/input/windows_vti.rs, src/ipc.rs; 10 import sites incl. vendored portable-pty) | drops-out (`std.os.windows` + hand-written `extern "kernel32"/"user32"` declarations for the missing functions) | M (absorbed into platform work) | Zig stdlib covers a lot of Win32 already; declare the rest per-site. No dependency needed. |
| build.rs (no build-deps) | Invokes `zig build` on vendor/libghostty-vt, injects build metadata env (build.rs:32-60) | drops-out (becomes the top-level `build.zig`; libghostty-vt is linked as a normal Zig dependency/module instead of a C static lib behind FFI) | M | This is a simplification: the FFI boundary in src/ghostty/mod.rs can shrink or disappear. |

## Deep dive: regex

All four `Regex::new` consumers compile patterns at runtime from user-controllable input, so a compile-time-only matcher is not an option:

- Detection manifests: `regex` / `line_regex` gate matchers, validated then compiled (src/detect/manifest.rs:1053, 1168, 1173). Users can override manifests in `~/.config/herdr/agent-detection/`.
- Plugin link handlers: `handler.pattern` from third-party plugin manifests (src/app/api/plugins/manifest.rs:452, src/app/api/plugins/mod.rs:567).
- API `wait output --regex`: arbitrary pattern over pane text (src/api/wait.rs:33, src/cli.rs:776).
- API event subscriptions: same `OutputMatch::Regex` shape (src/api/subscriptions.rs:215).

The bundled manifests are the concrete corpus of what real patterns look like. Every unique pattern currently shipped in src/detect/manifests/*.toml:

```
(?:^| - )grok$
(?:^| )[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏](?: |$)
(?i).*opencode.*esc (again to )?interrupt
(?i)\b[1-9][0-9]*\s+background\s+tasks?\b
(?i)\bkimi[-\w.]*\s+thinking\b.*\[[1-9][0-9]*\s+agents?\s+running\]
(?i)·\s*[1-9][0-9]*\s+task
(?i)^\s*❯?\s*1\.\s*yes\b
(?i)^\s*▶?\s*approve .*\?$
(?i)^\s*❯?\s*yes\b
(?i)^\s*❯.*(yes|allow)
(?i)^\s*(run |.*\(y\).*(allow|run \(once\)|→ run))
(?i)^\s*[⠀-⣿]+\s*(thinking\.\.\.|working\.\.\.|using )
(?i)^\s*╰\s+\S+\s+(thinking|streaming|running tools|waiting)\s+─
(?i)^\s*1\.\s*yes\b
(?i)^\s*2\.\s*no\b
(?i)^\s*2\.\s*yes\b
(?i)^\s*3\.\s*no\b
(?i)^\s*allow .*\(y\)
(?m)^\s*❯\s*$
(?s).+
(■|⬝){4,}
[⋅:⸬⁙.·]\s+[1-9][0-9]*\s+│
[\x{2800}-\x{28FF}]
\S
^❯ 
^ \[(BUILD|PLAN|BASH)\]
^( [\x{2800}-\x{28FF}]){1,2} 
^( [\x{2800}-\x{28FF}]){1,2} \[(BUILD|PLAN|BASH)\]
^[•◦]\s+Working \([^)]*esc to interrupt\)(?: · .*)?$
^[\x{2800}-\x{28FF}] 
^\s*❭ Ask Devin to build
^\s*❯
^\s*(⬡|⬢|[⠀-⣿]+)\s+\p{Alphabetic}+\w*ing\b
^\s*(◔|◑|◕|●)\s+\p{Alphabetic}
^\s*(🌕|🌖|🌗|🌘|🌑|🌒|🌓|🌔)\s*$
^\s*[⠀-⣿]
^\s*[⠀-⣿]\s+.*\p{Alphabetic}
^\s*[⠀-⣿]+\s+\p{Alphabetic}+\w*ing\b
^\s*[\x{2801}-\x{28FF}]\s.*\[stop\]\s*$
^\s*[\x{2801}-\x{28FF}]\s+(Run|Read|Search|List)\b
^\s*\? 
^\s*question\s*$
^\s*┃\s+[0-9a-z]+\s+\([●○]\)\s
^\x{2733} 
^4;0;0$
^4;0
^4;1;-1$
```

Feature inventory from that corpus (the syntax the engine must support):

- Anchors `^` `$`, flags `(?i)` `(?m)` `(?s)` (inline, prefix position only in practice).
- Character classes with literal non-ASCII chars, `⠀`/`\x{2800}` codepoint escapes, ranges across the BMP, negated classes (`[^)]`).
- Perl classes `\s` `\S` `\w` `\b` (word boundary), `\d` implied by `[0-9]` style but support it anyway.
- One Unicode property: `\p{Alphabetic}`.
- Alternation, non-capturing `(?:...)` and plain groups, quantifiers `*` `+` `?` `{1,2}` `{4,}`, `.` with and without `(?s)`.
- No lookaround, no backreferences, no lazy quantifiers, no named groups (and the Rust `regex` crate forbids the first two anyway, so no user pattern can depend on them).

Ecosystem check (verified 2026-07):

- mvzr 0.3.9 works with Zig 0.15.2 but is byte-level: no `(?i)` Unicode case folding, no `\p{...}`, codepoint class ranges must be hand-encoded as byte sequences. Insufficient for the shipped manifests as-is.
- zig-regex (tiehuis lineage / zig-utils fork) is maintained but its Unicode property and inline-flag coverage is unverified against this corpus.
- ezi-gex advertises full `\p{}` support and linear-time matching but is at 0.2.0-dev and unproven; too young to vendor under this policy.

Recommendation: in-house subset engine (effort L).
A Thompson-NFA/pike-VM over decoded codepoints, compiling the feature set above, is ~1.5-2.5k lines of Zig plus a small generated `Alphabetic` range table (from UCD DerivedCoreProperties; the vendored libghostty-vt tables cover width/grapheme, not Alphabetic).
Linear-time matching also removes the ReDoS class of bugs for plugin/API-supplied patterns.
Reject-with-error anything outside the subset, using the same error string surface manifests already show users (src/detect/manifest.rs:1053).
Characterization tests: run the full manifest corpus against fixture pane text and diff match results against the Rust engine before switch-over.

## Deep dive: bincode wire compatibility

Scope correction to the ticket premise: persisted session state is serde_json pretty JSON (src/persist/io.rs:53), not bincode.
Bincode appears in exactly two places: the client/server socket protocol (src/protocol/wire.rs) and a process-local frame hash (src/ui/tab_surface.rs:256, no cross-version compat needed).
So byte-compatibility only has to hold for the socket protocol, guarded by `PROTOCOL_VERSION: u32 = 17` (src/protocol/wire.rs:16) with an explicit version handshake (src/protocol/wire.rs:921).

Exact configuration used everywhere: `bincode::serde::encode_to_vec / decode_from_slice` with `bincode::config::standard()` (src/protocol/wire.rs:822, 864).
`standard()` = little-endian, variable-length integer encoding, no size limit.
Framing above it is `[u32 LE length][payload]` (src/protocol/wire.rs:812).

What a Zig codec must reproduce (verified against the bincode 2.0.1 spec and source):

- Unsigned varint: values < 251 are a single byte; 251..=u16::MAX → marker `0xFB` + u16 LE; ..=u32::MAX → `0xFC` + u32 LE; ..=u64::MAX → `0xFD` + u64 LE (`0xFE` + u128 exists but no wire type uses it). `u8` is always one raw byte. `usize` encodes as u64.
- Signed varint: zigzag first (`negative → !(n as uN) * 2 + 1`, `non-negative → n * 2`), then the unsigned rules. (Wire types are currently all unsigned, but do not let the codec silently mis-handle a future `i32`.)
- bool: one byte 0/1, decode rejects other values.
- enum: variant index in declaration order, encoded as a u32 through the varint rules (so almost always one byte).
- `Option<T>`: one byte 0/1 discriminant then the value - never varint-widened.
- `Vec<T>` / `String`: varint length then elements / raw UTF-8.
- `char`: the Unicode scalar value as a u32 through the varint rules (wire uses it: `Char(char)` at src/protocol/wire.rs:88).
- f32/f64: raw IEEE 754 LE bits, no NaN normalization.
- structs/tuples: fields in declaration order, no metadata, no length prefix.

Serde-attribute hazards: bincode is not self-describing, so `#[serde(default)]` (one use in wire types, `CursorState.shape`, src/protocol/wire.rs:454) is a decode-time no-op, and any future `skip_serializing_if` on a wire type would corrupt the stream.
The Zig codec should be generated by comptime reflection from Zig struct definitions that mirror the Rust declaration order exactly.

Compat strategy: treat the Rust implementation as the oracle.
wire.rs already contains many encode/decode fixtures (src/protocol/wire.rs:957-1223); export those exact byte vectors as golden fixtures for every `ClientMessage`/`ServerMessage` variant and test the Zig codec against them.
During any mixed-version window this keeps a Zig client speaking to a Rust server byte-for-byte; if the cutover is atomic (client and server ship together), the handshake at wire.rs:921 plus a PROTOCOL_VERSION bump is the escape hatch, but the golden-fixture suite is still the cheapest way to prove the codec.

## Deep dive: serde / serde_json / toml / serde_ignored / schemars

This family collapses into one comptime-reflection serialization core with three frontends (JSON via `std.json` tokens, TOML via vendored zig-toml, bincode via the wire codec above) and one schema generator.
Attribute inventory across src (grep of `#[serde(...)]`):

| Construct | Count | Notes for the Zig layer |
|---|---|---|
| `default` / `default = "fn"` | 132 + 7 | Per-field default values; Zig struct field defaults cover most, function defaults need a hook |
| `default, skip_serializing_if` | 260 | Omit-if-default/None on serialize; mostly `Option::is_none` |
| `skip_serializing_if` alone | 54 | Same mechanism |
| `rename = "..."` | 122 | Per-field wire-name override |
| `rename_all = "..."` | 41 | Case convention per type (snake_case dominates) |
| `tag = "..."` (internally tagged) | 6 + 2 | Enum with discriminator field |
| `tag + content = "params"` | 1 | Adjacently tagged (API request envelope) |
| `untagged` | 5 | Trial deserialization in declaration order (src/config/keybinds.rs, src/config/sidebar.rs, src/api/schema/events.rs, src/api/client.rs, src/remote/unix.rs) |
| `deny_unknown_fields` | 6 | Strict decode mode per type |
| `skip` / `skip_serializing` | 6 + 2 | Field excluded from (de)serialization |
| `flatten` | 2 | Inline child struct fields; consider refactoring these two sites away instead of implementing flatten |
| `alias` | 3 + 1 | Extra accepted input names |
| `deserialize_with` / `try_from` | 5 + 1 | Hand-written decode hooks; port each as a custom `jsonParse`-style override |

Design shape: a Zig `Codec(T)` built from `@typeInfo` plus a per-type declaration block (e.g. `pub const serde = .{ .rename_all = .snake_case, .fields = .{ ... } }`) supplying the table above.
`std.json` provides the tokenizer/value layer and already supports unknown-field detection and struct mapping; the core adds naming, enum tagging, defaults, and untagged trial decode.

serde_ignored: config loading wraps the deserializer to collect unknown key paths and warn the user (src/config/io.rs:499, path reconstruction at :424-438).
The Zig core needs an unknown-field callback carrying a path of map-key/seq-index segments; this must work through the TOML frontend, so the zig-toml bridge has to preserve positions/paths rather than silently dropping unknown keys.

schemars: `schemars::schema_for!` generates draft 2020-12 schemas for the API types; the merged document is checked in at docs/next/api/herdr-api.schema.json, embedded into the binary (src/cli/api.rs:1), and a test regenerates and diffs it (src/api/schema/tests.rs:6, :133 joins that path).
Overrides in use: `schemars(skip)` x6, `schemars(range)` x2, `schemars(schema_with = ...)` x5 (e.g. src/popup_size.rs:153, src/api/schema/common.rs:4).
The Zig generator walks the same comptime type info and the same per-type declaration block, so names/enums/defaults can never drift between serializer and schema.
The checked-in schema file is the compat oracle: the port must reproduce it byte-for-byte (modulo agreed formatting) before the Rust generator is retired.

Effort: L for the core + JSON frontend, then S-M each for TOML bridge, unknown-key reporting, and schema generation.
This is the single largest in-house component of the port and should land early because config, persistence, API, and wire all sit on it.

## Deep dive: stdlib-coverage batch

- png: one decode-only call site for kitty graphics (src/ghostty/mod.rs:543) with `EXPAND | STRIP_16` transformations normalizing to 8-bit, then a match converting RGB/Gray/GrayAlpha to RGBA8 (:554-575) and rejecting Indexed (:576, unreachable after EXPAND).
  Zig stdlib has inflate (`std.compress.flate`) but no PNG chunk layer.
  Vendor zigimg pinned at its `zigimg_zig_0.15.1` tag (verified to exist; master already requires 0.16.0).
  Fallback if zigimg is too heavy: in-house critical-chunk decoder on `std.compress.flate`, effort M.
- sha2: streaming file hash for update verification (src/checksum.rs:30), one-shot digests (src/ui/tab_surface.rs:257, src/api/schema/plugins.rs:151). `std.crypto.hash.sha2.Sha256` covers both patterns directly.
- base64: STANDARD engine only, encode and decode. `std.base64.standard.Encoder/Decoder` is a drop-in.
- unicode-width: `UnicodeWidthStr/UnicodeWidthChar` in UI text truncation and ANSI render (src/ui/text.rs:46, src/protocol/render_ansi.rs:32).
  The repo already vendors ghostty's generated width/grapheme tables (vendor/libghostty-vt/src/unicode/, simd/codepoint_width.zig); reuse them instead of adding zg or another Unicode dependency.
  This makes UI width computation agree with the terminal emulator's own cell layout, which the Rust split (unicode-width crate vs ghostty tables) never guaranteed.
- interprocess: unix path sockets and Windows named pipes behind one `LocalListener/LocalStream` alias (src/ipc.rs:10-11, 32-62).
  Unix side is `std.net`/`std.posix`; Windows side is a thin named-pipe wrapper - herdr uses only connect/accept/read/write, no advanced options.
- ctrlc: two flag-setting handlers; `std.posix.sigaction` + `SetConsoleCtrlHandler` in the platform layer.
- clap/clap_complete: builder-only spec (src/cli/spec.rs:1 imports `Arg, ArgAction, Command, ValueHint`), completions generated from it (src/cli/spec.rs:970); much of the actual parsing is already manual (src/cli.rs:729-796).
  Zig stdlib gives `std.process.args` only; an in-house declarative spec (subcommands, flags, help, completions) fits the vendored-minimalism policy better than zig-clap since completions generation would need custom work either way.
  `std.Progress` is unrelated (progress bars, not args or logging) - not applicable.
- tracing/tracing-subscriber: structured fields on ~150 call sites (src/logging.rs:28), `EnvFilter` from `HERDR_LOG` with default `herdr=info` (src/logging.rs:23), non-ANSI file output with rotation params.
  `std.log` with a custom `logFn` plus a small `target=level` filter parser and the existing rotation logic covers everything used; spans are not used anywhere.

## The three hardest dependencies

1. serde family (serde + serde_json + toml + serde_ignored + schemars): one comptime serialization core that must reproduce rename/default/tagging semantics across four formats, report unknown config keys with paths, and regenerate docs/next/api/herdr-api.schema.json byte-identically.
2. regex: an in-house linear-time engine with Unicode classes, `\p{Alphabetic}`, and inline flags, because all four consumers compile user-supplied patterns at runtime and no vetted Zig library on 0.15.2 covers the shipped manifest corpus.
3. bincode wire codec: byte-exact reimplementation of bincode 2 `standard()` (LE + varint + zigzag + one-byte Option + u32 variant tags) behind PROTOCOL_VERSION 17, proven by golden fixtures exported from the Rust implementation.

(Honorable mention outside this ticket's serialization focus: the vendored portable-pty replacement, where ConPTY semantics and the force-system-conpty patch carry the most platform risk.)
