# DartClaw — Project Guide for Claude Code

Security-focused AI agent runtime. Dart host (AOT-compiled, zero npm) drives the native `claude` CLI binary via JSONL control protocol. Defense-in-depth security with container isolation, guard chain, and credential proxy.

## Documentation Map

| Topic | Location | When to read |
|-------|----------|--------------|
| Getting started | `docs/guide/getting-started.md` | First setup |
| Configuration | `docs/guide/configuration.md` | Editing `dartclaw.yaml` |
| Workspace & behavior files | `docs/guide/workspace.md` | Customizing agent personality, safety rules, user context |
| Security & guards | `docs/guide/security.md` | Hardening, container setup, credential proxy |
| Deployment | `docs/guide/deployment.md` | LaunchDaemon, systemd, AOT compilation, production |
| Customization ladder | `docs/guide/customization.md` | L1 (behavior files) through L5 (Dart source) |
| Recipes | `docs/guide/recipes/` | Personal assistant, briefings, journaling, research, CRM, multi-user channel collaboration |
| WhatsApp channel | `docs/guide/whatsapp.md` | GOWA setup, pairing, access control |
| Signal channel | `docs/guide/signal.md` | signal-cli setup, registration |
| Google Chat channel | `docs/guide/google-chat.md` | GCP service account, Chat app setup |
| Tasks & orchestration | `docs/guide/tasks.md` | Background tasks, review workflow, coding tasks |
| Scheduling | `docs/guide/scheduling.md` | Heartbeat, cron jobs |
| Search & memory | `docs/guide/search.md` | FTS5/QMD search, memory consolidation |
| SDK quick start | `docs/sdk/quick-start.md` | Building on DartClaw programmatically |
| Package guide | `docs/sdk/packages.md` | Which package to depend on |
| Example configs | `examples/` | dev, production, personal-assistant presets |
| Architecture | `docs/guide/architecture.md` | Understanding the 2-layer model |
| Full guide index | `docs/guide/README.md` | Everything else |

## Key Commands

```bash
# Install dependencies
dart pub get

# Run server (default: localhost:3000)
dart run dartclaw_cli:dartclaw serve

# Run with specific config
dart run dartclaw_cli:dartclaw serve --config examples/personal-assistant.yaml

# Quick start with example config (stores data in .dartclaw-dev/)
bash examples/run.sh                          # uses dev.yaml
bash examples/run.sh production --port 8080   # uses production.yaml

# AOT compile to standalone binary (no Dart SDK needed at runtime)
dart compile exe apps/dartclaw_cli/bin/dartclaw.dart -o dartclaw
./dartclaw serve

# Auth token management
dartclaw token show
dartclaw token rotate

# Deployment wizard
dartclaw deploy setup

# Verify installation
dart analyze
dart test packages/dartclaw_core
dart test packages/dartclaw_server
```

## Project Structure

```
apps/dartclaw_cli/           CLI app: serve, status, deploy, token commands
packages/
  dartclaw/                  Umbrella package — re-exports core + models + storage
  dartclaw_core/             Runtime: harness, protocol, guards, channels, scheduling (no sqlite3)
  dartclaw_models/           Pure data classes: Session, Message, SessionKey (zero deps)
  dartclaw_storage/          SQLite-backed: memory service, FTS5/QMD search, pruning
  dartclaw_security/         Guard framework: CommandGuard, FileGuard, NetworkGuard
  dartclaw_server/           HTTP API (shelf) + HTMX web UI + SSE streaming
  dartclaw_whatsapp/         WhatsApp channel via GOWA
  dartclaw_signal/           Signal channel via signal-cli
  dartclaw_google_chat/      Google Chat channel via GCP
  dartclaw_config/           Typed config model + extension registration
  dartclaw_testing/          Shared test fakes and helpers
docs/                        User guide, SDK docs, architecture, recipes
examples/                    Ready-made configs + SDK examples
```

Dart pub workspace — all packages resolve locally via `pubspec.yaml` workspace declaration.

## Common Setup Paths

**Basic web UI** — Start here. `dart pub get && dart run dartclaw_cli:dartclaw serve`. Edit behavior files in `~/.dartclaw/workspace/` to personalize. See `docs/guide/getting-started.md`.

**Personal assistant** — Long-running knowledge companion with briefings, journaling, memory. Use `examples/personal-assistant.yaml` as starting config. See `docs/guide/recipes/00-personal-assistant.md`.

**Production deployment** — AOT compile, use `examples/production.yaml`, run `dartclaw deploy setup` for LaunchDaemon/systemd. See `docs/guide/deployment.md`.

**With messaging channels** — Add WhatsApp, Signal, or Google Chat. Each has its own guide under `docs/guide/`. Channels are independent — enable one or all.

**SDK integration** — Build on DartClaw programmatically. Start with `docs/sdk/packages.md` to pick the right package, then `docs/sdk/quick-start.md`. Examples in `examples/sdk/`.

## Customization Levels

Users customize DartClaw at five levels (see `docs/guide/customization.md`):

1. **L1 — Behavior files** (no code): Edit `SOUL.md`, `AGENTS.md`, `USER.md`, `TOOLS.md`, `HEARTBEAT.md` in `~/.dartclaw/workspace/`
2. **L2 — Config YAML** (no code): Tune `dartclaw.yaml` — guards, channels, scheduling, session scoping
3. **L3 — Skills** (no code): Prompt templates in `.claude/skills/`
4. **L4 — MCP servers** (minimal code): Tool integrations via `.mcp.json`
5. **L5 — Dart source**: Custom guards, channels, templates, MCP tools

Always suggest the lowest level that solves the user's need.

## Data Layout

```
~/.dartclaw/
  dartclaw.yaml          Runtime configuration
  workspace/             Behavior files (SOUL.md, AGENTS.md, USER.md, etc.)
  sessions/              Session transcripts (NDJSON)
  logs/                  Structured logs
  dartclaw.db            SQLite search index
```

## Prerequisites

- **Dart SDK** >= 3.11.0 (`brew install dart` on macOS)
- **Claude CLI** binary in PATH (`curl -fsSL https://claude.ai/install.sh | bash`)
- **SQLite** system library (pre-installed on macOS, `apt install libsqlite3-dev` on Debian/Ubuntu)
- **Docker** (optional) — for container isolation
- **ANTHROPIC_API_KEY** or Claude CLI OAuth session (`claude login`)
