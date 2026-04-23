# Project State

> **In-flight state only.** Shipped history lives in `CHANGELOG.md`. Session journals belong in git commit messages, not here. Keep this file lean — when in doubt, cut.

Last Updated: 2026-04-23 20:30 CEST

### Implemented Features (through 0.16.4)

- **Runtime**: 2-layer model (Dart host → Claude Code JSONL + Codex JSON-RPC binaries). Multi-provider `HarnessPool` with per-task provider override. Task orchestrator: lifecycle state machine, parallel execution, optimistic locking. Coding tasks: worktree isolation, diff, merge, PR creation. Standalone AOT binary with embedded templates, static assets, and skills (`tool/build.sh`)
- **CLI**: `dartclaw init` onboarding wizard (interactive + non-interactive), `dartclaw service` management (LaunchAgent/systemd), connected-by-default workflow execution with SSE lifecycle control (`workflow run/status/pause/resume/cancel`), operational command groups (`tasks`, `config`, `projects`, `sessions`, `agents`, `traces`, `jobs`). Unified instance directory (`~/.dartclaw/`)
- **Workflows**: Deterministic YAML-defined engine — sequential, parallel, loops (exit gates), map/fan-out. Step types: agent, bash, approval, hybrid, multi-prompt. Skill registry (11 built-in `dartclaw-*` skills), schema presets, crash recovery. Workflow workspace isolation with dedicated `AGENTS.md` guardrails. Trigger surfaces: web launch forms, `/workflow` chat commands, GitHub PR webhooks. Connected server-backed execution with `--standalone` fallback
- **Channels**: 4 types (WhatsApp/GOWA, Signal/signal-cli, Google Chat/Pub/Sub, Web). Normalized message abstraction, deduplication, mention gating. Google Chat: Cards v2, slash commands, workspace events. Alert routing with severity-aware formatting, per-target throttling, and burst summaries
- **Crowd coding** (0.12): Multi-user steering via Spaces, sender attribution, thread binding for task-thread routing, channel-based task creation/review
- **Sessions**: Multi-scope model (web/dm/group/cron/task/heartbeat), deterministic `SessionKey` routing, event bus (30+ events), cursor-based crash recovery, automated maintenance
- **Security**: Guard chain (command/file/network/content guards) with hot-reload, Docker container isolation (`network:none` + proxy), credential proxy (Unix socket), governance (rate limiting, token budgets, loop detection), emergency `/stop`/`/pause`/`/resume`
- **Configuration**: 3-tier (ephemeral/persistent/hot-reload), 25+ typed sections, `ConfigNotifier`/`Reconfigurable` with SIGUSR1/file-watch reload triggers, extension system, settings UI
- **Observability**: Alert routing to channels, health monitoring, date-partitioned audit logging, usage/token tracking, turn traces, SSE streaming (tasks/chat/workflows), context monitoring, compaction observability (Claude + Codex lifecycle signals)
- **Web UI & API**: HTMX+SSE UI (Trellis, zero JS build): dashboard, chat, tasks, workflows (with launch forms), projects, scheduling, memory, settings, health, canvas admin. REST API + MCP server. Multi-project support with PR creation. API read surfaces for sessions, traces, and scheduled jobs
- **Storage**: Files as source of truth (YAML/JSON/NDJSON) + SQLite indexes (tasks.db, search.db, state.db). Workspace behavior files (SOUL/USER/TOOLS/AGENTS/MEMORY.md). FTS5 search with QMD hybrid opt-in. Shareable canvas with workshop templates


## Current Phase

**0.16.4** — release prep, reopened mid-milestone for workflow step semantics redesign. Filesystem-first structured-output extraction is code-complete.

## Active Stories

- S49 — In Progress: building the workflow scenario-test tier, typed `E2EFixture`, and fitness-baseline ratchet now that dependency-aware `foreach` scheduling is landed.

## Next Planned

0.16.5 — Stabilisation & Hardening → 0.16.6 — Web UI Stimulus Adoption. See `docs/dev/ROADMAP.md`.

## Blockers

- `plan-and-implement` live-suite integration failure in `workflow_e2e_integration_test.dart` blocks tagging 0.16.4.

## Recent Decisions

- Dependency-aware fan-out is now a shared `mapOver` / `foreach` contract: dependency-aware records must carry `id` + `dependencies`, `story_specs` now preserves that adjacency, and promotion conflicts keep downstream stories pending for retry/resume.
- S46 task_executor.dart decomposition completed: task executor reduced to 771 LOC with extracted task config, workflow turn extraction, read-only guard, budget policy, runner-pool coordination, workflow worktree binding, and one-shot workflow runner seams.
- S47 git integration hardening completed: WorkflowGitPort seam, pre-merge invariants, RepoLock, fake-git parity tests, and fatal load-bearing artifact commit failures.
- Filesystem-first structured-output extraction completed: path outputs resolve from `WorkflowGitPort.diffNameOnly`, artifact propagation uses `ProducedArtifactResolver`, and mapped story specs preflight before agent launch.
- Stabilisation sprint inserted as 0.16.5 ahead of Stimulus adoption (0.16.6).
- Workflow project binding declared once at the top level; built-in YAMLs no longer repeat per-step `project:` boilerplate. Workflow-created tasks persist uniformly as `TaskType.coding`.
- Two-step CLI onboarding: deterministic wizard for infrastructure config + conversational agent for personalization.
- TUI/CLI package: `mason_logger` for the wizard; richer TUI libraries deferred until a REPL is in scope.
- Multi-project architecture: project model, worktree integration, PR strategy.
