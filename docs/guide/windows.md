# Windows

DartClaw targets the core runtime on native Windows x64: the server, Web UI, harness pool, sessions, and FTS5-backed
storage/search. The 0.21 support contract and qualification path are described below. Unix-coupled security and sidecar
features do not have full Windows parity; the matrix is the support contract.

## Install and Upgrade

Run the checksum-verifying PowerShell installer:

```powershell
irm https://raw.githubusercontent.com/DartClaw/dartclaw/main/install.ps1 | iex
```

It downloads `dartclaw-v<version>-windows-x64.zip` and installs its `VERSION`, `bin/dartclaw.exe`, and
`lib/sqlite3.dll` under `%LOCALAPPDATA%\Programs\DartClaw` by default. It persists
`%LOCALAPPDATA%\Programs\DartClaw\bin` on your user `PATH`. Open a new terminal before checking the installation:

```powershell
dartclaw --version
```

Re-run the installer to upgrade. It stages and verifies the complete replacement before activating it. To use a
different root, download `install.ps1` and pass `-InstallRoot`.

The public Scoop bucket exists and its manifest flow is qualified on native Windows x64, but it has no installable
manifest yet. Use the PowerShell installer until a public Windows release asset and its rendered bucket manifest are
both published. Then use:

```powershell
scoop bucket add dartclaw https://github.com/DartClaw/scoop-dartclaw
scoop install dartclaw/dartclaw
scoop update dartclaw
```

## Provider Setup

Install Claude Code or Codex separately, complete its normal sign-in flow, and verify it before starting DartClaw:

```powershell
claude auth login
claude auth status

codex login
codex login status
```

### Codex project trust

Codex may emit this provider-setup warning for an untrusted project:

> Project-local config, hooks, and exec policies are disabled until the project is trusted.

This means files under the project's `.codex` directory are intentionally ignored. If you require those local
settings, add the exact project path to `~/.codex/config.toml` and restart the worker or DartClaw:

```toml
[projects."C:\\path\\to\\your\\project"]
trust_level = "trusted"
```

Trust only projects whose local Codex configuration you have reviewed.

## Capability Matrix

| Capability | State | Windows behavior | Remediation |
|---|---|---|---|
| Core server, Web UI, and sessions | supported | The qualification candidate artifact passes the full runtime smoke on native Windows x64 | Keep the release artifact's `bin/` and `lib/` directories together |
| Claude and Codex harness turns | supported | Both live provider transports pass on native Windows ARM64 against the production tree used by the qualified x64 artifact | Install and authenticate the provider CLIs |
| FTS5 storage/search | supported | Uses the release's bundled `lib/sqlite3.dll`; it does not depend on `winsqlite3.dll` | Keep `bin/` and `lib/` as sibling directories |
| Config reload | supported | Use file watching with `gateway.reload.mode: auto`; SIGUSR1 is POSIX-only | Enable `auto` and save the config file atomically |
| Bash workflow steps | degraded | Run through Git Bash when `bash.exe` is found; otherwise the step fails with `bash steps require Git Bash on Windows`. Timeout cleanup does not claim descendant-process containment; unconfirmed cleanup blocks later Bash steps until restart | Install Git for Windows; use POSIX for commands requiring process-tree containment |
| Container isolation | unavailable | Native Windows fails closed because the credential proxy and owner-only permissions require POSIX facilities | Run DartClaw on a POSIX host or in WSL |
| Channel sidecars | unverified | Native Windows operation of GOWA and signal-cli sidecar paths is not qualified | Run channel sidecars on a supported POSIX deployment or validate them independently |
| Provider sandbox parity | unverified | Claude's native sandbox is unavailable; restrictive Codex sandbox modes were not qualified for the Windows release | Use a POSIX host or WSL when a qualified isolation boundary is required |

For Windows config reload, use:

```yaml
gateway:
  reload:
    mode: auto
```

`gateway.reload.mode: signal` is not a Windows reload path. A signal-trigger attempt reports that SIGUSR1 is
POSIX-only and points back to file-watch `auto` mode.

## Runtime Smoke Validation

The release-readiness profile checks each layer separately: server startup, Web UI load, FTS5 `MATCH` using the
bundled DLL, file-watch config reload, a Claude turn, and a Codex turn.

From a native Windows x64 checkout, run it against a release artifact:

```powershell
./dev/testing/profiles/windows-runtime/run.ps1 `
  -ArtifactPath ./build/dartclaw-v<version>-windows-x64.zip
```

Read `dev/testing/evidence/windows-runtime-smoke.md`. The result is release-ready only when every required layer
passes. If CI cannot access provider credentials, only the Claude/Codex turn layers may be skipped, and committed
manual evidence must cover both providers on native Windows with matching release version or source revision,
OS/architecture, provider versions, artifact or source identity, and passing stored turn results. Missing, stale, or
single-provider evidence leaves the result `incomplete`; it must not be reported as Windows support.

Source-mode smoke is useful for diagnosis, but it does not replace native x64 artifact, bundled-SQLite, installer, or
process-lifecycle qualification.
