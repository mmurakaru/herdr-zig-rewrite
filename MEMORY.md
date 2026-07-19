# Memory Discipline for the Zig Port

This document defines the allocator discipline for porting Herdr from Rust (ownership-checked) to Zig 0.15.2 (manual memory management).
It is the companion to `OWNERSHIP.tsv`, which maps every heap-owning Rust struct field to its Zig allocator and freeing owner.
It is the inverse of Bun's `LIFETIMES.tsv`: instead of documenting lifetimes the borrow checker already enforces, it prescribes the rules a human (or agent) must enforce by hand.

## Allocator inventory

Every allocation belongs to exactly one of these allocators.
A struct field's allocator is recorded in `OWNERSHIP.tsv`; anything not listed there defaults to the state gpa.

### 1. State gpa (long-lived)

One `std.heap.GeneralPurposeAllocator` (release: `std.heap.smp_allocator` or c_allocator behind the same interface) owned by `main()`.
Backs everything with session lifetime: `AppState`, `Workspace`/`Tab`/`PaneState`, `TerminalState`, the runtime registry, server client map, manifest cache generations, plugin registry, caches keyed by pane/terminal/path.
Freed by explicit `deinit()` methods that mirror Rust's `Drop` recursion.
Rule: every struct that owns gpa memory has a `deinit(self, gpa)` and its container calls it; a struct without `deinit` must be plain-old-data.

### 2. Per-frame render arena

`std.heap.ArenaAllocator` owned by the render loop, `reset(.retain_capacity)` at the start of every frame.
Backs `ViewState` geometry vectors (`pane_infos`, `tab_hit_areas`, `split_borders`, `workspace_card_areas` - src/app/state.rs:775), `FrameData`/`TerminalFrame` cell buffers and hyperlink lists (src/protocol/wire.rs:460), ANSI/graphics encode scratch.
Rule: nothing allocated from the frame arena may be stored in `AppState` or any client connection.
The one legal escape is the render baseline (`ClientRenderState`): the diff baseline is duped into the gpa because it must survive across frames.

### 3. Per-message protocol arena

One `ArenaAllocator` per decoded socket frame (client protocol, API socket, hook reports), reset after the handler returns.
Backs deserialized `ClientMessage`/`ServerMessage` payloads (src/protocol/wire.rs:308,599), API request JSON, `DetectionExplain` output.
Rule: handlers that need any payload byte past dispatch (clipboard image staging, terminal_id strings stored in `terminal_attach_owners`, session refs stored in `TerminalState`) must `dupe` into the gpa explicitly.
Storing an arena pointer in state is the bug class this rule exists to kill.

### 4. Per-operation arenas

- Snapshot save/load (src/persist/snapshot.rs): build or parse the whole `SessionSnapshot` tree in one arena; materialize into gpa-owned state on restore; destroy the arena. Pane history ANSI strings can be megabytes - never let them leak into the gpa via the snapshot path.
- Config load (src/config/model.rs:289): the entire `Config` tree lives in one arena per load. Reload = build new arena, swap the root pointer, destroy the old arena after the swap. No per-field frees, ever.
- Manifest cache generation (src/detect/manifest.rs:261): each reload builds a full generation (parsed manifests + compiled regexes) in gpa under one owner struct; the old generation is freed after the RwLock write swap. Readers evaluate under the read lock, so there are no dangling readers by construction.

### 5. Pool / fixed buffers

- PTY reader scratch: one fixed 64 KiB buffer per IO actor thread; payload `Bytes` handed to the terminal are gpa-owned, freed by the consumer after `ghostty_terminal_vt_write`.
- Layout `Node` tree (src/layout.rs:73): small recursive allocations; use the gpa (a dedicated pool is premature until profiling says otherwise).

### 6. Static (process lifetime)

Deliberately immortal state, registered in the leak-check skip list (see below): kitty `LOCAL_HOST_GRAPHICS` cache (src/kitty_graphics.rs), `KITTY_GRAPHICS_ENABLED`, manifest `OnceLock` cells' container (not the generations), tracing/logging sinks.

### 7. Foreign

libghostty-vt owns everything behind `GhosttyTerminal`; we own only the handle and must call `ghostty_terminal_free` exactly once, after all threads that touch it have been joined.
The `TerminalCallbackState` userdata (src/ghostty/mod.rs:622) is a separate, address-stable gpa allocation freed after `ghostty_terminal_free`.

## Arc -> what

Rust `Arc` in this codebase falls into three patterns; none of them ports to a general-purpose refcount.

