# Project State

> **In-flight state only.** Shipped history lives in `CHANGELOG.md`. Session journals belong in git commit messages, not here. Keep this file lean — when in doubt, cut.

Last Updated: 2026-04-26 21:36 CEST

### Implemented Features (through 0.16.4)

- **Runtime**: 2-layer model (Dart host → Claude Code JSONL + Codex JSON-RPC binaries). Multi-provider `HarnessPool` with per-task provider override. Task orchestrator: lifecycle state machine, parallel execution, optimistic locking. Coding tasks: worktree isolation, diff, merge, PR creation. Standalone AOT binary with embedded templates, static assets, and skills (`tool/build.sh`)
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

**0.16.4** — release prep. Agent-resolved-merge bundle (S57-S65) implemented and component-tier plus real-harness proofs landed. The 2026-04-26 gap reviews (codex + claude) caught a CRITICAL wiring gap (synthetic merge-resolve task did not bind to the conflicted iteration's worktree) plus HIGH lock-coverage gap and the test-suite blind spot that hid both. Remediation 2026-04-26: C1 (mapCtx propagated through `_executeStep`), H1 (new `runResolverAttemptUnderLock` callback wraps each attempt under `_workflowGitRepoLock`; `RepoLock` made zone-reentrant), M1 (`outcome: cancelled` explicit), M2 (event cardinality run-scoped), L1 (test configs aligned). S65 now supplies the outer-loop Codex proof: a real `WorkflowExecutor` drives a two-story `STATE.md` conflict through the real `dartclaw-merge-resolve` skill and completes without operator intervention. Release prep can proceed; package-wide live integration still has unrelated existing drift tracked separately.

## Active Stories

- S51-S55 — Done (workflow step semantics redesign + remediation).
- S56 — Done: Live release gate and documentation closeout. The deferred `plan-and-implement` release-gate e2e was originally satisfied by S62's cross-harness component-tier suite, but the 2026-04-26 gap reviews showed that suite cannot prove the success metric (every component test injects `merge_resolve.outcome` directly via `messageService.insertMessage` rather than driving the executor → skill → worktree chain). S65 now supplies the real-harness proof.
- S57 — Done: Harness env-var injection contract + Codex `!`-operator SPIKE-1 (GO; Codex matches Claude Code via POSIX shell expansion). Six `MERGE_RESOLVE_*` env-var names locked in `dartclaw_core`.
- S58 — Done: `gitStrategy.merge_resolve` schema + validator rules + parser threading (HIGH parser-gap remediation). Five validator rules with byte-identical PRD wording.
- S59 — Done: `dartclaw-merge-resolve` skill (markdown-driven, all-or-nothing commit, four output fields). Cross-harness via the `!` bang operator.
- S60 — Done (after two remediation rounds — original CRITICAL-heavy round + 2026-04-26 gap-review remediation): Plumbing wiring — retry loop, atomic capture+clean callback, structured artifact persistence (9 v1 fields including `started_at`/`elapsed_ms`), `fail` escalation propagation, server-side wiring, crash recovery with `interrupted by server restart` artifact. 9-test component suite (added C1 + H1 regression tests asserting `mapIterationIndex` propagation and `runResolverAttemptUnderLock` invocation through the executor). Lock-spanning resolver attempt seam: `WorkflowTurnAdapter.runResolverAttemptUnderLock` wraps each attempt's body under `_workflowGitRepoLock`; `RepoLock.acquire` is now zone-reentrant so existing inner primitives compose. Cancelled task → `outcome: cancelled` explicitly.
- S61 — Done (after HIGH remediation): `serialize-remaining` drain — `WorkflowSerializationEnactedEvent` with accurate `drainedIterationCount`, single `serialize_remaining_phase` flag (no two-flag race), parallel 30s-cap timeout. 10 component tests including S2/S4/S5/S6 scenarios.
- S62 — Done: built-in `plan-and-implement` and `spec-and-implement` adopt `merge_resolve:` block; 12-cell cross-harness component-tier suite ships (P1-P5 × 2 harnesses + Issue C BPC-27 reproduction); C1/H1 component regressions prove executor binding and lock callback plumbing; S65 supplies the real-harness outer-loop proof for the PRD success metric.
- S65 — Done: Real-harness integration E2E for agent-resolved merge added at `packages/dartclaw_workflow/test/workflow/merge_resolve_integration_test.dart`. Tagged `@Tags(['integration'])`, gated on Codex binary + provider auth, drives a real `WorkflowExecutor` through a two-story `STATE.md` conflict via real `dartclaw-merge-resolve` skill execution. Two consecutive local Codex runs passed and were captured under the private repo's `.agent_temp/s65-run{1,2}.log`.
- S63 — Done: Public `merge_resolve` user-guide section (PASS no findings).
- S64 — Done (after HIGH remediation): Workflow test suite overhaul — Phase 0 stabilize (listener-race fix in `step_dispatcher` + `map_iteration_dispatcher`), Phase 1 honesty cleanup, Phase 2 behavioral gaps (bash escape on `{{VAR}}` for symmetry, schema strictness as warnings, max_parallel/loops parser tightening), Phase 3 executor-mega-file split, Phase 4 fakeAsync replaces real-time waits, Phase 5 unit-test additions. Phase 6 (fitness classification) deferred per FIS.
- S66 — Done: Workflow schema and validator cleanups (Phase 26, parallel with Phase 25). Three small related changes shipped together: (1) `OutputConfig.setValue` slot with sentinel-backed round-trip preserves "explicitly null" vs "unset"; executor short-circuits extraction (including the legacy `extraction:` priority branch) and writes the literal verbatim on success only — failure/skip paths leave context untouched. (2) Validator alias-aware skip on `@`-prefixed providers at both `_validateMultiPromptProviders` and the `continueSession` hot spots; runtime fallback at `workflow_executor_helpers.dart:633` remains the safety net for resolved-provider mismatches; deferred full alias resolution flagged via `TODO(0.16.7+)`. (3) `outputs:` map keys now imply the context-write set; `contextOutputs:` is a deprecated alias retained one release. Validator emits tailored deprecation warnings (redundant / subset / disagree / pure-legacy); foreach controllers exempted (carve-out for the aggregate name). All three bundled built-in YAMLs migrated to outputs-only style and `dart run dartclaw_cli:dartclaw workflow validate` is clean for each. Code review (`andthen:review --mode code`) returned OK with no CRITICAL/HIGH findings; M1 (`ContextExtractor` reads `effectiveContextOutputs` for programmatically-built steps) and L2 (class-level dartdoc updated for the five-strategy ladder) addressed inline.

## Next Planned

0.16.5 — Stabilisation & Hardening → 0.16.6 — Web UI Stimulus Adoption. See `docs/dev/ROADMAP.md`.

## Blockers

- Before tagging 0.16.4: re-run S65 locally (`dart test packages/dartclaw_workflow/test/workflow/merge_resolve_integration_test.dart -t integration` with a real Codex binary on PATH and provider auth available) and capture two-green-runs-in-a-row per the S65 FIS. S65 is integration-tagged and does not run in default CI; the test's own `skip:` gate handles missing harness/auth, so the `-t integration` selector is sufficient.

## Recent Decisions

- Agent-resolved-merge contract (S57-S64): bash `{{VAR}}` substitutions are now shell-escaped for symmetry with `{{context.X}}` (security-by-design; breaking change documented in user guide). Schema validator enforces `additionalProperties` / `enum` / `minimum` / `maximum` as warnings (soft-validate contract). `escalation: serialize-remaining` is the default; per-attempt structured artifacts carry 9 v1 fields scoped per iteration. `WorkflowSerializationEnactedEvent` carries an accurate `drainedIterationCount`.
- Dependency-aware fan-out is now a shared `mapOver` / `foreach` contract: dependency-aware records must carry `id` + `dependencies`, `story_specs` now preserves that adjacency, and promotion conflicts keep downstream stories pending for retry/resume.
- Final workflow gap remediation will execute sequentially from S51 -> S52 -> S53 -> S54 -> S55; S52/S53 are not parallel because they share executor, dispatcher, task-boundary, and built-in workflow surfaces.
- S46 task_executor.dart decomposition completed: task executor reduced to 771 LOC with extracted task config, workflow turn extraction, read-only guard, budget policy, runner-pool coordination, workflow worktree binding, and one-shot workflow runner seams.
- S47 git integration hardening completed: WorkflowGitPort seam, pre-merge invariants, RepoLock, fake-git parity tests, and fatal load-bearing artifact commit failures.
- Filesystem-first structured-output extraction completed: path outputs resolve from `WorkflowGitPort.diffNameOnly`, artifact propagation uses `ProducedArtifactResolver`, and mapped story specs preflight before agent launch.
- Stabilisation sprint inserted as 0.16.5 ahead of Stimulus adoption (0.16.6).
- Workflow project binding declared once at the top level; built-in YAMLs no longer repeat per-step `project:` boilerplate. Workflow-created tasks persist uniformly as `TaskType.coding`.
- Two-step CLI onboarding: deterministic wizard for infrastructure config + conversational agent for personalization.
- TUI/CLI package: `mason_logger` for the wizard; richer TUI libraries deferred until a REPL is in scope.
- Multi-project architecture: project model, worktree integration, PR strategy.
