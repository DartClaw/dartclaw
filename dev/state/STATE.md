# Project State

> **In-flight state only.** Shipped history lives in `CHANGELOG.md`. Session journals belong in git commit messages, not here. Keep this file lean — when in doubt, cut.

Last Updated: 2026-05-04 20:01 CEST

### Implemented Features (through 0.16.4)

- **Runtime**: 2-layer model (Dart host → Claude Code JSONL + Codex JSON-RPC binaries). Multi-provider `HarnessPool` with per-task provider override. Task orchestrator: lifecycle state machine, parallel execution, optimistic locking. Coding tasks: worktree isolation, diff, merge, PR creation. Standalone AOT binary with embedded templates, static assets, and skills (`dev/tools/build.sh`)
- **CLI**: `dartclaw init` onboarding wizard (interactive + non-interactive), `dartclaw service` management (LaunchAgent/systemd), connected-by-default workflow execution with SSE lifecycle control (`workflow run/status/pause/resume/cancel`), operational command groups (`tasks`, `config`, `projects`, `sessions`, `agents`, `traces`, `jobs`). Unified instance directory (`~/.dartclaw/`)
- **Workflows**: Deterministic YAML-defined engine — sequential, parallel, loops (exit gates), map/fan-out. Step types: agent, bash, approval, hybrid, multi-prompt. Skill registry with DC-native discovery/validation skills plus AndThen-provided workflow skills, schema presets, crash recovery. Workflow workspace isolation with dedicated `AGENTS.md` guardrails. Trigger surfaces: web launch forms, `/workflow` chat commands, GitHub PR webhooks. Connected server-backed execution with `--standalone` fallback
- **Channels**: 4 types (WhatsApp/GOWA, Signal/signal-cli, Google Chat/Pub/Sub, Web). Normalized message abstraction, deduplication, mention gating. Google Chat: Cards v2, slash commands, workspace events. Alert routing with severity-aware formatting, per-target throttling, and burst summaries
- **Crowd coding** (0.12): Multi-user steering via Spaces, sender attribution, thread binding for task-thread routing, channel-based task creation/review
- **Sessions**: Multi-scope model (web/dm/group/cron/task/heartbeat), deterministic `SessionKey` routing, event bus (30+ events), cursor-based crash recovery, automated maintenance
- **Security**: Guard chain (command/file/network/content guards) with hot-reload, Docker container isolation (`network:none` + proxy), credential proxy (Unix socket), governance (rate limiting, token budgets, loop detection), emergency `/stop`/`/pause`/`/resume`
- **Configuration**: 3-tier (ephemeral/persistent/hot-reload), 25+ typed sections, `ConfigNotifier`/`Reconfigurable` with SIGUSR1/file-watch reload triggers, extension system, settings UI
- **Observability**: Alert routing to channels, health monitoring, date-partitioned audit logging, usage/token tracking, turn traces, SSE streaming (tasks/chat/workflows), context monitoring, compaction observability (Claude + Codex lifecycle signals)
- **Web UI & API**: HTMX+SSE UI (Trellis, zero JS build): dashboard, chat, tasks, workflows (with launch forms), projects, scheduling, memory, settings, health, canvas admin. REST API + MCP server. Multi-project support with PR creation. API read surfaces for sessions, traces, and scheduled jobs
- **Storage**: Files as source of truth (YAML/JSON/NDJSON) + SQLite indexes (tasks.db, search.db, state.db). Workspace behavior files (SOUL/USER/TOOLS/AGENTS/MEMORY.md). FTS5 search with QMD hybrid opt-in. Shareable canvas with workshop templates


## Current Phase

**0.16.5** — Stabilisation & Hardening. Consolidation sprint covering the full public codebase and user-facing docs. Closes a safety gap in alert routing, decomposes the top god files (`workflow_executor.dart`, `task_executor.dart`, `config_parser.dart`, `service_wiring.dart`, `server.dart`), formalises barrel-hygiene discipline (`dartclaw_workflow` narrowed), extracts turn/pool/harness interfaces to `dartclaw_core`, wires 7 orphan observability events, installs 10 fitness functions (6 Level-1 + 4 Level-2), refreshes `AGENTS.md` and the user guide. Absorbs the 0.16.4 advisory carry-over (`workflow_executor.dart` LOC trim, `WorkflowCliRunner` placement, typed inter-package `taskConfig` DTOs — see `TECH-DEBT-BACKLOG.md` TD-069). Zero new user-facing features. 21+ stories planned.

**Previous**: 0.16.4 — CLI Operations, Connected Workflows & Workflow Platform Hardening — tagged `v0.16.4` on 2026-05-04.

**Next**: 0.16.6 — Web UI Stimulus Adoption. See `dev/state/ROADMAP.md`.

## Active Stories

None yet — 0.16.5 stories will be enumerated when the milestone enters planning.

## Next Planned

0.16.6 — Web UI Stimulus Adoption → 0.17 — Personal AI & Developer Experience. See `dev/state/ROADMAP.md`.

## Blockers

- None currently recorded.

## Recent Decisions

- 0.16.4 advisory carry-over (`workflow_executor.dart` LOC trim, `WorkflowCliRunner` placement, typed inter-package `taskConfig` DTOs) booked as 0.16.5+ work in `TECH-DEBT-BACKLOG.md` TD-069. `WorkflowGitPort` extraction is closed.
- Agent-resolved-merge contract: bash `{{VAR}}` substitutions are shell-escaped for symmetry with `{{context.X}}` (security-by-design; breaking change). Schema validator enforces `additionalProperties` / `enum` / `minimum` / `maximum` as warnings (soft-validate contract). `escalation: serialize-remaining` is the default; per-attempt structured artifacts carry 9 v1 fields scoped per iteration.
- Dependency-aware fan-out is a shared `mapOver` / `foreach` contract: records carry `id` + `dependencies`, `story_specs` preserves adjacency, promotion conflicts keep downstream stories pending for retry/resume.
- Stabilisation sprint inserted as 0.16.5 ahead of Stimulus adoption (0.16.6).

## Session Continuity Notes

- [2026-05-04] 0.16.4 squash-merged to `main` (`2f45c84`) and tagged `v0.16.4`; remote `feat/0.16.4` deleted (local kept as archive). New work on `feat/0.16.5`. README path conflict resolved in favor of `dev/tools/build.sh` (post-`tool/`→`dev/tools/` reorg).
- [2026-05-01] 0.16.4 release-prep doc updates landed: CHANGELOG `dartclaw_workflow` version line corrected (0.9.0 → 0.16.0), STATE.md trimmed to released state, ROADMAP.md advanced to 0.16.5 active, architecture markers verified at 0.16.4, `feature-comparison.md` advanced to 0.16.4 with new entries. `dartclawVersion` was already 0.16.4.
- [2026-04-30] S80 complete — built-in workflows now consume AndThen 0.15.8's `dartclaw-review --output-dir <path>` support by pinning every `dartclaw-review` report to an engine-managed absolute runtime artifacts directory under `<data_dir>/workflows/runs/<runId>/runtime-artifacts/reviews`. Supersedes the unlanded S79 in-worktree `.agent_temp/reviews` convention.
- [2026-04-28] S65 release-gate recheck complete — two consecutive integration runs of `merge_resolve_integration_test.dart` passed with real Codex.
- [2026-04-28] S76 credentialed publish recheck complete — credentialed `plan-and-implement` passed end-to-end with real Codex, merge-resolve, forced remediation/re-review, HTTPS/token branch push, and real `gh pr create`.
