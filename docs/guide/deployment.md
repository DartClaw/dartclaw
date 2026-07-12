# Deployment

DartClaw runs on macOS, Linux, and native Windows x64. The built-in background-service commands currently target
macOS and Linux; on native Windows, run `dartclaw serve` in a terminal or under operator-managed process supervision.

## Quick Deploy

```bash
# 1. Install DartClaw
brew tap DartClaw/dartclaw
brew install dartclaw
dartclaw --version

# 2. Verify provider CLIs separately
claude --version
codex --version

# 3. Set up your instance (config, workspace, onboarding)
dartclaw init

# 4. Install as a user-scoped background service
dartclaw service install --instance-dir ~/.dartclaw

# 5. Start the service
dartclaw service start --instance-dir ~/.dartclaw
```

### Service Management

`dartclaw service` manages DartClaw as a user-scoped background service — no root required. Service units are instance-scoped, so multiple instance directories can coexist without overwriting each other:

```bash
dartclaw service install --instance-dir ~/.dartclaw
dartclaw service start --instance-dir ~/.dartclaw
dartclaw service stop --instance-dir ~/.dartclaw
dartclaw service status --instance-dir ~/.dartclaw
dartclaw service uninstall --instance-dir ~/.dartclaw
```

The service resolves its target instance from `--instance-dir`, then `--config`, then the standard discovery order: `DARTCLAW_CONFIG` > `DARTCLAW_HOME` > `~/.dartclaw/dartclaw.yaml`.

Or combine setup and service install in one step:

```bash
dartclaw init --launch=service   # Set up and install + start the service
```

### Verification States

`dartclaw init` completes with one of two states before any launch handoff:

- `verified`: local checks passed and the selected provider already has usable credentials or CLI login.
- `configured but unverified`: local checks passed, but provider verification was skipped (`--skip-verify`) or still needs login/API-key setup.

Launch handoff options are `--launch=foreground`, `--launch=background`, `--launch=service`, and `--launch=skip` (default).

### Old deploy workflow (deprecated)

The old `dartclaw deploy` workflow generated root-scoped system daemons (macOS LaunchDaemon, systemd `multi-user.target`). The `deploy setup` step has been removed — its prerequisite checks now live in `dartclaw init`. Use `dartclaw init` + `dartclaw service` instead. The remaining `deploy config` / `deploy secrets` subcommands still exist but are superseded.

## Standalone Binary

Use Homebrew for macOS/Linux releases:

```bash
brew tap DartClaw/dartclaw
brew install dartclaw
dartclaw --version
```

On Windows x64, use the checksum-verifying PowerShell installer:

```powershell
irm https://raw.githubusercontent.com/DartClaw/dartclaw/main/install.ps1 | iex
```

It installs `dartclaw-v<version>-windows-x64.zip` at `%LOCALAPPDATA%\Programs\DartClaw` by default and persists
`%LOCALAPPDATA%\Programs\DartClaw\bin` on the user `PATH`. Re-run the command to upgrade atomically, then open a new
terminal. A Scoop bucket is planned but not yet published or independently qualified. After publication, its commands
will be:

```powershell
scoop bucket add dartclaw https://github.com/DartClaw/scoop-dartclaw
scoop install dartclaw/dartclaw
scoop update dartclaw
```

See [Windows](windows.md) for provider setup, smoke validation, and capability limits.

DartClaw does not install provider CLIs. Install and verify `claude`, `codex`, Goose, Vibe, or any future provider binary separately before selecting that provider in configuration:

```bash
claude --version
codex --version
```

Use the repo build entrypoint to produce the production binary from source:

```bash
bash dev/tools/build.sh
```

`dev/tools/build.sh` runs `dart build cli` to produce `build/bin/dartclaw` alongside a bundled SQLite library in
`build/lib/` (`libsqlite3.dylib` on macOS, `libsqlite3.so` on Linux), then packs `VERSION`, `bin/dartclaw`, and
`lib/` into `build/dartclaw-v{VERSION}-{os}-{arch}.tar.gz` plus its checksum. Windows releases are built natively
with `dev/tools/build_windows.ps1` and packaged as `dartclaw-v<version>-windows-x64.zip` with
`bin/dartclaw.exe` and `lib/sqlite3.dll`. The binary resolves the library
relative to itself, so `bin/` and `lib/` must stay siblings. Templates, static assets, skills, and workflows are
embedded in the executable, so it needs no companion asset files and no first-run network request. `dart build cli`
cannot cross-compile: each release target (`macos-arm64`, `macos-x64`, `linux-x64`, `linux-arm64`, `windows-x64`)
must be built on a native runner for that OS/arch.

```bash
build/bin/dartclaw serve --config /path/to/dartclaw.yaml --data-dir /tmp/dartclaw
```

