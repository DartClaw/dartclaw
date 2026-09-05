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

`dartclaw service` is the only install path. It manages DartClaw in one of two scopes — user-scoped by default (no root
required), or system-scoped with `--system` (boot-started, root-installed). Service units are instance-scoped in both
scopes, so multiple instance directories can coexist without overwriting each other:

```bash
dartclaw service install --instance-dir ~/.dartclaw
dartclaw service start --instance-dir ~/.dartclaw
dartclaw service stop --instance-dir ~/.dartclaw
dartclaw service status --instance-dir ~/.dartclaw
dartclaw service uninstall --instance-dir ~/.dartclaw
```

The service resolves its target instance from `--instance-dir`, then `--config`, then the standard discovery order: `DARTCLAW_CONFIG` > `DARTCLAW_HOME` > `~/.dartclaw/dartclaw.yaml`. A symlinked `dartclaw.yaml` is fine at any of these: config writes resolve the link and land in its target.

Or combine setup and service install in one step:

```bash
dartclaw init --launch=service   # Set up and install + start the service
```

### Verification States

`dartclaw init` completes with one of two states before any launch handoff:

- `verified`: local checks passed and the selected provider already has a credential DartClaw can resolve – an API key, a subscription credential stored by `dartclaw auth claude` / `dartclaw auth codex`, or the provider CLI's own login. A forced `providers.<id>.auth` that cannot be satisfied is not rescued by the CLI login, exactly as at admission.
- `configured but unverified`: local checks passed, but provider verification was skipped (`--skip-verify`) or still needs login/API-key setup.

Launch handoff options are `--launch=foreground`, `--launch=background`, `--launch=service`, and `--launch=skip` (default).

### System-scoped service (boot-started)

Add `--system` to any `service` subcommand to manage a boot-started daemon instead of a login-session service — a macOS
LaunchDaemon in `/Library/LaunchDaemons`, or a systemd unit in `/etc/systemd/system` wanted by `multi-user.target`:

```bash
sudo dartclaw service install --system --instance-dir /opt/dartclaw
sudo dartclaw service start   --system --instance-dir /opt/dartclaw
sudo dartclaw service status  --system --instance-dir /opt/dartclaw
sudo dartclaw service uninstall --system --instance-dir /opt/dartclaw
```

- **System scope requires root.** `install`, `uninstall`, `start` and `stop` refuse without it, naming the missing
  privilege, and write nothing; `status` cannot determine the state either and reports `unknown` with the same
  `sudo` hint.
- **Name the instance explicitly.** `sudo` replaces `HOME` with root's on most distributions, so system scope refuses
  to guess: pass `--instance-dir <path>` or `--config <path>`.
- **The daemon does not run as root.** The run-as user comes from `SUDO_USER`, or from `--service-user <name>`. If
  neither resolves, install refuses rather than installing a root-running daemon.
- **Make the instance directory writable by that user** — `sudo` installs it as root, and the daemon runs as the
  named operator.
- **No secret is written into a unit file.** System-scoped units resolve credentials from config and the
  `dartclaw auth` stores exactly as user-scoped units do.

The two scopes are independent: installing, removing, or stopping one leaves the other's unit for the same instance
directory untouched.

## Standalone Binary

Use Homebrew for macOS/Linux releases:

```bash
brew tap DartClaw/dartclaw
brew install dartclaw
dartclaw --version
```

Workflow-only hosts can instead install `brew install DartClaw/dartclaw/dartclaw-workflow` and use flat commands
such as `dartclaw-workflow run my-flow`. The formula keeps its executable and SQLite under its own `libexec/`,
with a `bin/dartclaw-workflow` symlink, so both formulas can be installed together. The lean Windows ZIP is a
separate release asset for manual extraction; the installer and Scoop package below install the full binary.

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

