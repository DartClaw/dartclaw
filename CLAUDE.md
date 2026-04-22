# DartClaw — Project Guide

An experimental, security-conscious AI agent runtime built with Dart. Dart host (AOT-compiled, zero npm) orchestrates multiple native agent harnesses (Claude Code, Codex, more planned) via control protocols. Defense-in-depth security with container isolation, guard chain, and credential proxy.

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

## Project Document Index

Internal development docs for working on DartClaw itself (as opposed to using it).

<!-- AndThen-style index — workflow commands and the discover-project skill read this table to determine where to find and write project documents. -->

| Topic | Location | When to read |
|-------|----------|--------------|
| Current state | `docs/dev/STATE.md` | Check what's in flight before starting work |
| Learnings | `docs/dev/LEARNINGS.md` | Before debugging unfamiliar subsystems; append non-obvious discoveries |
| Product (summary) | `docs/dev/PRODUCT.md` | Vision and principles |
| Roadmap (current + next) | `docs/dev/ROADMAP.md` | Active milestone and what's after |
| Spec lifecycle | `docs/dev/SPEC-LIFECYCLE.md` | When `docs/specs/` files appear or disappear |
| Dart style | `docs/guidelines/DART-EFFECTIVE-GUIDELINES.md` | Before writing Dart |
| Package boundaries | `docs/guidelines/DART-PACKAGE-GUIDELINES.md` | When touching pubspec or workspace packages |
| HTMX patterns | `docs/guidelines/HTMX-GUIDELINES.md` | Before writing web UI fragments |
| Trellis templates | `docs/guidelines/TRELLIS-GUIDELINES.md` | Before writing templates |
| Testing strategy | `docs/guidelines/TESTING-STRATEGY.md` | Before writing tests |
| Key dev commands | `docs/guidelines/KEY_DEVELOPMENT_COMMANDS.md` | Before/after modifying code |

## Companion Private Repo

Strategic planning context (full roadmap, ADRs, research, PRDs, wireframes, design system, competitor analysis) lives in a sibling repo at `../dartclaw-private/`, checked out alongside this one. **Day-to-day code work in this repo does not require the private repo to be present** — the standard built-in DartClaw workflows operate on this repo alone.

When implementing a planned milestone, the active spec/PRD/plan/FIS files may be temporarily checked into `docs/specs/<version>/` for the duration of the implementation, then removed before merging to `main`. See `docs/dev/SPEC-LIFECYCLE.md` for the convention.

Authoring new PRDs/plans/FIS, ADR work, architecture or research notes, and wireframe/design-system updates happen in the private repo.

## Rules, Guardrails and Guidelines

### Foundational Rules and Guardrails
Adhere to system prompt "CRITICAL RULES and GUARDRAILS" before doing any work.

### Git Merge Strategy
All merging to `main` must use **squash merge** (`git merge --squash`). This applies to both repos in the workspace.

### Private Repo Git Policy
**Never** automatically commit or push in the companion private repo (`../dartclaw-private/`) during implementation work (executing plans, specs, etc.). All commits and pushes there must be explicitly requested by the user. (Normal commit/PR workflow applies in this public repo.)

### Timestamps
**Always** run `date '+%Y-%m-%d %H:%M %Z'` before writing timestamps. Never guess — internal time may be wrong timezone.

### Development Guidelines
Read relevant guidelines before coding, architecture, UX/UI, or review work:

- _`~/.claude/cc-workflows/guidelines/DEVELOPMENT-ARCHITECTURE-GUIDELINES.md`_ when doing development work (coding, architecture, etc.)
- _`~/.claude/cc-workflows/guidelines/UX-UI-GUIDELINES.md`_ when doing UX/UI related work
- _`~/.claude/cc-workflows/guidelines/WEB-DEV-GUIDELINES.md`_ when doing web development work
- _`docs/guidelines/DART-EFFECTIVE-GUIDELINES.md`_ — Effective Dart: style, documentation, usage, API design, async, error handling, Dart 3.x features, linter config
- _`docs/guidelines/DART-PACKAGE-GUIDELINES.md`_ — Package creation: structure, pubspec, versioning, pub.dev scoring, publishing workflow, automated publishing
- _`docs/guidelines/HTMX-GUIDELINES.md`_ — HTMX usage patterns, attributes, server-side rendering best practices, streaming updates, error handling, security considerations
- _`docs/guidelines/TRELLIS-GUIDELINES.md`_ — Trellis template usage, escaping rules, fragment patterns, integration with HTMX, security best practices
- _`docs/guidelines/TESTING-STRATEGY.md`_ — Test philosophy, four-layer pyramid, async patterns, coverage guidance, shared fakes, anti-patterns. **Read before writing tests**

### Key Development Commands
See `docs/guidelines/KEY_DEVELOPMENT_COMMANDS.md` — read before/after modifying code.

For local development only, if `dart test` is blocked by `package:sqlite3` failing to codesign its bundled native asset inside `.dart_tool/`, it is acceptable to temporarily point sqlite hooks at the host system library with an uncommitted `pubspec.yaml` edit:

```yaml
hooks:
  user_defines:
    sqlite3:
      source: system
```

This is an escape hatch for local iteration, not the canonical verification path. Do not commit it as the default, and verify the host SQLite build supports the required features (at minimum FTS5) before trusting test results.

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
3. **L3 — Skills** (no code): Prompt templates in `~/.claude/skills/` for Claude Code or `~/.agents/skills/` for other agents
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

## Conventions

- Lean dependencies. Prefer Dart stdlib and existing workspace packages over new packages.
- `dartclaw_core` must stay free of sqlite3 and server-only dependencies.
- Run `dart analyze` and targeted `dart test` coverage for touched code before finishing.
- Follow existing package boundaries, naming, and file organization.

## Prerequisites

- **Dart SDK** >= 3.11.0 (`brew install dart` on macOS)
- **Claude CLI** binary in PATH (`curl -fsSL https://claude.ai/install.sh | bash`)
- **SQLite** system library (pre-installed on macOS, `apt install libsqlite3-dev` on Debian/Ubuntu)
- **Docker** (optional) — for container isolation
- **ANTHROPIC_API_KEY** or Claude CLI OAuth session (`claude login`)