### Running Outside the Source Tree

Clone-based and development runs can still read the workspace directly. `dart run ...`, `dartclaw serve --dev`,
and explicit `--source-dir` / `--templates-dir` / `--static-dir` overrides take precedence over embedded content,
preserving template hot-reload and local workflow edits. Packaged installs use embedded content automatically.

When you install a service from the repository root for a clone-based deployment, `dartclaw service install`
automatically carries `--source-dir` into the generated unit so background services keep the right runtime
context. Packaged installs need no source path because their assets are embedded.

**Note**: This limitation also affects `dart run` when `cwd` is not the pub workspace root — for example, when you want DartClaw's `_local` project to point at a different repository. See [Projects & Git § Limitations](projects-and-git.md#limitations-and-future-considerations) for details.

## macOS (LaunchAgent)

`dartclaw service install --instance-dir ~/.dartclaw` creates a user-scoped LaunchAgent at `~/Library/LaunchAgents/com.dartclaw.agent.<instance-hash>.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.dartclaw.agent.3f1c9a4b</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/dartclaw</string>
    <string>serve</string>
    <string>--config</string>
    <string>/Users/you/.dartclaw/dartclaw.yaml</string>
    <string>--source-dir</string>
    <string>/path/to/dartclaw-public</string>
  </array>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><false/>
</dict>
</plist>
```

The agent runs as your user — no `sudo` or dedicated OS user needed. To have it start at login, set `RunAtLoad` to `true` in the plist.

## Linux (systemd --user)

`dartclaw service install --instance-dir ~/.dartclaw` creates a user-scoped unit at `~/.config/systemd/user/dartclaw-<instance-hash>.service`:

```ini
[Unit]
Description=DartClaw Agent Runtime (dartclaw-3f1c9a4b)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/dartclaw serve --config /home/you/.dartclaw/dartclaw.yaml --source-dir /path/to/dartclaw-public
WorkingDirectory=/home/you/.dartclaw
Restart=on-failure
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=default.target
```

This is a `systemd --user` unit — no root or system administrator needed. Enable auto-start at login with:

```bash
loginctl enable-linger $USER   # allow user units to run without active session
```

## Egress Firewall

Restrict outbound network access to only required services:

### macOS (pf)
```
# /etc/pf.anchors/dartclaw
pass out proto tcp from any to any port 443   # Anthropic API
block out quick user dartclaw
```

### Linux (nftables)
```
table inet dartclaw {
  chain output {
    type filter hook output priority 0;
    meta skuid dartclaw tcp dport 443 accept
    meta skuid dartclaw drop
  }
}
```

## Maintaining Agent Binaries

DartClaw does **not** auto-update the `claude` CLI, Codex, or channel sidecar binaries (GOWA, signal-cli). You are responsible for keeping them current.

### How updates propagate

Running harness processes hold the old binary in memory. Updating the binary on disk (e.g. via `claude update` or Homebrew) does **not** affect already-running processes. A harness picks up the new binary only when it next spawns a process, which happens on:

- **Server restart** (recommended for planned updates)
- **Crash recovery** (automatic — exponential backoff restart)
- **Task execution restart** (when working directory or model changes between turns)

### Recommended update procedure

```bash
# 1. Update the binary
claude update            # or: brew upgrade claude-code

# 2. Restart DartClaw to pick up the new version
dartclaw service stop && dartclaw service start   # via service command
# or manually:
launchctl kill TERM gui/$(id -u)/com.dartclaw.agent.3f1c9a4b          # macOS
systemctl --user restart dartclaw-3f1c9a4b                            # Linux

# 3. Verify
curl -s http://localhost:3333/health | jq .worker_state
```

On restart, DartClaw runs a version probe (`claude --version`) and logs the detected version. Check the startup log to confirm the expected version.

### Why restart is necessary

There is no graceful rolling restart yet — DartClaw cannot drain active turns and selectively restart idle harnesses. A full server restart is the only way to guarantee all harnesses use the same binary version. In-flight turns are interrupted; NDJSON cursor-based crash recovery will resume them on the new process.

A future milestone ([0.next-always-on](https://github.com/dartclaw)) plans graceful binary updates and staleness detection via `dartclaw doctor`.

### Version compatibility

DartClaw does not enforce version compatibility between itself and the agent binary. Protocol mismatches (e.g., after a major `claude` CLI update that changes the JSONL protocol) will surface as parse errors in the harness log. If you see unexpected JSONL errors after a binary update, check the [Claude Code changelog](https://claude.ai/changelog) for breaking protocol changes.

## Health Monitoring

Check agent health:

```bash
curl http://localhost:3333/health
```

Returns JSON with worker state, uptime, and session counts.
