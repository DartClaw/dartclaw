# Getting Started

DartClaw is a security-conscious AI agent runtime. A Dart host coordinates state, security, and the web UI while a native agent CLI handles turns.

## Prerequisites

| Dependency | Version | Purpose |
|-----------|---------|---------|
| Dart SDK | ^3.11.0 | Build toolchain for source checkouts and development runs |
| `claude` CLI | Latest | Agent binary — default provider (see [Deployment § Maintaining Agent Binaries](deployment.md#maintaining-agent-binaries) for update guidance) |
| `codex` CLI | Latest | Agent binary — optional, for OpenAI models (see [Agents § Providers](agents.md#providers)) |
| SQLite | System lib | Search index |

Install Dart, Claude Code, and SQLite:

```bash
brew tap dart-lang/dart && brew install dart
# Agent CLI — Claude (default provider)
curl -fsSL https://claude.ai/install.sh | bash
# Agent CLI — Codex (optional, for OpenAI models)
# See https://github.com/openai/codex for installation
sudo apt-get install libsqlite3-dev
```

Auth: for Claude, run `claude login` or `claude setup-token`, or export `ANTHROPIC_API_KEY`. For Codex (`provider: codex`), use the Codex CLI's normal sign-in flow or export `CODEX_API_KEY`.

## Install DartClaw

This guide treats the standalone `dartclaw` binary as the primary runtime entrypoint.

If you are working from a source checkout today, build that binary first:

```bash
git clone <repo-url> && cd dartclaw
dart pub get
bash dev/tools/build.sh
```

Then either:

- run `build/dartclaw` directly from the checkout, or
- copy `build/dartclaw` onto your `PATH` as `dartclaw`

All command examples below use `dartclaw`. If you have not installed it onto `PATH`, replace `dartclaw` with `build/dartclaw`.

## Quick Start

The fastest path to a running DartClaw instance:

```bash
# 1. Set up the instance (config, workspace, onboarding sentinel)
dartclaw init

# 2. Start the server
dartclaw serve

# 3. Open http://127.0.0.1:3333
```

`dartclaw init` is the primary setup command. It runs a Quick-track wizard in a terminal (or accepts all inputs via flags with `--non-interactive`). All preflight checks (provider binary, port, directory writability) run before any file is written, so an interrupted setup leaves nothing on disk. Re-running `dartclaw init` against an existing instance shows current values as defaults.

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

Setup reports one of two completion states:

- `Status: verified` means local checks passed and the selected provider already has usable credentials or CLI login.
- `Status: configured but unverified` means the instance is valid, but provider verification was skipped or still needs login/API-key setup.

Use `--launch foreground`, `--launch background`, or `--launch service` to start immediately after setup, or accept the default `--launch skip` to configure only.

**Important**: Standalone binaries produced by `bash dev/tools/build.sh` ship the `dartclaw` executable plus companion assets. Packaged installs discover those assets from the filesystem (`../share/dartclaw/` in Homebrew, or `~/.dartclaw/assets/v{VERSION}/` after the first-run download fallback) rather than embedding web UI, static assets, skills, or workflows in the binary. When you run from a clone with `dart run` or `--dev`, DartClaw still reads templates, static assets, skills, and workflows from the source tree, and `dartclaw service install` keeps `--source-dir` in checkout-backed service units. For those clone-based runs, see [Deployment § Running Outside the Source Tree](deployment.md#running-outside-the-source-tree).

If you install only the bare binary, the first `dartclaw serve` run downloads the matching asset archive unless you pass `--offline`.

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
