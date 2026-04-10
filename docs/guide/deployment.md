# Deployment

DartClaw is designed for always-on deployment on a Mac Mini or Linux server.

## Quick Deploy

```bash
# 1. Set up your instance (config, workspace, onboarding)
dartclaw init

# 2. Install as a user-scoped background service
dartclaw service install --instance-dir ~/.dartclaw

# 3. Start the service
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

Launch handoff options are `--launch foreground`, `--launch background`, `--launch service`, and `--launch skip` (default).

### Old deploy workflow (deprecated)

The old three-step `dartclaw deploy setup / config / secrets` workflow used root-scoped system daemons. Use `dartclaw init` + `dartclaw service` instead. `dartclaw deploy setup` now emits a deprecation notice and redirects to `dartclaw init`.

## AOT Compilation

Compile DartClaw to a native binary for production:

```bash
dart compile exe apps/dartclaw_cli/bin/dartclaw.dart -o dartclaw
```

The resulting binary has zero runtime dependencies (no Dart SDK needed).

### Running Outside the Source Tree

The compiled binary (and `dart run`) expects **templates** and **static assets** at paths relative to `cwd`:

| Asset | Default path (relative to cwd) | CLI flag |
|-------|-------------------------------|----------|
| Templates | `packages/dartclaw_server/lib/src/templates` | `--source-dir` or `--templates-dir` |
| Static assets | `packages/dartclaw_server/lib/src/static` | `--source-dir` or `--static-dir` |

If you run the binary from a directory other than the source root, template loading fails at startup with `Template validation failed: Missing templates: ...`.

**Workarounds**:

```bash
# Option 1: Run from the source root (simplest)
cd /path/to/dartclaw-public
./dartclaw serve --config /path/to/your/dartclaw.yaml

# Option 2: Symlink the template directory into your working directory
mkdir -p packages/dartclaw_server/lib/src
ln -s /path/to/dartclaw-public/packages/dartclaw_server/lib/src/templates \
      packages/dartclaw_server/lib/src/templates

# Option 3: Copy templates alongside the binary
cp -r /path/to/dartclaw-public/packages/dartclaw_server/lib/src/templates \
      packages/dartclaw_server/lib/src/templates
cp -r /path/to/dartclaw-public/packages/dartclaw_server/lib/src/static \
      packages/dartclaw_server/lib/src/static
```

When you install a service from the repository root, `dartclaw service install` automatically carries `--source-dir` into the generated unit so background services keep the right runtime context. For manual runs, pass `--source-dir /path/to/dartclaw-public` explicitly if needed.

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
curl -s http://localhost:3333/health | jq .worker
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
