# Project State

> **In-flight state only.** Shipped history lives in `CHANGELOG.md`. Session journals belong in git commit messages, not here. Keep this file lean — when in doubt, cut.

Last Updated: 2026-06-04 16:36 CEST

### Implemented Features (through 0.17)

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
- **Personal AI & SDK docs (0.17)**: Structured behavior-file scaffolding, web-only personalization onboarding, curated inbox ingestion, wiki provenance/search/lint, temporal KG MCP tools, YAML-backed guard editor, SDK Concepts/Architecture/Security docs, runnable SDK examples, rich chat composer payload metadata, and automated kill/restart crash-recovery smoke validation
- **Storage**: Files as source of truth (YAML/JSON/NDJSON) + SQLite indexes (tasks.db, search.db, state.db). Workspace behavior files (SOUL/USER/TOOLS/AGENTS/MEMORY.md). FTS5 search with QMD hybrid opt-in. Shareable canvas with workshop templates
- **Governance** (0.16.5): 13 fitness checks in CI (7 Level-1 every commit + 6 Level-2 every PR) — barrel `show`-clauses, file-LOC ceilings, package cycles, constructor param counts, `ProcessEnvironmentPlan` boundary, safe-process usage, format gate; plus dependency direction, cross-package `src/` import hygiene, testing-package deps, barrel export counts, enum/event consumer exhaustiveness, per-file method-count ceilings. `public_member_api_docs` lint flipped on in `dartclaw_models/_storage/_security/_config`. Alert classifier closes the `LoopDetectedEvent` / `EmergencyStopEvent` safety gap via compiler-enforced exhaustive switch over `sealed DartclawEvent`. All 7 orphan sealed events wired to SSE + alerts


## Current Phase

**0.17** — Personal AI & Developer Experience.

**Status**: Release-ready, awaiting tag. All pre-tag gates green. Automated gates pass (bundle cleanup, version lockstep at 0.17.0, format, analyze, fitness, full test suite). Manual gates re-run clean after the final workflow-engine fixes: live integration tests, the UI smoke test, and the maintainer-smoke workflow runs (skill-discovery TI07, workflow-engine-reliability TI09). See `dev/state/ROADMAP.md` for scope.

Milestone close note: all planned 0.17 stories plus the post-plan workflow-engine reliability, harness stabilization, and release-hardening work are implemented. The latter are captured as Phases G/H in the canonical PRD (`dartclaw-private/docs/specs/0.17/prd.md`); the transient implementation bundle (`dev/bundle/`) has been removed. No `0.17.x` deferral remains for planned stories; future/pre-1.0 PRD items remain explicitly out of scope.

**Previous**: 0.16.6 — Web UI Stimulus Adoption (tagged `v0.16.6` on 2026-05-27).

**Next**: 0.18 — Universal Agent Harness. See `dev/state/ROADMAP.md`.

## Active Stories

None.

## Blockers

None.

## Recent Decisions

- S12 Zero-friction Workflow CLI is implemented: `dartclaw init --workflow` now writes a minimal standalone config, missing standalone config errors point to the workflow init path, and standalone workflow discovery includes `<data_dir>/workflows/`.
- S01 Personalization Foundation is implemented: fresh workspaces now scaffold structured `USER.md`, updated `SOUL.md`, `wiki/README.md`, web-only onboarding prompt injection, `onboarding_complete`, and `dartclaw init --personalize` / `--apply-drafts`.
- S03 Knowledge Systems is implemented: filesystem inbox processing now runs bounded cron-session extraction turns into synthesized memory/wiki/KG outputs, wiki provenance/search ranking, wiki lint categories, and temporal KG MCP tools cover the durable knowledge loop.
- S06 Guard Editor Vertical Slice is implemented: settings now expose YAML-backed guard extension CRUD, validation, tester verdicts, pending-restart status, and server-side admin-gated editing (single gateway-token admin identity; `auth_mode: none` runs as the local admin). TD-107 resolved 2026-05-30: the unreachable non-admin/read-only tier was removed and the no-auth editing regression fixed.
- S07 SDK Documentation Phase 2 is implemented: SDK Concepts, Architecture, and Security guides now link from the SDK entry points, and custom guard, multi-turn CLI, and Shelf server examples run against local workspace packages.
- S08 Chat Composer is implemented: the main chat surface now has a richer composer shell, streaming stop/retry recovery, command palette discovery, attachment chips, reference chips, and durable rich-input message metadata.
- S13 WorkflowService dependency shape is implemented: production wiring now supplies typed `WorkflowPersistencePorts` and `WorkflowGitContext`, the default constructor requires persistence at compile time, and lifecycle-only tests/fakes use the explicit lifecycle-only constructor.
- S11 Milestone Documentation & Verification is implemented: milestone docs, public SDK/user references, wireframe deviations, and crash-recovery validation now agree on the shipped 0.17 scope and named future/pre-1.0 exclusions.
- 0.16.6 tagged on 2026-05-27. Stimulus is now the Web UI behavior layer; HTMX + Trellis remain the rendering/request foundation.
- Architecture deep-dives (`dev/architecture/`) and design system (`dev/design-system/`) promoted to canonical in this repo during 0.16.6; `release_check.sh` and `SPEC-LIFECYCLE.md` updated to stop treating them as transient.
