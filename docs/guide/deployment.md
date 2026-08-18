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

- `verified`: local checks passed and the selected provider already has a credential DartClaw can resolve – an API key, a subscription credential stored by `dartclaw auth claude` / `dartclaw auth codex`, or the provider CLI's own login. A forced `providers.<id>.auth` that cannot be satisfied is not rescued by the CLI login, exactly as at admission.
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
terminal. The public Scoop bucket exists and its manifest flow is qualified on native Windows x64, but it remains
empty until a public Windows release asset and its rendered bucket manifest are both published. Then use:

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
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>/opt/homebrew/bin:/Users/you/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>KeepAlive</key><true/>
  <key>RunAtLoad</key><false/>
</dict>
</plist>
```

The agent runs as your user — no `sudo` or dedicated OS user needed. Installation snapshots the absolute entries from
the current shell's `PATH` into the plist, so provider CLIs and channel sidecars resolve the same way during verification
and service startup. If that PATH changes, run `dartclaw service install` again to refresh the loaded definition. To have
it start at login, set `RunAtLoad` to `true` in the plist.

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

If container isolation is enabled and the unit runs as a user other than uid 1000, the container's mounted state
directories need a uid alignment the service cannot perform unprivileged — grant `CAP_CHOWN` or use rootless/
userns-remapped Docker. See [File Ownership on Native Linux](security.md#file-ownership-on-native-linux).

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

DartClaw disables Claude's background updater and nonessential network traffic in the Claude subprocesses it starts.
This prevents a running pool from changing underneath the host. It does not affect `claude update` run separately by
an operator or maintenance service.

### Provider update commands

| Installation | Update | Diagnose |
|--------------|--------|----------|
| Claude native installer | `claude update` | `claude doctor` |
| Codex release with self-update support | `codex update` | `codex doctor` |
| Homebrew, WinGet, npm, apt, dnf, or apk | Use the package manager that installed the CLI | Run the provider's `doctor` command afterward |

`claude update` follows the configured Claude release channel. `codex update` works only when the installed release
supports self-update. See the official [Claude Code setup guide](https://code.claude.com/docs/en/setup) and
[Codex CLI guide](https://learn.chatgpt.com/docs/codex/cli) for package-manager-specific commands.

### How updates propagate

Running harness processes hold the old binary in memory. Updating the binary on disk (e.g. via `claude update` or Homebrew) does **not** affect already-running processes. A harness picks up the new binary only when it next spawns a process, which happens on:

- **Server restart** (recommended for planned updates)
- **Crash recovery** (automatic — exponential backoff restart)
- **Task execution restart** (when working directory or model changes between turns)

### Recommended update procedure

```bash
# 1. Stop DartClaw so no turn is using the binary
dartclaw service stop --instance-dir /absolute/path/to/instance

# 2. Update each configured provider
claude update
codex update

# 3. Confirm the installed versions
claude --version
codex --version

# 4. Start DartClaw and verify health
dartclaw service start --instance-dir /absolute/path/to/instance
curl -s http://localhost:3333/health | jq .worker_state
```

Run only the provider commands relevant to your configuration, and substitute the package-manager update command when
the CLI is package-managed. Use the same explicit instance selector for both service commands and the configured port
for the health check. On startup, DartClaw probes each configured provider with `--version` and exposes the result
through `GET /api/providers` and the Settings page. Confirm that every configured provider is healthy and reports the
expected version; `/health` verifies the DartClaw host, not its providers.

### Optional scheduled maintenance

An external daily provider update job is possible when brief, scheduled interruption is acceptable. DartClaw cannot
make the update atomic or protect against a bad provider release. Run it through launchd, systemd, or Windows Task
Scheduler – not as a DartClaw task or workflow. The job should:

1. Stop the exact DartClaw instance.
2. Run the install-method-specific update commands.
3. Record the version and run diagnostics for each configured provider.
4. Start the same instance even if an update fails.
5. Check its host health and provider status, then alert on any failure.

Stopping first prevents new harness processes from starting against an updated binary while old processes still run.
Until graceful draining exists, an unattended update can interrupt an in-flight turn; schedule it only when that
trade-off is acceptable. DartClaw does not roll back a provider update.

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
