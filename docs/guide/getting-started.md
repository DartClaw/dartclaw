# Getting Started

DartClaw is a security-conscious AI agent runtime. A Dart host coordinates state, security, and the web UI while a native agent CLI handles turns.

## Prerequisites

| Dependency | Version | Purpose |
|-----------|---------|---------|
| Homebrew | Latest | DartClaw install path on macOS and Linux |
| PowerShell | 5.1+ | Qualified Windows installer; Scoop requires a public Windows asset and bucket manifest |
| Dart SDK | ^3.13.0 | Build toolchain for source checkouts and development runs |
| `claude` CLI | Stable channel | Agent binary — default provider (see [Deployment § Maintaining Agent Binaries](deployment.md#maintaining-agent-binaries) for update guidance) |
| `codex` CLI | Current release | Agent binary — optional, for OpenAI models (see [Deployment § Maintaining Agent Binaries](deployment.md#maintaining-agent-binaries) for update guidance) |
| Goose or Vibe | Latest | Optional ACP agent binaries; install only when configured under `harness.acp.agents` |
| SQLite | Bundled | FTS5 search library shipped with release builds |

Install DartClaw first, then install and verify provider CLIs separately. This example uses Homebrew on macOS/Linux;
see [Windows](windows.md) for native Windows installation and support boundaries.

```bash
brew tap DartClaw/dartclaw
brew install dartclaw
dartclaw --version

# Provider CLI — Claude (default provider; delayed stable channel recommended)
curl -fsSL https://claude.ai/install.sh | bash -s stable
claude --version

# Provider CLI — Codex (optional, for OpenAI models)
curl -fsSL https://chatgpt.com/codex/install.sh | sh
codex --version

# ACP agents — optional, install separately from DartClaw
goose --version
vibe-acp --version
```

Auth: subscription credentials are the default, and storing one is a step of [Quick Start](#quick-start) rather than a
prerequisite – `dartclaw auth` writes into the instance's own credential store, which does not exist until `dartclaw
init` has chosen the instance's `data_dir`. Exporting `ANTHROPIC_API_KEY` / `CODEX_API_KEY` instead keeps the API-key
path, which is the recommended choice for host-mode deployments running less-trusted agents – see
[Security § Authentication Modes](security.md#authentication-modes).

The provider-native installers give the simplest maintenance path. Package-manager installations are also supported,
but must be updated through the same package manager that installed them. Claude's stable channel is typically about
one week behind latest and skips releases with major regressions.

## Install DartClaw

Use Homebrew on macOS/Linux:

```bash
brew tap DartClaw/dartclaw
brew install dartclaw
dartclaw --version
```

On Windows x64, run the PowerShell installer from a trusted release checkout:

```powershell
irm https://raw.githubusercontent.com/DartClaw/dartclaw/main/install.ps1 | iex
```

The installer downloads `dartclaw-v<version>-windows-x64.zip`, verifies its checksum, and installs the complete
`VERSION` + `bin` + `lib` tree under `%LOCALAPPDATA%\Programs\DartClaw` by default. It adds
`%LOCALAPPDATA%\Programs\DartClaw\bin` to your persistent user `PATH`; open a new terminal before running
`dartclaw --version`. The public Scoop bucket and its qualified commands are recorded in the
[Windows guide](windows.md); they become usable after both the Windows release asset and rendered manifest publish.

Provider CLIs are not Homebrew dependencies of DartClaw. Install the providers you plan to use and verify them explicitly:

```bash
claude --version
codex --version
goose --version
vibe-acp --version
```

If you are working from a source checkout, build the standalone binary directly:

```bash
git clone <repo-url> && cd dartclaw
dart pub get
bash dev/tools/build.sh
build/bin/dartclaw --version
```

The build produces `build/bin/dartclaw` alongside a `build/lib/` holding the bundled SQLite library; keep the two directories together when relocating.

All command examples below use `dartclaw`. If you have not installed it onto `PATH`, replace `dartclaw` with `build/bin/dartclaw`.

## Quick Start

The fastest path to a running DartClaw instance:

```bash
# 1. Set up the instance. It finishes by printing: Done. Config written to <path>
dartclaw init

# 2. Store a provider credential against the instance step 1 just wrote.
#    CONFIG is the path step 1 printed — ~/.dartclaw/dartclaw.yaml unless you chose another instance directory.
CONFIG=~/.dartclaw/dartclaw.yaml
claude setup-token
dartclaw --config "$CONFIG" auth claude

# 3. Start the server
dartclaw serve --config "$CONFIG"

# 4. Open http://127.0.0.1:3333
```

Step 2 must come after step 1, and both must resolve the same store. `dartclaw auth` writes into
`<data_dir>/credentials/`, and `data_dir` is written by `init` — running `auth` first stores the credential against
whatever `data_dir` was in effect then, which `init` may change underneath you. Two more things decide which store is
resolved:

- **Use the `--config` path `init` printed**, not an assumed one. A different instance directory means a different
  `data_dir`, and therefore a different credential store.
- **Pass `--data-dir` whenever `serve` does.** A `serve --data-dir` overrides the YAML value, so
  `dartclaw --config "$CONFIG" auth claude --data-dir <same path>` is what puts the credential where that server reads.
  The same applies when `data_dir` is relative (`dartclaw init --workflow` writes `data_dir: .`): run `auth` from the
  same working directory the server runs in, or pass an absolute `--data-dir`.

A credential written against a different `data_dir` is invisible to the server, which then refuses the provider as if
nothing were stored. The refusal names the directory it searched — compare it against the path `dartclaw auth` printed.

For Codex (`provider: codex`), step 2 is `dartclaw --config "$CONFIG" auth codex`, which runs `codex login` against
DartClaw's own credential store instead of `~/.codex`.

`dartclaw init` is the primary setup command. It runs a Quick-track wizard in a terminal, or accepts all inputs via flags with `--non-interactive`. All preflight checks (provider binary, port, directory writability) run before any file is written, so an interrupted setup leaves nothing on disk. Re-running it against an existing instance shows current values as defaults.

```bash
# Non-interactive setup (e.g. for scripts or CI)
dartclaw init --non-interactive \
  --provider claude \
  --auth-claude oauth \
  --model-claude sonnet \
  --port 3333

# Multi-provider setup
dartclaw init --non-interactive \
  --provider claude \
  --provider codex \
  --auth-claude oauth \
  --auth-codex env \
  --model-claude sonnet \
  --model-codex gpt-5 \
  --primary-provider claude

# dartclaw setup is an alias for dartclaw init
dartclaw setup
```

`--auth-claude` / `--auth-codex` choose between an API key (`env`) and the provider CLI's own login (`oauth`). Neither
selects DartClaw's own credential store: `dartclaw auth claude` / `dartclaw auth codex` are a separate step that `init`
does not perform. Verification does read that store, so an instance whose only credential was stored there verifies.

Setup reports one of two completion states:

- `Status: verified` means local checks passed and the selected provider already has a credential DartClaw can resolve – an API key, a subscription credential stored by `dartclaw auth`, or the provider CLI's own login.
- `Status: configured but unverified` means the instance is valid, but provider verification was skipped or still needs login/API-key setup.

Use `--launch foreground`, `--launch background`, or `--launch service` to start immediately after setup, or accept the default `--launch skip` to configure only.

`dartclaw init` also creates the 0.17 workspace personalization structure:

- `USER.md` with six stable sections: Identity, Goals, Current Challenges, Preferences, Proactivity Level, Not Relevant.
- `SOUL.md` with durable behavior-update and proactivity guidance.
- `wiki/README.md` for curated sourced knowledge pages, distinct from canonical personal memory.
- `ONBOARDING.md`, a human-conversation sentinel that guides first-run personalization in web chat and configured messaging channels.

Existing installs can adopt the structure by running `dartclaw init --personalize`, then completing onboarding in any configured human-facing chat.
Reruns write `USER.md.draft` and `SOUL.md.draft` so curated behavior files are not overwritten. Review the drafts and apply
them with `dartclaw init --apply-drafts`.

**Important**: Standalone binaries produced by `bash dev/tools/build.sh` embed the web UI, static assets, skills, and workflows — no companion asset files and no first-run network request. The executable does ship with a bundled SQLite library in a sibling `lib/` (`build/bin/dartclaw` + `build/lib/libsqlite3.*`); the two directories must move together, since the binary resolves the library relative to itself. Clone-based `dart run`, `--dev`, and explicit source-directory runs still read from the source tree for live editing. See [Deployment § Running Outside the Source Tree](deployment.md#running-outside-the-source-tree).

## Run from Source

Use source-based execution when you are developing DartClaw itself, want template/static hot-reload, or need the plain Dart toolchain in CI:

```bash
dart run dartclaw_cli:dartclaw serve --dev
dart run dartclaw_cli:dartclaw workflow run code-review --standalone --json
```

That path is intentionally secondary in the user guide. For normal operation, prefer the standalone binary.

## First Session

1. Open [http://127.0.0.1:3333](http://127.0.0.1:3333)
2. Click **New Chat**
3. Type a message, then press **Ctrl+Enter** or **Cmd+Enter** on macOS
4. The agent responds with streaming text via SSE

See `examples/` for ready-made configs such as dev, production, and personal assistant setups.

## Instance Directory

DartClaw stores all configuration and runtime artifacts in a single **instance directory**. The default is `~/.dartclaw/`:

```
~/.dartclaw/
  dartclaw.yaml      ← configuration
  workspace/         ← behavior files that shape the agent
  sessions/
  logs/
  search.db
  tasks.db
```

To use a different location, set `DARTCLAW_HOME` to point at your instance directory. Config is resolved in this order: `--config` flag > `DARTCLAW_CONFIG` env var > `DARTCLAW_HOME` env var > `~/.dartclaw/dartclaw.yaml`.

See [Workspace](workspace.md) for how the behavior files are assembled into prompts and kept in sync.

## What's Next?

- [Workspace](workspace.md) - Learn how behavior files shape the agent.
- [Windows](windows.md) - Install, validate, and understand native Windows support boundaries.
- [Configuration](configuration.md) - See `dartclaw.yaml`, provider selection, environment variables, and CLI flags.
- [Security](security.md) - Review guard chains, container isolation, and credential handling.
- [WhatsApp](whatsapp.md) - Set up the GOWA-backed WhatsApp channel.
- [Signal](signal.md) - Configure signal-cli and access control.
- [Google Chat](google-chat.md) - Connect Google Chat spaces and slash commands.
- [Scheduling](scheduling.md) - Configure heartbeat and cron-based delivery.
- [Tasks](tasks.md) - Understand task lifecycle and review workflows.
- [Architecture](architecture.md) - Read the 2-layer system overview and protocol flow.
- [Recipes](recipes/) - Browse copy-pasteable workflow examples.
- [Full Guide Index](README.md) - Jump to the full guide catalog.
