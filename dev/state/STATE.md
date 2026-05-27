# Project State

> **In-flight state only.** Shipped history lives in `CHANGELOG.md`. Session journals belong in git commit messages, not here. Keep this file lean — when in doubt, cut.

Last Updated: 2026-05-27 20:17 CEST

### Implemented Features (through 0.16.6)

- **Runtime**: 2-layer model (Dart host → Claude Code JSONL + Codex JSON-RPC binaries). Multi-provider `HarnessPool` with per-task provider override. Task orchestrator: lifecycle state machine, parallel execution, optimistic locking. Coding tasks: worktree isolation, diff, merge, PR creation. Standalone AOT binary with embedded templates, static assets, and skills (`dev/tools/build.sh`)
- **CLI**: `dartclaw init` onboarding wizard (interactive + non-interactive), `dartclaw service` management (LaunchAgent/systemd), connected-by-default workflow execution with SSE lifecycle control (`workflow run/status/pause/resume/cancel`), operational command groups (`tasks`, `config`, `projects`, `sessions`, `agents`, `traces`, `jobs`). Unified instance directory (`~/.dartclaw/`)
- **Workflows**: Deterministic YAML-defined engine — sequential, parallel, loops (exit gates), map/fan-out. Step types: agent, bash, approval, hybrid, multi-prompt. Skill registry with DC-native discovery/validation skills plus AndThen-provided workflow skills, schema presets, crash recovery. Workflow workspace isolation with dedicated `AGENTS.md` guardrails. Trigger surfaces: web launch forms, `/workflow` chat commands, GitHub PR webhooks. Connected server-backed execution with `--standalone` fallback
- **Channels**: 4 types (WhatsApp/GOWA, Signal/signal-cli, Google Chat/Pub/Sub, Web). Normalized message abstraction, deduplication, mention gating. Google Chat: Cards v2, slash commands, workspace events. Alert routing with severity-aware formatting, per-target throttling, and burst summaries
- **Crowd coding** (0.12): Multi-user steering via Spaces, sender attribution, thread binding for task-thread routing, channel-based task creation/review
- **Sessions**: Multi-scope model (web/dm/group/cron/task/heartbeat), deterministic `SessionKey` routing, event bus (30+ events), cursor-based crash recovery, automated maintenance
- **Security**: Guard chain (command/file/network/content guards) with hot-reload, Docker container isolation (`network:none` + proxy), credential proxy (Unix socket), governance (rate limiting, token budgets, loop detection), emergency `/stop`/`/pause`/`/resume`
- **Configuration**: 3-tier (ephemeral/persistent/hot-reload), 25+ typed sections, `ConfigNotifier`/`Reconfigurable` with SIGUSR1/file-watch reload triggers, extension system, settings UI
- **Observability**: Alert routing to channels, health monitoring, date-partitioned audit logging, usage/token tracking, turn traces, SSE streaming (tasks/chat/workflows), context monitoring, compaction observability (Claude + Codex lifecycle signals)
- **Web UI & API**: HTMX+SSE UI (Trellis, zero JS build) with Stimulus `dc-*` controllers for browser behavior: dashboard, chat, tasks, workflows (with launch forms), projects, scheduling, memory, settings, health, canvas admin. REST API + MCP server. Multi-project support with PR creation. API read surfaces for sessions, traces, and scheduled jobs
- **Storage**: Files as source of truth (YAML/JSON/NDJSON) + SQLite indexes (tasks.db, search.db, state.db). Workspace behavior files (SOUL/USER/TOOLS/AGENTS/MEMORY.md). FTS5 search with QMD hybrid opt-in. Shareable canvas with workshop templates
- **Governance** (0.16.5): 13 fitness checks in CI (7 Level-1 every commit + 6 Level-2 every PR) — barrel `show`-clauses, file-LOC ceilings, package cycles, constructor param counts, `ProcessEnvironmentPlan` boundary, safe-process usage, format gate; plus dependency direction, cross-package `src/` import hygiene, testing-package deps, barrel export counts, enum/event consumer exhaustiveness, per-file method-count ceilings. `public_member_api_docs` lint flipped on in `dartclaw_models/_storage/_security/_config`. Alert classifier closes the `LoopDetectedEvent` / `EmergencyStopEvent` safety gap via compiler-enforced exhaustive switch over `sealed DartclawEvent`. All 7 orphan sealed events wired to SSE + alerts


## Current Phase

**0.16.6** — Web UI Stimulus Adoption.

**Status**: Release-ready, awaiting tag. All four stories (S01 foundation, S02 core migration, S04 special surfaces + legacy removal, S05 docs/spec sync) closed on 2026-05-26. Transient implementation bundle removed; version pins bumped; CHANGELOG dated 2026-05-27. Awaiting squash-merge to `main`, annotated `v0.16.6` tag, then branch-off to `feat/0.17`.

**Previous**: 0.16.5 — Stabilisation & Hardening (tagged 2026-05-25).

**Next**: 0.17 — Personal AI & Developer Experience. See `dev/state/ROADMAP.md`.

## Active Stories

None.

## Blockers

None.

## Recent Decisions

- 0.16.6 closed with Stimulus as the Web UI behavior layer while HTMX and Trellis remain the server-rendered interaction foundation.
- Architecture deep-dives (`dev/architecture/`) and design system (`dev/design-system/`) promoted to canonical in this repo during 0.16.6; `release_check.sh` and `SPEC-LIFECYCLE.md` updated to stop treating them as transient.