`dev/tools/build.sh` runs `dart build cli` for both entry points, producing `build/bin/dartclaw` and
`build/bin/dartclaw-workflow` with one bundled SQLite library in `build/lib/` (`libsqlite3.dylib` on macOS,
`libsqlite3.so` on Linux). It emits `build/dartclaw-v{VERSION}-{os}-{arch}.tar.gz` and
`build/dartclaw-workflow-v{VERSION}-{os}-{arch}.tar.gz`, each with its own checksum, `VERSION`, executable in
`bin/`, and SQLite in `lib/`. Windows builds use `dev/tools/build_windows.ps1` to emit
`dartclaw-v<version>-windows-x64.zip` and `dartclaw-workflow-v<version>-windows-x64.zip`, each with `VERSION`,
its matching `.exe` in `bin/`, and `lib/sqlite3.dll`. Each binary resolves the library
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

## macOS (launchd)

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
  <key>WorkingDirectory</key>
  <string>/Users/you/.dartclaw</string>
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

The agent runs as your user — no `sudo` or dedicated OS user needed. `WorkingDirectory` pins the process cwd to the
instance directory; without it launchd starts the agent at `/`, which DartClaw would treat as its local project root and
walk on every start, triggering macOS privacy prompts for `~/Downloads` and mounted volumes. Installation snapshots the absolute entries from
the current shell's `PATH` into the plist, so provider CLIs and channel sidecars resolve the same way during verification
and service startup. If that PATH changes, run `dartclaw service install` again to refresh the loaded definition. To have
it start at login, set `RunAtLoad` to `true` in the plist.

`sudo dartclaw service install --system` writes the same definition to `/Library/LaunchDaemons/` instead, with
`RunAtLoad` set to `true` and a `UserName` key naming the run-as operator, and bootstraps it into the `system` domain.

## Linux (systemd)

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

`sudo dartclaw service install --system` writes the same unit to `/etc/systemd/system/` instead, adding
`User=<run-as operator>`, `WantedBy=multi-user.target`, and the filesystem-hardening directives `ProtectSystem=strict`,
`ProtectHome=read-only`, `ReadWritePaths=<instance dir>` and `PrivateTmp=true`, and raising `Restart` to `always` so a
boot daemon returns from a clean exit the way macOS `KeepAlive` does. It is enabled with `systemctl` without `--user`,
so it starts at boot with no lingering session required.

`ProtectSystem=strict` and `ProtectHome=read-only` make everything outside `ReadWritePaths` read-only for the daemon —
including the harness home (`~/.claude`, `~/.codex`) and any project root outside the instance directory. Add each such
path to `ReadWritePaths` before agent turns need to write there.

