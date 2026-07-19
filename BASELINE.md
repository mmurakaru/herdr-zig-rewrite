# Rust Baseline for the Zig Port

This file records the behavior of the Rust implementation at commit `b580103b956ef9cdf39798947a46ce4e8b78c322` (`fix: preserve terminal live follow through resize`).
It is the "0 regressions" reference for the Rust to Zig port (refs #10).
Every number and output below was captured by running the commands on the machine described in the toolchain section.
The capture tree carried this private fork's CI adaptation on top of `b580103` (changes limited to `.github/workflows/`, `Cargo.toml` package metadata, and `README.md`); `src/`, `tests/`, `scripts/`, `vendor/`, and `docs/` were byte-identical to `b580103`, so every recorded value applies to that commit.

## 1. Toolchain

| Component | Version |
| --- | --- |
| rustc | 1.96.1 (31fca3adb 2026-06-26), pinned by `rust-toolchain.toml` |
| cargo | 1.96.1 (356927216 2026-06-26) |
| cargo-nextest | 0.9.140 (Homebrew) |
| Zig (for vendored libghostty-vt) | 0.15.2 (Homebrew `zig@0.15`) |
| Python | 3.14.6 |
| Platform | macOS 26.4.1 (Darwin 25.4.0), aarch64 (Apple Silicon) |

Environment note: the stock upstream Zig 0.15.2 tarball cannot link natively on this machine because the Xcode 26.4 SDK breaks Zig releases before 0.16 (undefined `libSystem` symbols when linking the build runner; see ziglang/zig issue #31658).
The Homebrew `zig@0.15` formula carries the backported fix and builds the vendored libghostty-vt correctly; `ZIG=/opt/homebrew/opt/zig@0.15/bin/zig` was set for all Cargo commands below.
The vendored tree requires exactly `minimum_zig_version = "0.15.2"`; Zig 0.16.0 rejects the build.

## 2. Test Inventory

Command: `cargo nextest list --locked`

Total: **2788 tests across 10 binaries** (2 of the 10 binaries list no tests on macOS, see below).
The full flat list is committed as [`BASELINE-tests.txt`](./BASELINE-tests.txt).

| Binary | Tests |
| --- | --- |
| `herdr::bin/herdr` (lib + bin unit tests) | 2700 |
| `herdr::live_handoff` | 19 |
| `herdr::server_headless` | 15 |
| `herdr::client_mode` | 12 |
| `herdr::api_ping` | 11 |
| `herdr::detach_reattach` | 11 |
| `herdr::multi_client` | 11 |
| `herdr::cross_area` | 9 |
| `herdr::auto_detect` | 0 on macOS (`#![cfg(not(target_os = "macos"))]`) |
| `herdr::cli_wrapper` | 0 on macOS (`#![cfg(not(target_os = "macos"))]`) |

The `tests/auto_detect.rs` and `tests/cli_wrapper.rs` integration suites are compiled out on macOS, so their counts must be captured on a Linux CI runner to complete the inventory.

## 3. Green State

Command: `cargo nextest run --locked --status-level fail`

```text
Starting 2788 tests across 10 binaries
Summary [  15.866s] 2788 tests run: 2788 passed, 0 skipped
```

- Passed: 2788
- Failed: 0
- Skipped: 0
- Flaky/retried: none
- Wall time: 15.87s (nextest summary), 16.36s real for the whole command

Known-baseline exceptions: none.
Every listed test passes on this machine.

## 4. Python Maintenance Tests

Command:

```bash
python3 -m unittest scripts.test_agent_detection_manifest_check scripts.test_changelog scripts.test_config_reference_check scripts.test_docs_translation_parity scripts.test_preview scripts.test_vendor_libghostty_vt scripts.test_vendor_portable_pty
```

Result: `Ran 85 tests in 75.241s` - **OK** (85 passed, 0 failed, 0 errors, 0 skipped) on Python 3.14.6.

## 5. Binary Behaviors

Built with `cargo build --locked` (dev profile).

### Version output format

```text
$ herdr --version
herdr 0.7.4
```

The format is `herdr <semver>` with no additional metadata.
`-V` is an accepted alias.

### Wire and persistence constants

- `PROTOCOL_VERSION` (`src/protocol/wire.rs`): **17**
- `SNAPSHOT_VERSION` (`src/persist/snapshot.rs`): **3**

### API schema artifact

`docs/next/api/herdr-api.schema.json`:

- sha256: `eaf3eb22915d83e214dfc29578e3003570df410a12f7eb7b9458e4a031006796`
- size: 236830 bytes

### `herdr --help`

```text
herdr — terminal workspace manager for AI coding agents

Usage: herdr [options]
       herdr --session <name> [options]
       herdr --remote <ssh-target> [--session <name>]
       herdr session attach <name>
       herdr completion zsh
       herdr update [--handoff]
       herdr channel set <stable|preview>
       herdr server stop
       herdr server reload-config
       herdr api <subcommand> ...
       herdr completion <shell>
       herdr config <subcommand> ...
       herdr channel <subcommand> ...
       herdr workspace <subcommand> ...
       herdr worktree <subcommand> ...
       herdr tab <subcommand> ...
       herdr notification <subcommand> ...
       herdr agent <subcommand> ...
       herdr pane <subcommand> ...
       herdr wait <subcommand> ...
       herdr session <subcommand> ...
       herdr integration <subcommand> ...

Common commands:
  herdr                            Launch or attach to the persistent session
  herdr status [server|client]     Show local client and running server status
  herdr update                     Download and install the latest version
  herdr completion zsh             Generate shell completions for zsh
  herdr server stop                Stop the running server via the API socket
  herdr channel set <stable|preview> Choose the stable or preview update channel
  herdr server reload-config       Reload config.toml in the running server
  herdr config reset-keys          Back up config.toml and remove custom keybindings
  herdr channel <subcommand>       Manage the stable or preview update channel
  herdr api <subcommand>           Inspect socket API metadata and live runtime state
  herdr workspace <subcommand>     Workspace helpers over the socket API
  herdr worktree <subcommand>      Git worktree helpers over the socket API
  herdr tab <subcommand>           Tab helpers over the socket API
  herdr notification <subcommand>  Notification helpers over the socket API
  herdr agent <subcommand>         Agent/terminal helpers over the socket API
  herdr pane <subcommand>          Pane control helpers over the socket API
  herdr wait <subcommand>          Blocking wait helpers over the socket API
  herdr session <subcommand>       Manage named persistent sessions
  herdr integration <subcommand>   Manage built-in agent integrations

Advanced commands:
  herdr server                     Run as headless server

Options:
  --no-session        Run monolithically (no server/client, escape hatch)
  --session <name>    Use or create a named persistent session
  --remote <target>   Attach through SSH to a remote Herdr server
  --remote-keybindings <local|server>
                      Keybindings for --remote app attach (default: local)
  --handoff           Opt into live handoff for update or remote attach
  --default-config    Print default configuration and exit
  --version, -V       Print version and exit
  --help, -h          Show this help

Config: <config-dir>/config.toml
Logs:   <config-dir>/herdr.log (plus herdr-client.log, herdr-server.log)
Env:    HERDR_CONFIG_PATH overrides config file path
Home:   https://herdr.dev
```

Note: the `Config:`/`Logs:` lines print the machine-local config directory (`~/.config/herdr/` for release builds, `~/.config/herdr-dev/` for debug builds); the paths above are normalized.

### Subcommand help (one level deep)

All 16 subcommands exit 0 for `--help`.

#### `herdr status --help`

```text
herdr status commands:
  herdr status [--json]         show local client and running server status
  herdr status server [--json]  show running server status
  herdr status client [--json]  show local client binary status
```

#### `herdr update --help`

```text
usage: herdr update [--handoff]
```

#### `herdr completion --help`

```text
usage: herdr completion <bash|elvish|fish|powershell|zsh>
```

#### `herdr server --help`

```text
herdr server commands:
  herdr server                run as headless server
  herdr server stop           stop the running server via the API socket
  herdr server live-handoff   hand off live panes to a new local server
  herdr server reload-config  reload config.toml in the running server
  herdr server agent-manifests [--json]  show agent detection manifest status
  herdr server update-agent-manifests [--json]  fetch and reload agent detection manifests
  herdr server reload-agent-manifests  reload agent detection manifests in the running server
```

#### `herdr channel --help`

```text
herdr channel commands:
  herdr channel show                  print the configured update channel
  herdr channel set <stable|preview>  choose the update channel
```

#### `herdr api --help`

```text
herdr api commands:
  herdr api snapshot
  herdr api schema [--json | --output PATH]
```

#### `herdr config --help`

```text
herdr config commands:
  herdr config check  validate config.toml and print diagnostics
  herdr config reset-keys  back up config.toml and remove custom keybindings
```

#### `herdr workspace --help`

```text
herdr workspace commands:
  herdr workspace list
  herdr workspace create [--cwd PATH] [--label TEXT] [--env KEY=VALUE] [--focus] [--no-focus]
  herdr workspace get <workspace_id>
  herdr workspace focus <workspace_id>
  herdr workspace rename <workspace_id> <label>
  herdr workspace report-metadata <workspace_id> --source ID [--token NAME=VALUE] [--clear-token NAME] [--seq N] [--ttl-ms N]
  herdr workspace close <workspace_id>
```

#### `herdr worktree --help`

```text
herdr worktree commands:
  herdr worktree list [--workspace ID | --cwd PATH] [--json]
  herdr worktree create [--workspace ID | --cwd PATH] [--branch NAME] [--base REF] [--path PATH] [--label TEXT] [--focus] [--no-focus] [--json]
  herdr worktree open [--workspace ID | --cwd PATH] (--path PATH | --branch NAME) [--label TEXT] [--focus] [--no-focus] [--json]
  herdr worktree remove --workspace ID [--force] [--json]
```

#### `herdr tab --help`

```text
herdr tab commands:
  herdr tab list [--workspace <workspace_id>]
  herdr tab create [--workspace <workspace_id>] [--cwd PATH] [--label TEXT] [--env KEY=VALUE] [--focus] [--no-focus]
  herdr tab get <tab_id>
  herdr tab focus <tab_id>
  herdr tab rename <tab_id> <label>
  herdr tab close <tab_id>
```

#### `herdr notification --help`

```text
herdr notification commands:
  herdr notification show <title> [--body TEXT] [--position top-left|top-right|bottom-left|bottom-right] [--sound none|done|request]
```

#### `herdr agent --help`

```text
herdr agent commands:
  herdr agent list
  herdr agent get <target>
  herdr agent read <target> [--source visible|recent|recent-unwrapped] [--lines N] [--format text|ansi] [--ansi]
  herdr agent send <target> <text>
  herdr agent prompt <name> <text> [--wait] [--timeout MS]
  herdr agent rename <target> <name>|--clear
  herdr agent focus <target>
  herdr agent wait <name> [--timeout MS]
  herdr agent attach <target> [--takeover]
  herdr agent start <name> --kind KIND --pane ID [--timeout MS] [-- <agent-args...>]
  herdr agent explain <target> [--json]
  herdr agent explain --file PATH --agent LABEL [--json]
  targets accept terminal ids, unique agent names, detected/reported agent labels, and legacy pane ids
  agent send writes literal text; use pane run when you want command text plus Enter
```

#### `herdr pane --help`

```text
herdr pane commands:
  herdr pane list [--workspace <workspace_id>]
  herdr pane current [--pane ID|--current]
  herdr pane get <pane_id>
  herdr pane layout [--pane ID|--current]
  herdr pane process-info [--pane ID|--current]
  herdr pane neighbor --direction left|right|up|down [--pane ID|--current]
  herdr pane edges [--pane ID|--current]
  herdr pane focus --direction left|right|up|down [--pane ID|--current]
  herdr pane resize --direction left|right|up|down [--amount FLOAT] [--pane ID|--current]
  herdr pane zoom [<pane_id>|--pane ID|--current] [--toggle|--on|--off]
  herdr pane rename <pane_id> <label>|--clear
  herdr pane read <pane_id> [--source visible|recent|recent-unwrapped] [--lines N] [--format text|ansi] [--ansi]
  herdr pane split [<pane_id>|--pane ID|--current] --direction right|down [--ratio FLOAT] [--cwd PATH] [--env KEY=VALUE] [--focus] [--no-focus]
  herdr pane swap --direction left|right|up|down [--pane ID|--current]
  herdr pane swap --source-pane ID --target-pane ID
  herdr pane move <pane_id> --tab <tab_id> --split right|down [--target-pane ID] [--ratio FLOAT] [--focus|--no-focus]
  herdr pane move <pane_id> --new-tab [--workspace ID] [--label TEXT] [--focus|--no-focus]
  herdr pane move <pane_id> --new-workspace [--label TEXT] [--tab-label TEXT] [--focus|--no-focus]
  herdr pane close <pane_id>
  herdr pane send-text <pane_id> <text>
  herdr pane send-keys <pane_id> <key> [key ...]
  herdr pane report-agent <pane_id> --source ID --agent LABEL --state idle|working|blocked|unknown [--message TEXT] [--seq N] [--agent-session-id ID] [--agent-session-path PATH]
  herdr pane report-agent-session <pane_id> --source ID --agent LABEL [--seq N] [--agent-session-id ID] [--agent-session-path PATH]
  herdr pane release-agent <pane_id> --source ID --agent LABEL [--seq N]
  herdr pane report-metadata <pane_id> --source ID [--agent LABEL] [--applies-to-source ID] [--title TEXT|--clear-title] [--display-agent TEXT|--clear-display-agent] [--state-label STATUS=TEXT] [--clear-state-labels] [--token NAME=VALUE] [--clear-token NAME] [--seq N] [--ttl-ms N]
  herdr pane run <pane_id> <command>
```

#### `herdr wait --help`

```text
herdr wait commands:
  herdr wait output <pane_id> --match <text> [--source visible|recent|recent-unwrapped] [--lines N] [--timeout MS] [--regex] [--raw]
  herdr wait agent-status <pane_id> --status <idle|working|blocked|done|unknown> [--timeout MS]
```

#### `herdr session --help`

```text
herdr session commands:
  herdr session list [--json]
  herdr session attach <name>
  herdr session stop <name> [--json]
  herdr session delete <name> [--json]
  use 'default' as <name> to target the default session for stop
```

#### `herdr integration --help`

```text
herdr integration commands:
  herdr integration install pi
  herdr integration install omp
  herdr integration install claude
  herdr integration install codex
  herdr integration install copilot
  herdr integration install devin
  herdr integration install droid
  herdr integration install kimi
  herdr integration install opencode
  herdr integration install kilo
  herdr integration install hermes
  herdr integration install qodercli
  herdr integration install cursor
  herdr integration install mastracode
  herdr integration uninstall pi
  herdr integration uninstall omp
  herdr integration uninstall claude
  herdr integration uninstall codex
  herdr integration uninstall copilot
  herdr integration uninstall devin
  herdr integration uninstall droid
  herdr integration uninstall kimi
  herdr integration uninstall opencode
  herdr integration uninstall kilo
  herdr integration uninstall hermes
  herdr integration uninstall qodercli
  herdr integration uninstall cursor
  herdr integration uninstall mastracode
  herdr integration status [--outdated-only]
```

## 6. Platform Matrix

This baseline was captured locally on **macos-arm64** only.

The remaining target platforms are covered by CI (ubuntu, macos, windows runners), and CI is the authority for their baselines:

- linux-x86_64
- linux-aarch64
- macos-x86_64
- windows-x86_64
- windows-aarch64 (if targeted)

Platform-specific deltas known from this capture: `tests/auto_detect.rs` and `tests/cli_wrapper.rs` are compiled only on non-macOS targets, so Linux and Windows baselines include tests that this macOS inventory does not.
