# Deployment

DartClaw is designed for always-on deployment on a Mac Mini or Linux server.

## Quick Deploy

```bash
# 1. Setup (create directories, plist/systemd unit)
dartclaw deploy setup

# 2. Configure (generate dartclaw.yaml from wizard)
dartclaw deploy config

# 3. Secrets (set ANTHROPIC_API_KEY securely)
dartclaw deploy secrets
```

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
| Templates | `packages/dartclaw_server/lib/src/templates` | None (`--templates-dir` not yet available) |
| Static assets | `packages/dartclaw_server/lib/src/static` | `--static-dir` |

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

For `--static-dir`, use the CLI flag to point at the correct location. For templates, the workaround is to ensure the expected directory structure exists relative to `cwd`.

**Note**: This limitation also affects `dart run` when `cwd` is not the pub workspace root — for example, when you want DartClaw's `_local` project to point at a different repository. See [Projects & Git § Limitations](projects-and-git.md#limitations-and-future-considerations) for details.

## macOS (LaunchDaemon)

`dartclaw deploy setup` creates a LaunchDaemon plist at `/Library/LaunchDaemons/com.dartclaw.agent.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.dartclaw.agent</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/dartclaw</string>
    <string>serve</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>UserName</key><string>dartclaw</string>
</dict>
</plist>
```

## Linux (systemd)

`dartclaw deploy setup` creates a systemd unit at `/etc/systemd/system/dartclaw.service`:

```ini
[Unit]
Description=DartClaw Agent Runtime
After=network.target docker.service

[Service]
Type=simple
User=dartclaw
ExecStart=/usr/local/bin/dartclaw serve
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

## Dedicated User

Create a dedicated OS user for isolation:

```bash
# macOS
sudo dscl . -create /Users/dartclaw
# Linux
sudo useradd -r -s /bin/false dartclaw
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
sudo launchctl kickstart -k system/com.dartclaw.agent   # macOS
sudo systemctl restart dartclaw                          # Linux

# 3. Verify
curl -s http://localhost:3000/health | jq .worker
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
curl http://localhost:3000/health
```

Returns JSON with worker state, uptime, and session counts.