1. Join-bounded sharing (the default): `Arc` exists only so a spawned task/thread can outlive a borrow. Examples: `PaneRuntime.terminal: Arc<PaneTerminal>`, the atomics block (`child_pid`, `detection_content_seq`, `kitty_keyboard_flags`, `full_lifecycle_authority_active`), `reported_cwd`, `pending_release`, `detect_reset_notify` (src/pane.rs:928). Zig: single owner (`PaneRuntime`) holds one heap `PaneShared` struct; worker threads get a plain pointer; `shutdown()` signals cancellation, joins every thread, then frees. The join is what makes the pointer valid - shutdown order is the invariant, not a refcount.
2. App-owned signal/queue handles: `Arc<Notify>`, `Arc<AtomicBool>` render flags, `mpsc::Sender` clones (src/workspace/tab.rs:38, src/app/mod.rs:96). Zig: the `App` owns one `EventQueue` and one `RenderSignal`; tabs/runtimes store non-owning pointers. `App.deinit` runs strictly after all runtimes are shut down.
3. Genuinely shared mutable registry: `EventHub` (src/api/event_hub.rs), `ClientWriterQueue` (src/server/client_transport.rs:184). Zig: keep single ownership plus mutex, and make the non-owner side (API thread, writer thread) terminate before the owner frees. `ClientWriterQueue` is the one place where "join the thread on connection close, then free" replaces Rust's drop-when-both-sides-detach.

Actual reference counting is reserved for cases where no join point exists.
Audit found none; if one appears, use an explicit `RefCounted(T)` wrapper with atomic count, not ad-hoc counters.

## RefCell / Cell / Mutex -> what

- `Cell<T>` (e.g. `PaneRuntime.current_size`) -> plain field; single-threaded mutation, no wrapper needed.
- `Mutex<T>` for cross-thread data (`kitty_fingerprints`, `reported_cwd`, writer queues) -> `std.Thread.Mutex` guarding the field, same shape. When the guarded value owns memory (the cwd path), the writer frees the old value under the lock.
- `RwLock` (manifest cache) -> `std.Thread.RwLock` with generation-pointer swap as described above.
- There is no runtime borrow tracking to replace: Rust `RefCell` panics become Zig data races. Any field mutated from more than one thread must have a mutex or be atomic; "checked by review" single-thread access is only allowed for state confined to the App event loop thread, which is where all of `AppState` lives.

## Ownership-transfer idioms

Rust `Option::take()` handoffs (clipboard write requests, `pending_agent_resume_plan`, `pending_release`) become: taker moves the pointer out (set field to null under any applicable lock), and the taker frees.
Channels follow produce-alloc/consume-free: the sender allocates the payload from the gpa, the receiver frees it after handling.
`AppEvent` payloads (src/events.rs) are the main instance; every event variant with heap data gets a `deinitPayload(gpa)` called at the end of the handler.

## Leak / UAF detection strategy

- Tests: every test constructs `std.heap.DebugAllocator(.{})` (Zig 0.15's GPA) and fails on `deinit() == .leak`. This is the fail-on-leak harness policy: a shared `testing_allocator` helper wraps this so no test opts out silently; `std.testing.allocator` already enforces it for unit tests - use it, never `page_allocator`, in tests.
- Debug builds: run the whole app under `DebugAllocator` with `.safety = true`, `.never_unmap = true`, `.retain_metadata = true` so use-after-free hits poisoned, unmapped-but-tracked memory and reports the allocation and free stack traces.
- Release builds: `smp_allocator`/c_allocator behind the same `Allocator` interface; a build flag (`-Dallocator=debug`) can force the debug allocator into a release-optimized build for reproducing field reports.
- CI: one job runs the test suite and a scripted headless server session compiled with `-fsanitize=address` (`-Doptimize=Debug` + AddressSanitizer via the C allocator path) or under valgrind on Linux, whichever the vendored libghostty-vt tolerates; ASan is preferred because it also covers the FFI boundary where libghostty frees memory we must not touch.
- Skip list: the statics in section 6 are freed in a `deinitStatics()` called only in leak-check builds so intentional process-lifetime state does not mask real leaks.
- Thread discipline is the UAF backstop: every spawned thread is joined in a `shutdown()`/`deinit()` that runs before its shared state is freed. A thread that cannot be joined must own its state outright.

## Top UAF risks (watch list)

1. `PaneRuntime`/`PaneTerminal` + ghostty FFI handle: detect task, IO actor callback, and render path all reach the terminal; freeing before joins, or moving the struct holding the FFI userdata, is a segfault (src/pane.rs:928, src/ghostty/mod.rs:622).
2. `ClientWriterQueue`: server loop and writer thread share it; connection close must signal + join before freeing (src/server/client_transport.rs:184).
3. Handoff paths (`preserve_for_handoff`, `from_handoff_fd`): deliberately leak fds and skip child reaping so a successor process can adopt them; these are the sanctioned exceptions and must be annotated at the call site (src/pane.rs, src/handoff_runtime.rs).