If container isolation is enabled and the unit runs as a user other than uid 1000, the container's mounted state
directories need a uid alignment the service cannot perform unprivileged — grant `CAP_CHOWN` or use rootless/
userns-remapped Docker. See [File Ownership on Native Linux](security.md#file-ownership-on-native-linux).

## Secrets and the Service Unit

A generated LaunchAgent or systemd unit is **regenerated** by the next `dartclaw service install`. A secret hand-added
to its `EnvironmentVariables` dict or an `Environment=` line is therefore lost on the next install, silently, and the
service comes back up without the credential it had.

Since 0.24.3 that is avoidable: store the secret instead.

```bash
dartclaw secrets set brave-search --type api-key       # masked prompt; nothing in argv or shell history
```

Then reference it from config:

```yaml
search:
  providers:
    brave:
      enabled: true
      credential: brave-search
```

The value lives at `<data_dir>/credentials/named/brave-search.json`, outside the generated unit, so a reinstall cannot
lose it and no key appears in `dartclaw.yaml`. Every config load re-reads the store, so the next reload — SIGUSR1, a
file-watch reload, or a web-UI edit — sees a new value; `credentials` is a restart-tier section, so the reload reports
it as restart-required and the running service applies it at its next restart. See
[Security § Named Credential Storage](security.md#named-credential-storage) for what the store does and does not
protect, and [CLI Reference § Secrets](cli-reference.md#secrets) for the commands.

**`${VAR}` delivery keeps working unchanged.** Nothing about environment-delivered secrets is deprecated or removed: a
deployment that injects secrets from an external secret manager into the serve process environment should keep doing
so. The store is the answer for a secret that had nowhere better to live than a generated unit file. Run
`dartclaw secrets audit` to see which of your secrets are in which place; it exits non-zero on any finding, so it can
gate a deploy.

`dartclaw deploy secrets` belongs to the superseded `deploy` path and is unchanged — prefer `dartclaw secrets set`.

## Egress Firewall

**The rule sets below are a default-drop allowlist scoped to the service account.** That is the model the retired
`dartclaw deploy` generators produced; it replaces the weaker per-uid blocklist this guide carried until 0.25, which
had no default policy, no connection-tracking or loopback accepts, and no DNS allowances. Reproduce them by hand —
DartClaw ships no generator, and the `deploy` command that once emitted them is gone.

Run DartClaw as its own account (`dartclaw` below) so the policy can name it. Everything that account sends is
dropped unless a rule allows it; every other account on the host is untouched.

**These rules do not reach container traffic.** A `network:none` container has no egress at all and reaches the
network only through the host gateway, which mediates provider and MCP calls on the host's own credentials — so
gateway traffic leaves as the DartClaw account and is covered here. On Docker Desktop, container traffic that does
escape leaves through the VM's own stack, which a host firewall does not see. Treat these rules as host-level
defence in depth, not as the container boundary.

Substitute your own resolvers and endpoints: the DNS servers below are examples, and you need one `443` allowance
per provider and per allowlisted MCP or search endpoint your deployment actually calls.

### macOS (pf)

Rule order matters. `pf` applies the *last* matching rule unless a rule says `quick`, so every allowance is `quick`
and the final block is `quick` too — written without it, the trailing block would win over the allowances above it
and the account would have no egress at all.

```
# /etc/pf.anchors/dartclaw — load with: sudo pfctl -f /etc/pf.conf
# Referenced from /etc/pf.conf as:  anchor "dartclaw"
anchor "dartclaw" {
  # Loopback first: the local API, the web UI and the gateway pipes never leave the host.
  pass out quick on lo0 all

  # DNS.
  pass out quick proto { tcp, udp } from any to { 1.1.1.1, 8.8.8.8 } port 53 user dartclaw keep state

  # One line per endpoint the deployment calls.
  pass out quick proto tcp from any to api.anthropic.com port 443 user dartclaw keep state

  # Default drop for this account. Anything not allowed above stops here.
  block out quick user dartclaw
}
```

`keep state` is pf's default on a `pass` rule and is written out here so the connection-tracking behaviour is
visible rather than implied.

### Linux (nftables)

```
#!/usr/sbin/nft -f
# Apply with: sudo nft -f /etc/nftables.d/dartclaw.conf

table inet dartclaw {
  chain output {
    type filter hook output priority 0; policy drop;

    # Everything not run by the service account is out of scope. This rule must
    # come first: the chain's policy is drop, so without it the whole host loses
    # egress rather than just DartClaw.
    meta skuid != dartclaw accept

    # Replies on connections the account already opened.
    ct state established,related accept

    # Loopback.
    oifname "lo" accept

    # DNS.
    ip daddr { 1.1.1.1, 8.8.8.8 } tcp dport 53 accept
    ip daddr { 1.1.1.1, 8.8.8.8 } udp dport 53 accept

    # One line per endpoint the deployment calls.
    ip daddr api.anthropic.com tcp dport 443 accept
  }
}
```

`nft` resolves a hostname once, when the ruleset is loaded, and stores the addresses it got. An endpoint behind a
rotating CDN address will start failing without the rules changing; pin the addresses you intend to allow, or
reload the ruleset on a schedule.

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

`dartclaw doctor` compares the running server version with the CLI version and warns when they differ. It does not check upstream releases for staleness.

### Version compatibility

DartClaw does not enforce version compatibility between itself and the agent binary. Protocol mismatches (e.g., after a major `claude` CLI update that changes the JSONL protocol) will surface as parse errors in the harness log. If you see unexpected JSONL errors after a binary update, check the [Claude Code changelog](https://claude.ai/changelog) for breaking protocol changes.

## Health Monitoring

Check agent health:

```bash
curl http://localhost:3333/health
```

Returns JSON with worker state, uptime, and session counts.
