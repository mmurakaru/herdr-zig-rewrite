# herdr-zig-rewrite

A full rewrite of herdr - a terminal workspace manager for AI coding agents - from Rust to Zig, with functional parity as the gate: all tests passing, zero regressions, identical product behavior.

The effort is tracked as a wayfinder map on this repo's issue tracker (see the issue labelled `wayfinder:map`). Key documents:

- `PORTING.md` (branch `research/porting`) - the mechanical Rust-to-Zig translation rules.
- `OWNERSHIP.tsv` + `MEMORY.md` (branch `research/ownership`) - allocator and ownership discipline.
- `DEPS.md` (branch `research/deps`) - dependency disposition table.
- `zig/` - the growing Zig tree, consuming the vendored libghostty-vt as a native Zig module.

The Rust tree stays intact and authoritative until the port reaches full parity on all six target platforms (Linux x64/arm64, macOS x64/arm64, Windows x64/arm64), at which point the trees swap.

## License

AGPL-3.0-or-later, inherited from the original herdr project. See `LICENSE`.
