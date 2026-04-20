# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [0.16.4]

CLI Operations, Connected Workflows & Workflow Platform Hardening — connected-by-default workflow execution, operational command groups, workflow trigger surfaces, a redesigned `plan-and-implement` built-in, file-based artifact transport with auto-commit, skill altitude split + upstream AndThen re-sync, workflow default cleanup, and the `AgentExecution` primitive decomposition. 35 stories across 21 phases.

### Added

- **Connected CLI workflow client**: `DartclawApiClient` now powers server-backed workflow execution, lifecycle control, SSE progress streaming, and loopback server detection
- **Operational CLI command groups**: new `agents`, `config`, `jobs`, `projects`, `tasks`, and `traces` families, plus expanded `sessions` commands for remote inspection and lifecycle operations
- **Workflow lifecycle CLI controls**: `workflow runs`, `workflow pause`, `workflow resume`, and `workflow cancel`
- **Workflow one-shot CLI runner**: workflow-owned task execution can now invoke `claude -p` / `codex exec` directly for bounded workflow prompt chains while preserving DartClaw task/session bookkeeping
- **New server read endpoints**: `GET /api/sessions/:id`, `GET /api/traces/:id`, `GET /api/scheduling/jobs`, and `GET /api/scheduling/jobs/:name`
- **Workflow trigger surfaces**: launch forms on `/workflows`, `/workflow` chat commands in the web UI, and GitHub PR webhooks that can start the `code-review` workflow
- **CLI operations guide**: new public guide page covering connected mode, standalone mode, server detection, and authentication behavior
- **Workflow control structures & node model**: first-class `foreach` and `story-pipeline` sub-pipelines with item-level crash recovery and per-item resume fidelity
- **Workflow worktree + publish pipeline**: per-story worktrees, deterministic branch promotion/merge semantics, explicit project auth + GitHub token delivery, and a workflow-owned publish path producing a `publish.pr_url`
- **`workflow show [--resolved] [--step <id>]`**: CLI + server endpoint that emits the fully merged workflow (variables, `stepDefaults`, skill defaults) as round-trippable YAML for debugging and audit
- **Auto-framed context inputs**: the engine wraps unreferenced `contextInputs` / variables in XML tags during prompt assembly; `auto_frame_context: false` opts out per step
- **Skill frontmatter defaults**: `workflow.default_prompt` and `workflow.default_outputs` on SKILL.md replace the per-skill `agents/openai.yaml` files across all built-in skills (the S30 re-port later unified `review-code` / `review-doc` / `review-gap` into a single `dartclaw-review` skill; end-of-release count is 11)
- **Generalized step-level `entryGate`**: skip-on-false semantic with `StepSkippedEvent`, available on all step kinds (previously loop-only)
- **File-based artifact transport**: `dartclaw-prd`/`dartclaw-plan`/`dartclaw-spec` skills write to disk and emit paths; `dartclaw-discover-project` publishes `artifact_locations` + `active_milestone`/`active_prd`/`active_plan`
- **Artifact auto-commit hook**: `gitStrategy.artifacts.commit: true` lands generated artifacts on the workflow branch before per-map-item worktrees are created, so stories inherit them via standard `git checkout`
- **`gitStrategy.worktree.externalArtifactMount`**: cross-clone FIS visibility for split-repo testing profiles (mount or per-story copy)
- **`worktree: auto`**: resolves to `per-map-item` under real parallelism, otherwise to `inline`; explicit values still win
- **`AgentExecution` primitive**: shared execution metadata (session, provider, model, token budget) lives in new `agent_executions` and `workflow_step_executions` tables with atomic AE+WSE+Task creation for workflow steps; five CI-enforced fitness functions lock the boundary. See `docs/adrs/021-agent-execution-primitive.md`
- **Workflow E2E Dart integration test**: tagged integration test drives `plan-and-implement` and `spec-and-implement` end-to-end with the real Codex harness and git (`packages/dartclaw_workflow/test/workflow/workflow_e2e_integration_test.dart`). Asserts the workflow-emitted `publish.pr_url` is a real GitHub URL that `gh pr view` resolves — the workflow's publish pipeline is validated end to end rather than via a post-workflow manual PR
- **Standalone CLI publish PR-creation hook**: `CliWorkflowWiring` accepts an optional `prCreator` to customize publish-step PR creation. Production standalone wiring leaves it null (push-only — operator creates the PR). Tests and alternative entry points inject one (e.g. `gh pr create`) so the URL flows through `WorkflowGitPublishResult.prUrl` into `context['publish.pr_url']`
- **`dartclaw-prd` skill**: PRD creation split out of `dartclaw-plan` (altitude split, mirrors AndThen 0.13.0)
- **`dartclaw-validate-workflow` skill**: validates workflow YAML definitions and packaged workflow assets
- **New server event stream**: `GET /api/agent-executions/events` surfaces AE status transitions

### Changed

- **`workflow run` is now connected-by-default**: the CLI uses the server API unless `--standalone` is explicitly requested
- **Standalone safety guard**: `workflow run --standalone` aborts when a server is already running unless `--force` is provided
- **`workflow status` is now connected-by-default** with an explicit `--standalone` fallback for local DB inspection
- **Workflow execution unification**: workflow-authored step types now execute through the coding-task path, preserve the original YAML type as `_workflowStepType` metadata, and express non-mutating intent through `readOnly` instead of a separate workflow streaming/restricted branch
- **Workflow structured outputs default to native mode**: `format: json` with `schema` now resolves to provider-enforced structured output by default; explicit `outputMode: prompt` is the opt-out and heuristic JSON parsing is now a fallback path
- **Workflow JSON schema presets hardened for Codex strict mode**: wrapped `story-specs`, `story-plan`, `file-list`, `checklist`, and `project-index` schemas now satisfy the stricter nested-object requirements used by `codex exec --output-schema`
- **Workflow read-only enforcement follows the worktree**: read-only workflow research/writing/analysis steps now fail on file mutations inside their linked worktree instead of only checking the primary project checkout
- **Workflow authoring surface simplified**: `executionMode` / `execution_mode` was removed from workflow YAML and validation now rejects `format: json` outputs that omit a schema
- **Workflow structured outputs**: JSON workflow outputs can now opt into `outputMode: structured`, which uses provider-native schema constraints and stores the structured payload directly on the workflow task for extraction
- **Workflow structured-output happy path is now inline-first**: when a structured-output step already emits a valid `<workflow-context>` payload, DartClaw promotes that inline JSON directly and skips the extra extraction turn; provider-native schema extraction remains the fallback
- **Built-in workflow continuation chains were tightened**: nine low-value `continueSession` edges across `plan-and-implement`, `spec-and-implement`, and `code-review` now start fresh sessions because their review-style inputs are already carried by `contextInputs`
- **Breaking**: `WorkflowTaskConfigKeys` was renamed to `WorkflowTaskConfig`
- **Standalone workflow CI ergonomics**: `workflow run --standalone --json` now emits structured lifecycle events in-process, and the standalone workflow guides now document CI usage, approval-step limitations, and explicit `codex-exec` sandbox configuration
- **Codex auth guidance**: public docs now distinguish persistent `codex` auth from `codex-exec` CI usage and recommend `CODEX_API_KEY` for non-interactive `codex exec` flows while keeping `OPENAI_API_KEY` compatibility visible for the broader Codex provider family
- **Built-in workflow skills expanded to full-capability parity**: the 8 AndThen-derived `dartclaw-*` skills (`review-code`, `review-gap`, `spec`, `plan`, `exec-spec`, `remediate-findings`, `review-doc`, `refactor`) now ship with their full adapted DartClaw methodology instead of the earlier thin stubs, and `discover-project` / `update-state` were revalidated against the S11 contract
- **Shared skill support content completed**: the built-in skill tree now includes the shared `references/` support content and expanded review/spec support files, with relative-path wiring verified in both the source tree and the installed harness-visible copies under `~/.claude/skills/` and `~/.agents/skills/`
- **AndThen migration process documented**: the private milestone artifacts now include a repeatable checklist for porting future AndThen skill changes into DartClaw without reintroducing AndThen-only runtime assumptions
- **Built-in workflow definitions tightened**: skill-backed workflow prompts now act as thin input/output wrappers around the `dartclaw-*` skills, `spec-and-implement` and `plan-and-implement` both use bounded remediation/re-review loops, and the obsolete `research-and-evaluate` built-in workflow was removed from the default set
- **Breaking**: `plan-and-implement` restructured around a first-class per-story sub-pipeline (`story-pipeline` + `foreach`), replacing the flat step list; authored workflow YAMLs targeting the prior shape need to migrate
- **Breaking**: `Task.toJson()` now exposes nested `agentExecution` and optional `workflowStepExecution` objects; `sessionId`, `provider`, `maxTokens`, and `model` are no longer top-level task fields. Web UI, CLI output, REST, and SSE responses were updated together. No backward-compat rehydration — DartClaw is soft-published
- **Breaking**: `dartclaw-spec-plan` skill removed — its responsibilities absorbed into `dartclaw-plan` (Option A merge); PRD creation split out of `dartclaw-plan` into new `dartclaw-prd` skill (altitude split mirroring AndThen 0.13.0)
- **Breaking**: `dartclaw-prd`/`dartclaw-plan`/`dartclaw-spec` Workflow-Step Mode collapsed to a single file-based contract — skills always write files and emit paths; inline-emission branches removed
- **Breaking**: shipped `plan-and-implement.yaml` removed the `review-prd` step; `spec-and-implement.yaml` removed the `review-spec` step; remaining review steps gate on `*_source == synthesized`
- **Workflow skills re-ported from AndThen 0.12.1**: eight SYNC-VERBATIM skills (`dartclaw-spec`, `-exec-spec`, `-review`, `-review-code`, `-review-doc`, `-review-gap`, `-remediate-findings`, `-quick-review`) re-synchronized verbatim + three DC overlays; redundant step-level `prompt:` blocks in shipped YAMLs folded into skill `workflow.default_prompt` + auto-framing
- **Workflow defaults cleanup**: workflow-owned coding tasks auto-advance by default (only explicit `review: always` parks in the Review queue); omitted `gitStrategy.promotion` is inferred from worktree shape; the default Review queue hides workflow-owned parked artifacts with an on-demand workflow-artifact view
- **Workflow structured-output remediation**: the `plan-and-implement` E2E run now completes inside a 3.5M-token budget (3,449,461 tokens consumed). Nine `continueSession` edges tightened, skill scoping cleaned, and Codex one-shot token accounting corrected to treat `turn.completed` as cumulative-per-invocation
- **`dartclaw_workflow` package**: bumped 0.11.0 → 0.12.0 with migration notes for file-based artifact contract, generalized `entryGate`, `gitStrategy.artifacts`, and `externalArtifactMount`

### Fixed

- **Task creation guardrails**: `POST /api/tasks` continues to reject client `configJson` keys prefixed with `_`, preserving the server-owned workflow/internal namespace
- **Standalone agent-backed workflows**: headless standalone runs now provision provider-aware task runners and inject provider credentials, so agent steps no longer queue indefinitely or lose API-key auth outside the server wiring path
- **Codex CI auth compatibility**: `codex-exec` now treats `CODEX_API_KEY` as the primary CI env var, accepts compatible fallback key sources, updates provider-status/validation messaging accordingly, and redacts both Codex/OpenAI API-key env vars from approval payloads
- **Codex one-shot prompt parity**: workflow one-shot execution now forwards `appendSystemPrompt` to both Claude and Codex CLI invocations
- **Codex workflow token accounting**: one-shot workflow usage now treats Codex `turn.completed` token counts as cumulative-per-invocation values instead of summing them, and persists `new_input_tokens` alongside cache-read and output metrics
- **Standalone approval pause messaging**: CLI guidance for approval-paused standalone runs now points operators to start `dartclaw serve` before using `workflow resume` or `workflow cancel`
- **Map/fan-in merge hygiene**: `MergeExecutor` now recognises `git stash pop`'s "already exists, no checkout" overlap (caused by stashed untracked files colliding with files introduced by the merge) and drops the stash entry instead of leaving it behind, keeping the stash list clean across sequential fan-in merges
- **Workflow-branch promotion for top-level / loop-body scopes**: the last branch-touching step in top-level and loop-body scopes now folds back into the integration branch via `promoteAfterSuccess` (previously confined to map/foreach iteration handlers)
- **Legacy `tasks` table migration**: `SqliteTaskRepository` now migrates pre-S34 tables that are missing `agent_execution_id` / `workflow_run_id` instead of crashing at boot; session/provider/max_tokens/model are backfilled onto matching `agent_executions` rows
- **Concurrency bug in execution-repository transactor**: parallel map iterations no longer attempt nested `BEGIN` on the same connection; `SqliteExecutionRepositoryTransactor` serializes transactions through a single-slot queue
- **Pause responsiveness during task-completion wait**: `WorkflowExecutor._waitForTaskCompletion` now subscribes to `WorkflowRunStatusChangedEvent` and re-queries the run after subscription to close the broadcast-race window; pausing a run whose current step is waiting on a task now aborts cleanly with a clear `StateError`
- **Standalone coding-task review honoring**: `TaskExecutor._resolvePostCompletionStatus` now checks `_isCodingTask(task)` rather than only the WSE step type, so standalone coding tasks (no WSE) no longer skip their configured review
- **CLI task-event recorder wiring**: `CliWorkflowWiring` now constructs `TaskExecutor` with the shared `TaskEventRecorder`. The CLI workflow path (used by `dartclaw workflow run` and the workflow E2E integration test) had been silently dropping task error, artifact-created, token, compaction, and structured-output-inline events since the recorder was introduced; the server wiring was correct, but the CLI surface was not. Server-path observability was unaffected
- **Permanent task-failure logging**: `TaskExecutor._markFailed` now logs `errorSummary` via `_log.warning` before recording the event, so failures remain diagnosable in logs even when the event recorder is null or unreachable
- **Workflow publish phase logging**: `WorkflowExecutor._runDeterministicPublish` now emits `info` on start and success, `warning` on a failed publish result, and `severe` when the publish callback throws — previously the 5-10s phase between the last agent step and workflow `completed` was completely silent, masking push/PR-creation errors

---

## [0.16.3]

Architecture Hygiene & Documentation — SDK Package Decomposition Phase 2. Completed the package-boundary cleanup, workflow workspace/skills library, standalone binary build system, and documentation closeout for the 0.16 workflow/runtime platform. 13 stories across 7 phases.

### Added

- **`dartclaw_workflow` package**: unified workflow parsing, validation, registry, built-in definitions, and execution into a dedicated package consumable by both server and CLI surfaces
- **Workflow workspace isolation**: workflow steps now execute with a dedicated behavior workspace (built-in `AGENTS.md` guardrails), separate from the main interactive workspace. Operators can override via `workflow.workspace_dir` config field
- **Built-in skill library**: 10 `dartclaw-*` skills shipped as markdown assets in `packages/dartclaw_workflow/skills/` — `discover-project` (detects 6 SDD frameworks), `update-state`, `review-code`, `review-gap`, `spec`, `plan`, `exec-spec`, `remediate-findings`, `review-doc`, `refactor`. Each includes `SKILL.md` + `agents/openai.yaml` per [Agent Skills spec](https://agentskills.io/specification)
- **Skill materialization**: built-in skills are materialized to user-scoped harness directories (`~/.claude/skills/`, `~/.agents/skills/`) at startup with FNV-1a fingerprinting and `.dartclaw-managed` provenance markers; user overrides are preserved
- **Integration & scenario testing framework**: tagged integration tests for governance and thread-binding; governance testing profile at `docs/testing/workflows/`
- **Workflow architecture deep-dive**: private architecture docs now include a full workflow architecture reference covering the definition model, parser/validator contract, context extraction chain, gates, loops, map/fan-out, crash recovery, and built-in workflow catalog
- **Architecture fitness functions**: `tool/arch_check.dart` now enforces cycle freedom, `sqlite3` exclusion from `dartclaw_core`, no cross-package `src/` imports, core LOC/export ceilings, and workspace package-count limits
- **Standalone binary build system**: `tool/build.sh` now compiles `build/dartclaw` and packages external asset archives for templates, static assets, skills, and workflows, plus SHA256 checksums for release publication. `.github/workflows/ci.yml` runs check + build jobs and uploads platform artifacts
- **CLI reference**: new `cli-reference.md` in the public guide documenting all `dartclaw` subcommands (`serve`, `init`, `status`, `token`, `sessions`, `workflow`, `service`, `rebuild-index`)

### Changed

- **Workflow consolidation**: built-in workflows reduced from 10 to 4 (`spec-and-implement`, `plan-and-implement`, `code-review`, `research-and-evaluate`), all referencing `dartclaw-*` skills with `discover-project` as step 0. The four 0.16.1 workflow packs (`adversarial-dev`, `idea-to-pr`, `workflow-builder`, `comprehensive-pr-review`) were absorbed into this surface — their delivery, authoring, and review patterns are covered by the skill-backed built-ins plus user-authored workflows. (0.16.4 further removed `research-and-evaluate`, leaving the 3 shipped today.)
- **Evaluator removal**: the `evaluator` step field has been removed from the workflow model, parser, validator, executor, and prompt augmenter
- **Package decomposition**: moved shared model types into `dartclaw_models`, moved config parsing and config types into `dartclaw_config`, and kept `dartclaw_core` focused on runtime primitives
- **Config dependency direction**: the workspace now uses the intended `models -> security -> config -> core` layering, with direct config imports instead of a `dartclaw_core` config facade
- **Container ownership**: container orchestration lives in `dartclaw_server`; `dartclaw_core` retains only the abstract container executor boundary
- **Public and private docs**: README, roadmap, architecture markers, ADR status formatting, and SDK/package reference material were synchronized with the shipped 0.16.3 structure

### Fixed

- **Architecture hygiene remediation**: removed stale workflow barrel exports, restored explicit config imports across the workspace, fixed residual analyzer findings from the extraction, and brought the public workspace back to `dart analyze` clean
- **Documentation completion gaps**: `data-model.md` now reflects 0.16.3, README version reporting is current, and the workflow architecture doc now meets the original depth target

---

## [0.16.2]

CLI Onboarding Wizard — guided first-run setup, unified instance directory, background service management, and verification/launch handoff. 6 stories across 4 phases: foundation → core setup → operations → advanced configuration.

### Added

- **Unified instance directory & config discovery** (S01): `~/.dartclaw/` is now the canonical home for config, workspace, sessions, logs, and databases. `DARTCLAW_HOME` env var supports multi-instance layouts. Config discovery follows `--config` > `DARTCLAW_CONFIG` > `DARTCLAW_HOME` > `~/.dartclaw/dartclaw.yaml`. CWD-level `./dartclaw.yaml` discovery deprecated with a warning
- **`dartclaw init` command** (S02–S03): Primary setup entrypoint (`dartclaw setup` as alias) that creates a runnable instance through preflight checks, config generation, workspace scaffold, and `ONBOARDING.md` seeding. Non-interactive mode (`--non-interactive`) accepts all inputs via flags for scripts and CI. Interactive Quick-track wizard (mason_logger TUI) collects provider, auth, model, port, and gateway-auth in seconds. Re-running against an existing instance shows current values as defaults and never overwrites curated behavior files
- **Service management** (S04): `dartclaw service install|uninstall|status|start|stop` manages DartClaw as a user-scoped background service — LaunchAgent on macOS, `systemd --user` on Linux — without requiring root. Service units are instance-scoped via directory hash, so multiple instances coexist cleanly. `--source-dir` is carried into generated units to resolve templates outside the source tree
- **Verification & launch completion** (S05): Local verification (config parse, binary presence, writable paths, port availability) always runs before setup reports success. Optional network verification (provider credential probes), skippable with `--skip-verify`, yields an explicit "configured but unverified" state. Post-setup launch choices: `--launch foreground`, `--launch background`, `--launch service`, or `--launch skip` (default)
- **Full-track advanced configuration** (S06): `dartclaw init --track full` widens the wizard to collect channel inputs (WhatsApp, Signal, Google Chat) and advanced runtime options (container isolation, guard toggles) without lengthening Quick-track. Every interactive prompt has a non-interactive flag equivalent. Deferred steps (QR pairing, Signal linking, webhook registration) are noted with explicit post-serve instructions rather than simulated in the wizard

### Improved

- **Workflow list page**: Run cards now display token count in the meta row alongside step progress and start time
- **Workflow detail page**: Metadata section upgraded from flat label/value layout to a 4-column metric card grid (Status, Started, Tokens, Duration); progress bar now shows completion percentage; step pipeline uses colored circular icons (checkmark/dot/circle) instead of text status badges
- **Workflow step detail**: Artifact labels replaced with typed colored badge pills (Diff, Document, Data, PR); step metrics footer now includes duration alongside token count
- **Canvas standalone page**: Permission chip now uses distinct accent (interact) vs muted (view) styling; connection status indicator shows text labels (Connected/Reconnecting/Disconnected) alongside the dot; heading includes accent-colored logo mark
- **Canvas admin page**: Live Canvas and Share Links cards now render in a side-by-side two-column grid on wide viewports (single column below 960px)

### Fixed

- **Gap review fixes**: Config-discovery edge cases for `DARTCLAW_HOME` with trailing slashes and symlinked instance directories; service-backend error handling for stale PID files and pre-existing units; preflight port-check race condition when multiple init processes target the same port

### Changed

- **Config discovery order**: `./dartclaw.yaml` CWD-level discovery removed from default resolution. Use `--config ./dartclaw.yaml` for explicit project-level configs
- **Default port**: Changed from `3000` to `3333` in examples and defaults
- **`dartclaw deploy setup` deprecated**: Now emits a deprecation notice and redirects to `dartclaw init`. The old root-scoped daemon workflow is replaced by user-scoped `dartclaw service`
- **Public guides updated**: `getting-started.md`, `configuration.md`, and `deployment.md` rewritten for the instance-directory model, `dartclaw init`, and `dartclaw service`

---

## [0.16.1]

Workflow Engine: Hybrid Steps, Workflow Packs, and 0.16 Stabilization — hybrid workflow execution primitives, built-in workflow packs, summary-first workflow discovery, and follow-up hardening from dual gap-review passes.

### Added

- **Hybrid workflow schema + validation CLI** (S01): Workflow definitions now support `bash`, `approval`, `continueSession`, `onError`, and `workdir` while remaining backward-compatible with 0.15/0.15.1 definitions. Validation warnings are now first-class alongside hard errors, and operators can validate definitions without execution via `dartclaw workflow validate <path>`
- **Host-side bash steps + step-level failure policy** (S02): `type: bash` runs deterministically on the host with template substitution, shell-escaped context interpolation, `workdir` support, stdout/stderr capture, timeout handling, and existing `text`/`json`/`lines` output extraction. `onError: pause|continue` now applies to both bash and agent steps
- **Approval gates + explicit approval pause flow** (S03): `type: approval` adds a zero-token human checkpoint to workflows using the existing paused lifecycle, with explicit approval metadata carried through the API, UI, SSE, and resume/cancel flows
- **Session continuity + worktree context bridge** (S04): Agent steps can now opt into `continueSession` to reuse a prior step's conversation context through a validated linear chain, while coding steps automatically expose branch/worktree metadata into workflow context for downstream deterministic steps
- **Built-in delivery workflow pack** (S05): Added `adversarial-dev` for evaluator-isolated adversarial iteration and `idea-to-pr` for hybrid delivery flows that combine planning, approval, coding, deterministic validation, review fan-out, and PR creation
- **Built-in authoring/review workflow pack** (S06): Added `workflow-builder`, which goes from workflow description to YAML to validation summary, and `comprehensive-pr-review`, which performs deterministic diff extraction, parallel specialized review, and synthesis
- **Progressive-disclosure workflow discovery** (S07): Workflow registry/API/browser contracts are now summary-first by default, with on-demand full-definition fetches so the picker and browser stay context-efficient while still supporting detailed inspection
- **0.16 stabilization follow-through**: Server/CLI verification reliability, hot-reload end-to-end coverage, SSE continuity across reloadable config changes, and the guard-chain reconfigurability seam were tightened so package-wide verification and docs match the shipped architecture again

### Fixed

- **Parallel hybrid-step execution + result preservation**: Parallel groups now execute through the shared step runtime instead of a legacy task-only path, so hybrid steps keep the same behavior as sequential execution. Parallel result merging now preserves explicit step metadata including bash success state, status fields, and session identifiers
- **Approval timeout lifecycle + UI/API state**: Approval timeouts now surface as `timed_out` in workflow run status views instead of appearing as a generic paused state. Approval payloads on workflow pages and API responses now retain timeout/cancel details needed to explain why execution stopped
- **Workflow authoring validation hardening**: Validation now rejects `continueSession` on `parallel: true` steps, rejects multi-prompt `bash` and `approval` steps that cannot safely continue across turns, rejects empty `workdir` values instead of silently resolving to the process CWD, and continues continuity checks in CLI validation even when no configured providers support them
- **Timeout field compatibility**: Workflow parsing now accepts `timeoutSeconds` as a compatibility alias while documentation remains canonical on `timeout`
- **Built-in workflow prompt/file safety**: Built-in workflow definitions no longer rely on unsafe heredoc interpolation for branch names, PR bodies, or generated YAML content. The `idea-to-pr` approval step now includes an explicit approval prompt instead of an empty one
- **Unsupported `onError` feedback**: Unsupported `onError` values now emit validation warnings instead of failing silently, aligning the validator with documented runtime behavior

### Changed

- **Workflow authoring guide**: `docs/guide/workflows.md` updated to document the canonical timeout field, clarify compatibility behavior, and stay aligned with the hardened validator/runtime contract

## [0.16.0]

Always-On Foundation — compaction observability, live config Tier 3, alert-routing primitives, guard hot-reload, and harness hardening. 14 stories across 5 phases: compaction observability, hot-reload, harness hardening, alert routing, and guard-chain reconfiguration.

### Added

- **Compaction observability + context hardening** (S01-S03): `CompactionStartingEvent` / `CompactionCompletedEvent` added to the shared event model. Claude now emits deterministic compaction lifecycle signals via `PreCompact` + `compact_boundary`, Codex parses `contextCompaction` items into bridge events, running task sessions record `compaction` timeline entries, and pre-compaction flushes gain SHA-256 dedup plus identifier-preservation instructions
- **Live Config Tier 3** (S04-S07): `ConfigNotifier`, `ConfigDelta`, and `Reconfigurable` provide section-scoped hot-reload for runtime-owned services. `gateway.reload` adds `off` / `signal` / `auto` modes, with `ReloadTriggerService` handling `SIGUSR1` and parent-directory file watching with debounce. The config API now distinguishes live, reloadable, and restart-required fields
- **Alert-routing subsystem** (S08-S10): `AlertsConfig`, `AlertRouter`, `AlertDeliveryAdapter`, `AlertFormatter`, and `AlertThrottle` add explicit channel alert targets, severity-aware formatting (plain text for WhatsApp/Signal, Cards v2 for Google Chat), per-target cooldowns, and burst-summary aggregation
- **Guard-chain hot-reload** (S11): `SecurityWiring` rebuilds guards on `guards.*` config changes and atomically swaps the active guard list. Duplicate rules are deduplicated, conflicting or invalid rules preserve the previous chain, `MessageRedactor` stays reloadable through an adapter, and `InputSanitizer` is refreshed as part of the rebuilt guard chain
- **Harness hardening refresh** (S12-S14): Claude hook registration now includes `PermissionDenied` and `PreCompact`, `PreToolUse` uses `if:` filtering to reduce unnecessary callback traffic, Codex v0.118.0 response-shape compatibility was audited, and Anthropic MCP tool schemas were updated for SDK v1.4.2 compliance

### Fixed

- **Milestone integration gaps**: production wiring now instantiates the alert pipeline, Codex `contextCompaction` bridge events now reach the shared EventBus model, compaction-hook availability is resolved per runner, alert cooldown expiry and Google Chat burst-summary formatting now match the shipped contract, and invalid `guards.*` reloads no longer partially mutate the live sanitizer state

### Changed

- **Version display**: Updated from 0.15.0 to 0.16.0
- **Architecture docs**: `system-architecture.md`, `data-model.md`, `control-protocol.md`, and `security-architecture.md` updated to "Current through 0.16"
- **Public architecture guide**: Updated to "Current through 0.16" and clarified the mixed Claude/Codex provider trust model
- **Feature comparison**: 0.16 additions marked in `docs/specs/feature-comparison.md`

## [0.15.1]

Workflow Engine Refinements — output format parsing with schema presets, multi-prompt step sessions, loop finalizers, pattern-based step config defaults, skill discovery + skill-aware workflow steps, task-scoped prompt composition, map/fan-out step execution, built-in plan-and-execute workflow, and workflow authoring guide. 9 stories across 5 phases, all additive and backward-compatible.

### Added

- **Output format parsing + schema presets** (S01): Per-key `outputs` with `format` (text/json/lines), optional `schema` (preset name or inline JSON Schema). 4-strategy JSON extraction engine (raw → json-fenced → bare-fenced → brace/bracket scan). 4 built-in schema presets (`verdict`, `story-plan`, `file-list`, `checklist`) with prompt augmentation ("Required Output Format" section). Evaluator default: `evaluator: true` + `format: json` + no `schema:` → `verdict`. Schema soft validation (warning on mismatch, no failure)
- **Multi-prompt step sessions** (S02): `WorkflowStep.prompt` accepts list of strings. Prompts 2..N run as follow-up turns via `resume: true` on same session. Only final turn's output extracted. Cumulative budget enforcement. Validation error for non-continuity providers
- **Loop finalizer** (S03): Optional `finally` field on loop constructs. Runs after loop termination regardless of exit reason (gate pass, maxIterations, step failure). Validation rejects finalizer referencing loop-internal steps
- **Pattern-based step config defaults** (S03): `stepDefaults` section on `WorkflowDefinition` with glob `match` patterns. First-match-wins. Per-step explicit config takes precedence. Config resolution: per-step → first matching default → workflow-level → global
- **Skill discovery registry** (S04): `SkillRegistry` with 6 prioritized source directories. YAML frontmatter parsing. Security: symlink blocking, 512KB file size limit, executable warnings. Deduplication by name. `GET /api/skills` endpoint
- **Skill-aware workflow steps** (S04): Optional `skill` field on `WorkflowStep`. Prompt construction: "Use the '<skill>' skill. <context>". Load-time validation (skill exists, provider compatibility). 4-case handling (skill+prompt, skill-only, prompt-only, error)
- **Task-scoped prompt composition** (S05): `PromptScope` enum (`interactive`, `task`, `restricted`, `evaluator`). Scope-aware `composeSystemPrompt(scope:)` and `composeStaticPrompt(scope:)`. `task` scope excludes USER.md, MEMORY.md, errors.md, learnings.md, compact instructions. Scope selection in `TaskExecutor`: evaluator/restricted/task. Project SOUL.md deprecated
- **Append-mode scoped startup prompts** (S09): Task pool runners spawned with `task`-scoped startup prompt instead of full interactive prompt. Primary runner unchanged. Token reduction at spawn time
- **Map step model + template engine** (S06): `mapOver`, `maxParallel`, `maxItems` on `WorkflowStep`. Template variables `{{map.item}}`, `{{map.index}}`, `{{map.length}}`. Dot notation field access (3 levels). Indexed context `{{context.key[map.index]}}`. Object items → JSON-serialized, scalar → string
- **Map step execution engine** (S07): Bounded-concurrency dispatch loop with `effectiveConcurrency(poolAvailable)`. Dependency ordering via topological sort. Error handling: failed iterations → error objects in result array, others continue. Budget exhaustion → remaining cancelled. `MapIterationCompletedEvent`, `MapStepCompletedEvent` SSE events
- **Built-in plan-and-execute workflow** (S08): Plan step (schema: story-plan, inline prompt) → implement (map_over, coding) → review (map_over, evaluator, cross-map indexed context). Uses `stepDefaults`
- **Workflow authoring guide** (S08): "Writing Custom Workflows" at `docs/guide/workflows.md`. 7-step progressive refinement, Shopify Roast "handwave" philosophy, all new YAML fields, dependency limitation for coding map steps

### Fixed

- **ContextExtractor throw on empty session** (gap review M1): `_extractFromAgentConvention` threw `StateError` when no assistant messages existed. Now returns null gracefully
- **Loop metadata cleanup** (gap review L1): `_loop.current.stepId` was not cleaned up after loop completion due to specific-key removal instead of prefix filtering. Now uses `!e.key.startsWith('_loop.current')` matching the map cleanup pattern

### Changed

- **Architecture docs**: `system-architecture.md`, `data-model.md` updated to "Current through 0.15.1"

---

## [0.15.0]

Workflow Platform — deterministic multi-step agent orchestration in compiled Dart. Replaces LLM-driven prompt choreography with a `WorkflowExecutor` that uses `Future.wait()` for parallelism, `try/catch` for error handling, and real process control for stuck detection. 12 stories across 4 phases: foundation → engine core → content & refinements → workflow UI.

### Added

- **Workflow data model + YAML parsing** (S02): `WorkflowDefinition`, `WorkflowStep`, `WorkflowVariable`, `WorkflowContext`, `WorkflowRun` models. YAML parser with schema validation (required fields, unique step IDs, valid variable references, gate syntax, loop constraints). `{{variable}}` and `{{context.key}}` template engine. `WorkflowRun` persistence in SQLite
- **WorkflowExecutor — sequential execution** (S03): Processes steps sequentially, resolves prompt templates against `WorkflowContext`, creates Tasks via `TaskService`, waits for completion, extracts context outputs (artifact-to-context mapping). State machine: `pending → running → paused → completed/failed/cancelled`. Crash recovery resumes from last completed step. Gate expressions block steps when conditions not met
- **Parallel step groups** (S04): Contiguous `parallel: true` steps collected into groups and executed concurrently via `Future.wait()`, bounded by `HarnessPool` capacity. Results merged in definition order. Partial failure: other steps complete, workflow pauses. Resume re-runs only failed steps (successful outputs preserved)
- **Iterative loops** (S04): `maxIterations` circuit breaker, `exitGate` (agent-evaluated exit condition), sequential step execution per iteration. Context accumulates per iteration (`loop.<id>.iteration` counter). Pauses if `maxIterations` reached without gate passing
- **Workflow API routes** (S05): `POST /api/workflows/run`, `GET /api/workflows/runs`, `GET /api/workflows/runs/<id>`, pause/resume/cancel endpoints, `GET /api/workflows/definitions`. Auth required on all endpoints
- **5 built-in workflows** (S06): `spec-and-implement` (6 steps), `research-and-evaluate` (4 steps), `fix-bug` (5 steps), `refactor` (4 steps), `review-and-remediate` (4 steps with iterative loop). Evaluator calibration (anti-leniency, structured grading, acceptance criteria reference). `WorkflowRegistry` with custom workflow discovery from workspace directories
- **CLI workflow commands** (S07): `dartclaw workflow list`, `run <name> --var KEY=VALUE`, `status <runId>`. Structured machine-parseable progress output. Exit codes: 0=completed, 1=failed, 2=paused. Review steps auto-accepted in headless mode
- **Per-task token budget enforcement** (S01): `maxTokens` on Task model. 80% warning (`BudgetWarningEvent` + agent system message), 100% hard-stop (`budget_exceeded` status + `BudgetArtifact`). `tasks.budget.*` config section. Fail-safe open policy
- **Per-task autonomy dial** (S08): `allowedTools` (tool subset restriction), `reviewMode` (`auto-accept`/`mandatory`/`coding-only`), `model` override per task. "Advanced" section in New Task dialog
- **Auto-retry with loop detection** (S09): `maxRetries` on Task (opt-in). Re-queues failed tasks with error context in prompt. Same error class on consecutive attempts → permanent failure. Per-retry budget reset. Workflow pauses only after all retries exhausted
- **Workflow picker** (S10): Tab switcher in New Task dialog: "Single Task" | "Workflow". Variable input form generated from definition, project selector for scoped steps
- **Workflow run detail page** (S11): Vertical pipeline visualization at `/workflows/<runId>`. Per-step status badges, live SSE updates, expandable task chat panels, progress bar, context viewer, loop iteration indicator, pause/resume/cancel actions
- **Workflow management page + sidebar** (S12): Run listing with status/definition filtering, definition browser. Active workflows in sidebar with step progress indicator, notification badges, link to detail page. SSE for live sidebar updates
- **Workflow-level budget warnings** (gap fix H2): `WorkflowBudgetWarningEvent` fires once at 80% of `maxTokens` ceiling before hard-stop at 100%
- **Per-task tool filter guard** (`dartclaw_security`): `TaskToolFilterGuard` enforces `allowedTools` restriction in the guard pipeline

### Fixed

- **Parallel-group resume skipped failed steps** (gap fix H1): `currentStepIndex` was advanced past the group before checking failures. Now stays at group start on failure; resume detects `_parallel.failed.stepIds` and re-executes only those steps
- **Loop-step resume replayed entire iteration** (gap fix M1): Persists `_loop.current.stepId` on failure. Resume skips already-completed steps within the iteration, re-runs from the failed step. Crash recovery still re-runs the full iteration (distinct from user resume)
- **Executor crashes left runs stuck in `running`** (gap fix M2): Unexpected exceptions in `_spawnExecutor()` now transition the run to `WorkflowRunStatus.failed` with error message and fire `WorkflowRunStatusChangedEvent`
- **Loop workflows showed impossible progress** (gap fix M3): Management page and sidebar counted raw accepted tasks instead of unique step indices. Loop iterations overcounted (e.g., "5/4 steps"). Now uses distinct `stepIndex` values, clamped to `totalSteps`

### Changed

- **Version display**: Updated from 0.14.7 to 0.15.0
- **Architecture docs**: `system-architecture.md`, `data-model.md`, `control-protocol.md`, `security-architecture.md` updated to "Current through: 0.15"
- **Public architecture guide**: Updated to "Current through: 0.15"
- **Ubiquitous language**: 10 workflow terms added (Workflow, Workflow Run, Workflow Step, Workflow Context, Workflow Definition, Loop Iteration, Parallel Group, Exit Gate, WorkflowExecutor, WorkflowRegistry)
- **Feature comparison**: Workflow engine marked as shipped in 0.15

---

## [0.14.7]

Preparatory Refactoring — internal structural improvements ahead of 0.15 Workflow Platform. ~7,300 lines removed, ~1,300 added across 68 files in 9 packages. Pure SRP-driven file splits, base class extraction, pattern consolidation, and test double deduplication. Zero behavioral changes, zero public API changes, zero barrel export changes.

### Added

- **`BaseHarness` abstract class**: Shared lifecycle state machine, crash recovery with exponential backoff, and stream management extracted from `ClaudeCodeHarness`, `CodexHarness`, and `CodexExecHarness`. Three template methods (`buildStartArgs`, `buildProtocolAdapter`, `configureHarness`) define the extension points
- **`BaseProtocolAdapter` + shared protocol utilities**: Common JSONL parsing functions (`decodeJsonObject`, `mapValue`, `stringValue`, `intValue`, etc.) and Codex tool name mapping extracted from duplicated adapter code
- **`CommonChannelFields<T>` generic class**: Shared YAML parsing for the ~140 LOC of field extraction duplicated between `WhatsAppConfig` and `SignalConfig` (enabled, dmAccess, groupAccess, allowlists, mention patterns, retry policy, task trigger)
- **`TurnGuardEvaluator` + `TurnGovernanceEnforcer`**: Guard chain evaluation and governance enforcement (budget, loop detection, rate limiting) extracted from `TurnRunner` into focused collaborators
- **`DartclawServerBuilder`**: Builder extracted from `server.dart` — constructs the server handler from `ServiceWiring`
- **`ReviewCommandDispatcher`**: Review command handling (accept/reject/push back, task resolution, response formatting) extracted from channel bridge support into a focused single-responsibility collaborator
- **Server builder integration test (TD-047)**: End-to-end test constructing `ServiceWiring` with realistic config, asserting `builder.build()` produces a working handler that serves `/` and `/health`
- **8 shared test doubles in `dartclaw_testing`**: `NullIoSink`, `RecordingMessageQueue`, `FakeGoogleChatRestClient`, `FakeGoogleJwtVerifier`, `FakeProjectService`, `FakeTurnManager`, `TaskOps`, `RecordingReviewHandler` — replacing 46+ private copies across test files
- **`flushAsync` shared helper**: Microtask drain utility using `Duration.zero` timer-queue yields, replacing 11 private copies with inconsistent delay strategies
- **`dart_test.yaml`** in `apps/dartclaw_cli/` for integration-tagged test support

### Changed

- **`dartclaw_config.dart` decomposed** (2,171 → ~300 LOC): Split into `config_parser.dart` (~1,400 LOC), `config_channel_provider.dart` (~150 LOC), `config_extensions.dart` (~100 LOC), and `config_parser_governance.dart` via `part` files
- **`governance_config.dart` decomposed**: 12 types split into `rate_limits_config.dart`, `budget_config.dart`, `loop_detection_config.dart`, `crowd_coding_config.dart`, `turn_progress_config.dart`
- **`dartclaw_event.dart` decomposed**: 20+ sealed event types split into 8 domain-specific `part of` files (auth, session, task, container, agent, governance, advisor, project) — sealed exhaustiveness preserved
- **`channel_task_bridge.dart` decomposed** (598 → 182 LOC): Split into `task_trigger_evaluator.dart`, `thread_binding_router.dart`, `channel_task_bridge_support.dart`, and `review_command_dispatcher.dart`
- **`server.dart` decomposed**: `DartclawServerBuilder` extracted to `server_builder.dart`
- **`turn_runner.dart` decomposed**: Guard evaluation and governance enforcement extracted to `turn_guard_evaluator.dart` and `turn_governance_enforcer.dart`
- **Utilities relocated**: `duration_parser.dart` moved from `utils/` to `config/`; `sliding_window_rate_limiter.dart` moved from `utils/` to `governance/`
- **Removed `dartclaw_google_chat` dev dependency** from `dartclaw_core` — cross-boundary test import fixed
- **Redundant channel bridge tests removed**: `channel_task_bridge_review_test.dart` eliminated — coverage maintained by equivalent manager-level tests
- **`TESTING-STRATEGY.md`** refreshed to "Current through 0.14.7" with shared fakes table
- **Version display**: Updated from 0.14.6 to 0.14.7

---

## [0.14.6]

Harness Spawn Hardening — security environment defaults on all Claude spawns and cheaper subagent routing on task runners. `--bare` mode evaluated and rejected after live CLI validation showed it is incompatible with DartClaw's hook-based harness behavior and OAuth-backed local workflows.

### Added

- **Security environment variables on all harness spawns**: `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`, `DISABLE_AUTOUPDATER=1`, and `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` applied to every Claude process — both direct spawns (host environment map) and containerized spawns (`docker exec -e`). Reduces credential-exfiltration risk, prevents mid-session updater surprises, and suppresses non-essential traffic
- **Task-runner subagent model routing**: `CLAUDE_CODE_SUBAGENT_MODEL=sonnet` set on lazily spawned task runners only, reducing background-work cost without affecting the primary interactive runner. Forwarded through both direct and containerized spawn paths
- **Shared `claudeHardeningEnvVars` constant**: Single source of truth for security env vars in `claude_protocol.dart`, exported from `dartclaw_core` barrel. Eliminates previous duplication across harness and wiring layers
- **Positive OAuth startup test**: Regression guard verifying harness startup succeeds with local OAuth auth and no `ANTHROPIC_API_KEY`

### Fixed

- **Workspace containers received no env vars**: Previously, workspace-profile containers passed `null` to `ContainerManager.exec(env:)`, silently skipping all environment injection. Now receives hardening vars alongside restricted containers
- **Parent shell `CLAUDE_CODE_SUBAGENT_MODEL` leaked into primary runner**: `_providerEnvironment()` now strips `CLAUDE_CODE_SUBAGENT_MODEL` from the inherited `Platform.environment` before composing the base env map, ensuring only task runners receive it
- **Stale `ClaudeCodeHarness` capability test**: `codex_harness_crash_test.dart` expected `supportsCachedTokens == false` but the harness now returns `true`

### Changed

- **Version display**: Updated from 0.14.5 to 0.14.6

---

## [0.14.5]

Multi-Space Configuration — per-group model/effort overrides, project binding, structured allowlist entries, and conversation history recovery. Groups across all channels (WhatsApp, Signal, Google Chat) can now be independently configured with display names, project bindings, and model/effort overrides via structured YAML entries. The flat string allowlist format remains backward-compatible.

### Added

- **`GroupEntry` data class** (S02): Shared model in `dartclaw_core` with `parseList()` for mixed string/map YAML parsing. Supports `id`, `name`, `project`, `model`, and `effort` fields. Malformed entries skipped with warning; duplicate IDs resolve last-entry-wins
- **`GroupConfigResolver` lookup service** (S02): Keyed by `(ChannelType, groupId)` with config-key-to-runtime-key normalization (`google_chat` → `googlechat`). Returns `GroupEntry` for structured entries, `null` for plain strings
- **Structured `group_allowlist` entries** (S02): All three channel configs (`WhatsAppConfig`, `SignalConfig`, `GoogleChatConfig`) upgraded from `List<String>` to `List<GroupEntry>`. `groupIds` convenience getter preserves backward compatibility with existing access control call sites
- **Per-group model/effort overrides** (S03): `resolveChannelTurnOverrides()` extended with per-group tier as highest precedence — structured `GroupEntry` with `model`/`effort` overrides applies before per-channel and crowd-coding fallback chain. Explicit regression preservation for `governance.crowd_coding.model`/`effort` when no per-group override exists
- **Per-group project binding** (S03): `TaskCreator` typedef extended with `String? projectId` named parameter. `ChannelTaskBridge` looks up `GroupEntry.project` via `GroupConfigResolver` and passes through task creation. Invalid/missing project ID falls back to default with warning
- **`GroupEntry.name` display name resolution** (S02): Wired into `GroupSessionInitializer` display name chain — structured name → resolver callback → raw ID. Appears as session title in sidebar for shared-scope groups
- **`HistoryConfig`** (S01): `agent.history` config sub-section with `max_message_chars` and `max_total_chars` budget fields for controlling conversation history injection size
- **Process spawn logging**: `ClaudeCodeHarness` now logs generation number and PID when spawning the Claude process

### Fixed

- **Conversation history lost on harness restart** (S01): Replay-safe history injection via `<conversation_history>` block in user message content on cold process turns. Filters out guard-blocked exchanges, synthetic markers, and interrupted turns. `_turnsSinceStart` counter gates injection to cold process only (first turn after start/restart)
- **False harness restarts on effort mismatch** (S01): Effort tolerance in restart check — adopts per-turn effort on first use without restarting when `_processEffort` is null. Parameter-change restarts now emit warning log entry
- **Dead `_withConversationHistory()` removed** (S01): Replaced by `buildReplaySafeHistory()`. `ClaudeProtocolAdapter.buildTurnRequest()` `history` param documented as intentionally unused (kept for Codex compatibility)
- **`system:init` protocol documentation**: Corrected — emitted per-turn (not once per session) by the Claude CLI

### Changed

- **`ChannelGroupConfig` DTO**: `groupAllowlist` field renamed to `groupEntries` carrying `List<GroupEntry>`
- **`ConfigChangedEvent` handling**: Updated for structured group entries
- **Version display**: Updated from 0.14.4 to 0.14.5

---

## [0.14.4]

### Added

- **Google Chat quoted replies**: Outbound messages include `quotedMessageMetadata` referencing the inbound message, showing the original user message as a quoted excerpt in the reply. Works for both plain text and Cards v2 responses. Only activates for Google Chat-originated messages
- **Configurable typing indicator mode**: `typing_indicator` config accepts `true` (placeholder message, default), `false` (disabled), or `emoji` (react with eyes emoji on inbound message). Emoji mode avoids the placeholder edit conflict with quoted replies. Adds `addReaction`/`removeReaction` to `GoogleChatRestClient`
- **`--source-dir` CLI flag**: Sets the base directory for resolving default template and static file paths when running from an external directory. Eliminates the need for symlinks. Also supported via `source_dir` in YAML. Resolution: `--templates-dir`/`--static-dir` > YAML > source-dir-relative > defaults
- **`--templates-dir` CLI flag**: Explicit HTML templates directory override, same pattern as existing `--static-dir`
- **`deleteMessage` in `GoogleChatRestClient`**: Deletes a Google Chat message by resource name

### Fixed

- **Sender attribution broken via Space Events path**: `getMemberDisplayName` constructed an invalid API URL (`spaces/{space}/members/users/{id}` instead of `spaces/{space}/members/{id}`), returning HTTP 404. When Pub/Sub won the dedup race and the CloudEvent payload lacked `sender.displayName`, the fallback API call always failed, silently dropping sender attribution
- **Channel turns lost conversation history on restart**: Two issues — (1) `_dispatchChannelTurn` only passed `[userMsg]` to the harness instead of the full session history, (2) `ClaudeCodeHarness.turn()` only sent `messages.last` to the CLI, ignoring prior entries. Now loads all persisted messages and injects prior conversation history into the system prompt so the CLI has context even after process restart
- **Dispatcher path lost inbound message metadata**: The webhook handler's dispatcher fallback (`_sendChunks`) dropped `senderDisplayName`, `spaceType`, `messageName`, and `messageCreateTime` from outbound `ChannelResponse` chunks. Replaced with `_formatWithMetadata()` that reconstructs metadata from the original `ChannelMessage`, matching the `MessageQueue` pattern
- **409 ALREADY_EXISTS in Space Events subscriptions**: `_createSubscription` now recovers when Google returns 409 by extracting the existing subscription name from the error response, fetching its details via GET, and persisting locally. Previously returned null, silently losing the subscription on restart
- **Quoted replies with typing indicator**: When quoting is active and a typing indicator placeholder exists, the placeholder is deleted before sending the quoted reply (placeholder edits cannot carry `quotedMessageMetadata`)

### Changed

- **`typing_indicator` config type**: Changed from `bool` to enum (`disabled`/`message`/`emoji`). Boolean values still accepted for backward compatibility
- **`messageNamePattern` visibility**: Promoted from file-private to public in `GoogleChatRestClient` for reuse in channel quoting logic

---

## [0.14.3] — 2026-03-25

Crowd Coding Intelligence — per-context model routing, sender-fair queueing, cross-channel task binding, and an advisory observer agent. DartClaw becomes the first agent runtime with built-in crowd coding intelligence: facilitators can tune model cost/performance per session scope, ensure equitable agent attention across participants, steer a single task from multiple channels simultaneously, and receive periodic strategic insights from a secondary observer agent.

### Added

#### Phase A — Per-Context Model Routing
- **Crowd coding model routing** (S01): `CrowdCodingConfig` with `model` and `effort` fields as a new sub-section under `GovernanceConfig`. Optional `model` and `effort` fields on `SessionScopeConfig` and `ChannelScopeConfig` for per-scope and per-channel overrides. Model resolution chain: per-task `configJson['model']` > per-channel `sessions.channels.<type>.model` > per-scope `sessions.model` > `governance.crowd_coding.model` > global `agent.model`. `resolveChannelTurnOverrides()` in `model_resolver.dart` wires the chain into channel dispatch. Crowd coding model applies only to group sessions. All new fields default to `null` — existing behavior preserved

#### Phase B — Per-Sender Queue Fairness
- **Sender-aware debounce + per-sender queue depth limit** (S02): `MessageQueue` debounce restructured from per-session to per-sender-per-session via `_DebounceKey` record type `({String sessionKey, String senderJid})`. Each sender's rapid-fire messages are coalesced independently while preserving sender boundaries in the queue. `governance.rate_limits.per_sender.max_queued` config field (default 0 = disabled) caps queued entries per sender — overflow rejected with "Queue full" response. `governance.rate_limits.per_sender.max_pause_queued` for per-sender depth within `PauseController`. Admin senders exempt per existing `isAdmin()` pattern
- **Round-robin sender scheduling** (S03): `governance.queue_strategy` config field (`fifo` | `fair`, default `fifo`). Fair mode drains messages in round-robin order across senders within a session. Circular sender rotation with late-arriving sender inclusion in next cycle. Sender sub-queue removal on empty

#### Phase C — Cross-Channel Session Binding
- **Multi-channel binding store** (S04): `ThreadBindingStore.lookupByTask()` returns `List<ThreadBinding>` instead of single match. `deleteByTaskId()` removes all bindings for a task across channels. `ThreadBindingLifecycleManager._onTaskStatusChanged()` invokes corrected multi-binding cleanup. Idle timeout cleanup handles all expired bindings per task
- **Bind/unbind channel commands** (S05): `/bind <taskId>` and `/unbind` as admin-only reserved commands. `/bind` validates task existence and non-terminal state, detects conflicts (409 if already bound to different task), supports idempotent re-bind to same task. `/unbind` removes current thread/group binding with confirmation. Extracts binding key from Google Chat `threadName`, WhatsApp `groupJid`, or Signal `groupId`
- **Binding API + visibility** (S06): REST endpoints `GET /api/tasks/:id/bindings` (list), `POST /api/tasks/:id/bindings` (create, 201), `DELETE /api/tasks/:id/bindings/:channelType/:threadId` (remove, composite key). Duplicate POST returns 409 Conflict. Task detail page shows bound channels with type and thread ID. Canvas task board cards show binding count badge (`hasBindings` + `bindingLabel`)

#### Phase D — Advisor Agent
- **Advisor subscriber + context window** (S07): `AdvisorSubscriber` in `dartclaw_server` subscribes to `TaskStatusChangedEvent`, `TaskEventCreatedEvent`, `AgentStateChangedEvent`, and `AdvisorMentionEvent` on the EventBus. `SlidingContextWindow` bounded buffer (configurable `max_window_turns`, default 10) with estimated token tracking. Events normalized to compact `ContextEntry` summaries. `AdvisorMentionEvent` added to sealed `DartclawEvent` hierarchy — fired by `ChannelTaskBridge` when `@advisor` detected via `_looksLikeAdvisorMention()`. Prior advisor reflections bounded at `max_prior_reflections` (default 3)
- **Advisor trigger policies** (S08): `TriggerEvaluator` with configurable trigger conditions: `turn_depth` (consecutive turns exceed threshold), `token_velocity` (consumption rate exceeds threshold within window), `periodic` (timer-based), `task_review` (task enters review status), `explicit` (`@advisor` mention). `CircuitBreaker` prevents firing more than once per 5 primary turns. Explicit `@advisor` triggers bypass circuit breaker. Multiple triggers active simultaneously
- **Advisor harness execution** (S09): On trigger, advisor acquires `TurnRunner` from `HarnessPool` via `tryAcquire()`. If unavailable, skip logged and deferred to next trigger. Prompt constructed from sliding context window, trigger reason, current task states, recent turn traces (via `TurnTraceService`), and prior reflections. Structured output parsed by `AdvisorOutputParser` (JSON-first with regex fallback). `AdvisorStatus` enum: `on_track`, `diverging`, `stuck`, `concerning`. Runner released in `finally` block
- **Advisor output routing + identity** (S10): `AdvisorOutputRouter` routes to three destinations: (a) canvas via `CanvasService.push()` with `renderAdvisorInsightCard()` (muted accent, italic heading, compact layout), (b) channels — explicit `@advisor` replies to originating channel thread; periodic/event triggers broadcast to all bound channels via `ThreadBindingStore.lookupByTask()` with fallback to task origin channel, (c) `AdvisorInsightEvent` on EventBus. Google Chat uses `ChatCardBuilder.advisorInsight()` Cards v2 template with distinct header. Thread-exact delivery via `sendMessageToThreadName` for Google Chat

#### Phase E — Configuration + Documentation
- **Config sections + crowd coding template** (S11): `AdvisorConfig` as built-in config section in `DartclawConfig.load()` with `'advisor'` in `_knownKeys`. Fields: `enabled` (bool, default false), `model`, `effort`, `triggers` (list), `periodic_interval_minutes` (default 10), `max_window_turns` (default 10), `max_prior_reflections` (default 3). 10 `FieldMeta` entries for `advisor.*`, `governance.crowd_coding.*`, `governance.queue_strategy`, `governance.rate_limits.per_sender.*`. `ConfigSerializer` updated with advisor section. Invalid trigger names rejected with warnings. Crowd coding recipe (`08-crowd-coding.md`) updated with three deployment scenario templates including model routing, queue fairness, and advisor configuration
- **Documentation updates** (S12): Crowd coding recipe covers all four new capabilities with config examples and operational tips. Architecture docs updated: `system-architecture.md` (advisor subsystem, `/bind`/`/unbind` in routing precedence, `AdvisorSubscriber` component table entry, `AdvisorMentionEvent`/`AdvisorInsightEvent` in event hierarchy), `data-model.md` (advisor events, `AdvisorConfig` schema). "Current through" markers bumped to 0.14.3. Feature comparison matrix updated with 0.14.3 row

### Fixed

- **Google Chat typing indicator via Pub/Sub path** (S13): When Pub/Sub space events are enabled, the Pub/Sub path now sends the typing indicator placeholder before dispatching the message — previously only the webhook path did this, so the dedup-winning Pub/Sub path silently skipped it
- **Google Chat session display name** (S14): `GroupSessionInitializer` now resolves human-readable space display names via `GoogleChatRestClient.getSpace()` instead of showing raw `spaces/123...` IDs. Graceful fallback to raw ID on API error. `spaceDisplayName` propagated through message metadata from both webhook and Pub/Sub paths
- **Binding API race condition** (H-01): `taskRoutes()` and `TasksPage` now use the singleton `ThreadBindingStore` instead of creating ephemeral per-request/per-render instances from disk
- **Advisor turn bounded** (H-04): Advisor passes `maxTurns: 1` to `reserveTurn()`, enforced at the harness level via Claude Code `initializeFields.maxTurns`. `int? maxTurns` parameter added to `AgentHarness.turn()`, `TurnContext`, and `TurnRunner.reserveTurn()`
- **`/bind` prefix matching** (H-03): `/bind` now resolves task IDs by prefix (consistent with `/accept` and `/reject`), with clear feedback for ambiguous or missing matches
- **TriggerEvaluator double-initialization** (H-02): Refactored to parse triggers and interval as plain fields in `AdvisorSubscriber` constructor, creating a single `TriggerEvaluator` via `late final`
- **`/bind`/`/unbind` in reserved commands** (M-02): Both commands now registered in `isReservedCommand()` — correctly bypass pause handling
- **`SessionScopeConfig.hashCode`** (M-04): Channel keys sorted before hashing to eliminate insertion-order dependence
- **`_extractField()` regex** (M-05): Field name now escaped with `RegExp.escape()` in `AdvisorOutputParser`
- **Config model/effort validation** (M-06): Unrecognized model and effort values produce parse-time warnings across `advisor`, `sessions`, and `governance.crowd_coding` config sections
- **Analyzer warnings** (L-01): Removed unnecessary `!` operator in `advisor_subscriber.dart` and duplicate `dart:io` import in `tasks_page.dart`
- **AdvisorSubscriber EventBus consistency** (L-03): Single `EventBus` instance used consistently for both output routing and event subscriptions

### Changed

- **Version display**: Updated from 0.14.2 to 0.14.3
- **Thread binding store**: `lookupByTask()` signature changed from `ThreadBinding?` to `List<ThreadBinding>` — all callers updated
- **Debounce key**: `MessageQueue` debounce changed from per-session to per-sender-per-session — sender boundaries preserved in queue even with `max_queued: 0` (default)

---

## [0.14.2] — 2026-03-25

Shareable Canvas for Crowd Coding — agent-controlled visual workspace rendered on viewer devices via SSE, accessible via zero-auth share links. Purpose-built for workshop projection and participant phone access.

### Added

#### Phase A — Core Plumbing
- **CanvasService + state model** (S1): In-memory per-session canvas state (`CanvasState`, `CanvasShareToken`, `CanvasPermission`) with SSE broadcast to all connected viewers. Share token lifecycle (create with 24-byte `Random.secure()`, validate, revoke, lazy expiry cleanup). Configurable max SSE connections per session and max HTML size (512KB default)
- **Canvas route handlers + share-token middleware** (S2): shelf `Router` at `/canvas` with three routes: `GET /canvas/:token` (standalone page), `GET /canvas/:token/stream` (SSE), `POST /canvas/:token/action` (interaction injection). `canvasShareMiddleware` validates tokens and returns 404 on all failures (no information leakage). Canvas routes bypass `authMiddleware` via `publicPrefixes`. Per-token action rate limiter (10 req/min)
- **Canvas MCP tool** (S3): `CanvasTool` implementing `McpTool` with five actions: `render` (push HTML), `clear`, `share` (create share link), `present`/`hide` (visibility toggle). Config-driven base URL, default permission, and default TTL

#### Phase B — Standalone Canvas Page
- **Standalone canvas page** (S4): Self-contained Trellis template with all CSS and JS inline (zero external dependencies). Catppuccin dark/light palette via `prefers-color-scheme`. Responsive `clamp()`-based typography for projectors, tablets, and phones. SSE via `EventSource` with auto-reconnect. Nickname dialog for `interact` tokens, `canvas-view-only` CSS for `view` tokens. Connection status indicator (green/yellow/red). CSP nonce-based policy (`script-src 'nonce-{nonce}'`) blocking injected scripts from agent HTML
- **Admin canvas panel + share link management** (S5): Canvas admin page at `/canvas-admin` with sandboxed iframe embed (`sandbox="allow-scripts allow-forms"`). Share link management: generate, copy URL, revoke, list active tokens with labels. QR code generation via `package:qr` (inline SVG). Admin API routes behind `authMiddleware`: `POST/DELETE/GET /api/canvas/share`, `GET /api/sessions/:key/canvas/embed`. Embed endpoint with CSP headers

#### Phase C — Workshop Templates
- **Workshop task board template** (S6): Kanban-style task board fragment with four columns (Queued, Running, Review, Done). Cards show task title, creator name, and relative time-in-state. Running tasks display CSS-animated pulsing indicator. Responsive: 4-column (>1200px), 2-column (600–1200px), stacked (<600px)
- **Workshop stats bar template** (S7): Composable stats bar with token budget progress (color-coded: green <50%, yellow 50–80%, red >80%), task activity counters, top-5 contributor leaderboard (from `Task.createdBy`), and session elapsed clock. `WorkshopCanvasSubscriber` auto-pushes both fragments on `TaskStatusChangedEvent` with 500ms debounce

#### Phase D — Configuration + Documentation
- **Canvas config section** (S8): `CanvasConfig` with nested `CanvasShareConfig` and `CanvasWorkshopConfig` as built-in config section. `base_url` field on `ServerConfig`. 10 `FieldMeta` entries. `ConfigSerializer` additions. Canvas routes conditionally mounted based on `canvas.enabled`
- **Documentation** (S9): Updated crowd coding recipe with canvas config and usage guidance. Workshop facilitation guide updated with canvas setup checklist, H2 resolution, and canvas troubleshooting. System architecture and feature comparison updated. User-facing architecture overview updated

### Changed

- **CSP policy**: Canvas pages use nonce-based `script-src` instead of `unsafe-inline`, preventing XSS from agent-generated HTML rendered via `innerHTML`
- **Version display**: Updated from 0.14.1 to 0.14.2

---

## [0.14.1] — 2026-03-25

Crowd coding workshop polish — targeted UX improvements for multi-user collaborative sessions via Google Chat Spaces.

### Added

- **Informative rate limit rejection message**: Throttled users now see the configured limit, window duration, and an exemption hint (review commands and `/status` are never rate-limited) instead of a generic "too fast" message
- **Queue note in task creation responses**: When `max_concurrent` slots are full, both channel `task:` triggers and `/new` slash commands now append "Queued (will start when a slot opens)" to the response
- **Auto-accept on task completion** (`tasks.completion_action: accept`): New config option that automatically accepts completed tasks using the same merge/push/PR semantics as manual accept. Tasks still transition through `review` state — the system immediately invokes the existing accept path. Default behavior (`review`) is unchanged. Failures are logged and leave the task in `review` for manual intervention

### Fixed

- Recipe (`08-crowd-coding.md`): Corrected loop-detection YAML comment ("without human input" not "without a tool result"), listed all 6 slash commands with IDs in Step 3, updated Step 8 web UI link wording to reflect current state (canvas share link planned for 0.14.2)
- Facilitation guide (`crowd-coding-workshop.md`): H3 (rate limit message) and M1 (queue note) marked as resolved

---

## [0.14.0] — 2026-03-24

Multi-project support & task observability — DartClaw becomes a project-aware agent runtime. Register external git repos, create coding tasks against them, review diffs, and accept results as pushed branches or GitHub PRs. Agent execution becomes queryable and transparent with structured turn traces, event-sourced task timelines, and live progress indicators.

### Added

#### Phase 0 — Prep
- **Reusable Trellis component fragments** (S00): Extracted three high-repetition UI patterns into shared fragments in `components.html`/`components.dart`: metric card (used ~9 times), status badge (used ~15 times), and info card with rows (used ~4 times). All existing call sites migrated. Zero visual regression

#### Phase A — Multi-Project Support
- **Project model + service + configuration** (S01): `Project` domain model in `dartclaw_models` with id, name, remoteUrl, localPath, defaultBranch, credentialsRef, cloneStrategy (shallow/full/sparse), prStrategy (branch-only/github-pr), status enum (cloning/ready/error/stale). `ProjectService` with `Isolate`-based git operations (first DartClaw use of Isolates — clone/fetch/push never block the event loop). `projects:` config section with `ProjectConfig` parser — config-defined projects are read-only via API, runtime-created projects are fully mutable. Implicit `_local` project from `Directory.current.path` always available for backward compatibility. Startup registry reconciliation (config wins on ID collision). Stale clone recovery on restart
- **WorktreeManager integration + auto-fetch** (S02): `WorktreeManager.create(taskId, {project?})` creates worktrees from project clones instead of local repo. `ensureFresh()` fetches with configurable cooldown (default 5 min) and per-project lock to prevent concurrent fetches. `BehaviorFileService` wired to read project's `CLAUDE.md`/`AGENTS.md`. Network failure during fetch proceeds with local state
- **Push-to-remote + PR creation** (S03): `RemotePushService` pushes task branches to remote via `Isolate`. `PrCreator` invokes `gh pr create` as an outpost (subprocess with structured I/O). PR URL stored as `ArtifactKind.pr` task artifact. `branch-only` strategy pushes without PR. Graceful degradation: `gh` not found → push-only with warning artifact containing manual PR instructions. Auth failures leave task in `review` state with error artifact
- **Project API + container mount** (S04): REST API routes `GET/POST/PATCH/DELETE /api/projects`, `POST /api/projects/<id>/fetch`, `GET /api/projects/<id>/status`. Config-defined projects return 403 on PATCH/DELETE. Parent-directory container mount (`<dataDir>/projects/:ro`) with legacy `/project:ro` alias. `DELETE` cascades: cancel running tasks, fail queued/review tasks, remove worktrees, delete clone. `PATCH` blocks URL/branch changes while tasks are active (409 Conflict)
- **Project UI + task selector** (S05): Project management page with status badges (ready/cloning/error/stale), last fetch timestamps, per-project actions (fetch, edit, remove). "Add Project" form with remote URL, name, branch, credentials reference, PR config. Project selector dropdown in "New Task" dialog with clone status indicators. Real-time clone status updates via `ProjectStatusChangedEvent` → SSE `project_status` events. Task cards show project name

#### Phase B — Agent Observability
- **Enriched turn recording** (S06): `AgentObserver.recordTurn()` extended with `turnDuration` (wall-clock via `Stopwatch`), `cacheReadTokens`/`cacheWriteTokens`, and `List<ToolCallRecord>` (per-tool: name, success, durationMs, errorType). Provider normalization: Anthropic `cache_read/creation_input_tokens` → read/write, Codex `cached_input_tokens` → read only, others → 0/0. `ProtocolAdapter` handles normalization
- **Turn trace persistence + query API** (S07): Structured turn records persisted to SQLite `turns` table (id, session_id, task_id, runner_id, model, provider, started_at, ended_at, input/output/cache tokens, is_error, error_type, tool_calls JSON). Async fire-and-forget writes (zero added latency). `GET /api/traces` with filtering by taskId, sessionId, runnerId, model, provider, since/until with pagination. Summary aggregates (totalTokens, traceCount) in response. Token summary section on task detail page

#### Phase C — Task Timeline & Visual Progress
- **TaskEvent model + persistence** (S08): `TaskEvent` with sealed 6-kind enum (`statusChanged`, `toolCalled`, `artifactCreated`, `pushBack`, `tokenUpdate`, `error`). Append-only `task_events` SQLite table with synchronous writes (no event loss on crash). Events captured at all integration points: status transitions, tool calls, artifacts, push-backs, token updates, errors. `TaskEventCreatedEvent` fired on `EventBus`
- **Task timeline UI** (S09): Vertical timeline on task detail page with per-kind icons and formatting. Filter bar: All | Status | Tools | Artifacts | Errors. Auto-scroll to latest event when task is running
- **Live activity + progress + SSE** (S10): `task_progress` SSE event type with progress percentage, current activity (tool name + truncated args via `tool_call_summary.dart`), tokensUsed, tokenBudget. Live activity indicator updates within 1s of harness event. Token-budget-based progress bar ("1,847 / 10,000 tokens (18%)") when budget set, indeterminate pulsing animation when not. SSE throttled to max 1 per second per task
- **Multi-task dashboard enhancements** (S11): Per-task thin progress bar, token consumption text ("1.8K / 10K"), agent assignment badge, compact timeline preview (last 3 events inline with icons). Dashboard subscribes to SSE for all active tasks. Non-running tasks show final token count without progress bar

#### Phase D — Documentation
- **Architecture docs + ADR finalization** (S12): ADR-017 status set to "Accepted". `system-architecture.md` updated with Project subsystem, Isolate usage pattern, package DAG. `data-model.md` updated with Project entity, `turns` table, `task_events` table, `projects.json` lifecycle. `security-architecture.md` updated with credential integration, parent-directory mount, TaskFileGuard scoping. `control-protocol.md` updated with enriched turn data extraction. User guide architecture overview updated. All docs marked "Current through 0.14"

### Changed

- **Credential injection model**: Reference-based credentials (`credentials: github-ssh` in project config) resolved at clone/push time via environment injection (`GIT_SSH_COMMAND` for SSH, `GIT_ASKPASS` for HTTPS tokens). Never stored in config or logs
- **Accept semantics for project-backed tasks**: Project-backed tasks always push to remote — local merge is skipped (the remote branch/PR is the deliverable). `_local` project tasks retain existing local merge semantics
- **Version display**: Updated from 0.13.1 to 0.14.0
- **Stale worktree detection**: `detectStaleWorktrees()` called on startup to clean up orphaned worktrees from crashed tasks

### Fixed

- **Gap review remediation** (post-Codex review): `projectId` now persisted on task creation; diff generation resolves project clone path + `origin/<branch>` as base ref; all cleanup paths use project-aware resolution; tasks created while project is cloning stay queued (not immediately failed); runtime project edits trigger async re-clone on coordinate change; review-state tasks are failed (not preserved) during project deletion; queued tasks correctly failed (not cancelled) on project delete; `tool_call_summary.dart` extracts file path/command context for live activity display

---

## [0.13.1] — 2026-03-24

UX polish & progressive disclosure — the sidebar becomes a clear, self-explanatory navigation surface. Terminology matches user intent, running work is ambient, dismissing a chat is safe by default, and icons are consistent and accessible.

### Added

#### Phase A — Sidebar Polish
- **Rename "Sessions" to "Chats"** (S01): Sidebar section label and "New Session" button updated to "Chats" / "New Chat". Internal models (`SessionType.user`), API endpoints, and storage paths unchanged — display-only rename across sidebar template, Dart rendering, and all wireframes
- **Archive-first × button** (S02): × on active user chats now archives (no confirmation) instead of hard-deleting. New `POST /api/sessions/:id/archive` endpoint mirrors `/resume`. Smooth HTMX OOB swap moves item from Chats to Archived section without page reload. × on archived sessions shows confirmation dialog before permanent deletion. Archiving the currently-viewed chat redirects to `/`. Protected session types (channel, main, task) unaffected
- **Lucide icon system** (S07): Ported 32 Lucide SVG icons from design system to production web UI via CSS `mask-image` data URIs. Replaced ~40 Unicode HTML entity icons across 14 template files. All sidebar nav items render icons via `data-icon` attributes. All icon-only interactive elements have `aria-label` attributes. Icons inherit `currentColor` for theme compatibility and `em` units for scaling. Old icon CSS blocks removed

#### Phase B — Sidebar Intelligence
- **Conditional "Running" sidebar section** (S03): New sidebar section between Channels and Chats showing active/review tasks with live elapsed timers. Pulsing status dot (respects `prefers-reduced-motion`), truncated title, provider badge. Review items show warning indicator + "review" label. Section appears/disappears via SSE task events. Click navigates to `/tasks/<id>`. Guarded by `data-tasks-enabled` attribute to prevent SSE reconnect loops on taskless deployments
- **Feature-aware sidebar navigation** (S04): Sidebar adapts to configured features. System pages (Health, Memory, Scheduling, Tasks) shown/hidden based on service availability. Channels section hidden when no channel services configured. `dev.yaml` shows only Settings; production shows all. All flags default `true` for backward compatibility. Derived from existing service availability — no new config keys

#### Phase C — Onboarding
- **Streamlined getting-started guide** (S05): Restructured from ~182 to <100 lines. Quick Start within first 40 lines. Advanced topics (Docker, WhatsApp, AOT) relocated to dedicated guide pages
- **README quick-start-first** (S06): Quick Start code block before line 15. Features list trimmed from 15+ verbose bullets to 8 concise one-liners

### Changed

- **"Crowd coding" reclassified** (S08): Removed "crowd coding" as an architectural concept — the underlying capabilities (thread binding, runtime governance, emergency controls, sender attribution) are general-purpose primitives. Architecture docs updated: `crowd-coding.md` content folded into `system-architecture.md` and `data-model.md`, then deleted. Code comments and test names updated to reference specific capabilities. User-facing recipe (`08-crowd-coding.md`) unchanged. Ubiquitous language updated
- **Provider credential validation**: Supports OAuth/subscription login — `claude` binary using its own authentication no longer requires `ANTHROPIC_API_KEY`. Codex OAuth tokens detected via `~/.codex/auth.json`. 15s timeout on all binary probes
- **Startup banner**: Now shows provider and model in the ASCII banner and log line
- **Version display**: Updated from 0.9.0 to 0.13.1
- **Dependency bump**: Dart packages (`test`, `lints`, `uuid`, `collection`, `meta`, `fake_async`, `yaml_edit`, `crypto`, `http`, `async`) and frontend libraries (HTMX 2.0.8, DOMPurify 3.3.3, htmx-ext-sse 2.2.4) updated to latest stable
- **Claude brand color**: CLAUDE provider pill uses terracotta/orange (`--color-claude`) instead of terminal green
- **Lazy task pool spawning**: Task harnesses are no longer spawned eagerly at startup. The pool starts with only the primary harness and spawns task runners on-demand when the first task is created, up to `tasks.max_concurrent`. Eliminates ~2s per task runner from startup time when tasks are not in use

### Fixed

- **Sidebar left margin alignment**: Section labels, archive toggle, subsection labels, and dividers now use consistent `var(--sp-4)` left padding matching session items
- **Sidebar toggle aria-label**: `setSidebarOpen()` now updates the hamburger button's `aria-label` between "Open sidebar" and "Close sidebar" on toggle (was static)
- **Running tasks section on session pages**: `sidebarTemplate()` calls on the root and session page handlers now pass `tasksEnabled`, enabling the `data-tasks-enabled` attribute and sidebar SSE connection. Previously only the Tasks dashboard page rendered this attribute
- **S02 archive OOB swap**: Gap review fix — sidebar state preserved correctly after archive; redirect on archiving active session
- **S03 task SSE guard**: Gap review fix — `data-tasks-enabled` attribute prevents SSE reconnect loop on deployments without task service
- **S04 visibility test**: Gap review fix — sidebar visibility assertions aligned with actual server wiring
- **Graceful shutdown hangs** (TD-050): Server no longer hangs on SIGTERM/SIGINT. Root cause: spawned `claude`/`codex` subprocesses could ignore SIGTERM, leaving `process.exitCode` futures pending on the VM event loop. Fix: all three harness implementations (`ClaudeCodeHarness`, `CodexHarness`, `CodexExecHarness`) now escalate from SIGTERM to SIGKILL after a 2-second grace period, then confirm process exit. `ServeCommand` also calls `exit(0)` after clean shutdown as a belt-and-suspenders safeguard

---

## [0.13.0] — 2026-03-22

Multi-provider support — DartClaw can now run Claude Code and Codex (OpenAI) as interchangeable agent harnesses, with heterogeneous worker pools and per-task/per-session provider overrides.

### Added

#### Phase 1 — Foundation
- **Protocol adapter extraction + HarnessFactory** (S01): Extracted `ClaudeProtocolAdapter` from `ClaudeCodeHarness` behind a new `ProtocolAdapter` abstract interface; `HarnessFactory` instantiates harness implementations by provider identifier (`claude`, `codex`); `TurnRunner` and `HarnessPool` now use factory-based construction — zero direct `ClaudeCodeHarness` references remain
- **Canonical tool taxonomy** (S02): `CanonicalTool` enum (`shell`, `file_read`, `file_write`, `file_edit`, `web_fetch`, `mcp_call`) — provider-agnostic tool names; guards (`CommandGuard`, `FileGuard`, `NetworkGuard`) evaluate canonical names instead of raw provider strings; unmapped tools pass through with `provider:name` prefix and fail-closed on security-sensitive guards
- **Provider config + credential registry** (S03): `providers` config section with per-provider `executable`, `pool_size`, and extensible settings; `credentials` config section with environment variable resolution; `CredentialRegistry` extending existing `CredentialProxy` for multi-provider API key management; startup binary/credential validation (missing default provider = error, secondary = warning)

#### Phase 2 — Codex Core
- **CodexProtocol + CodexHarness MVP** (S04): `CodexProtocolAdapter` for `codex app-server`'s bidirectional JSON-RPC JSONL protocol — handles `initialize`/`initialized` handshake, `thread/start`, streaming notifications (`item/agentMessage/delta`, `turn/completed`, `turn/failed`); Codex events map to standard `BridgeEvent` types; `FakeCodexProcess` test double for unit testing without the real binary
- **CodexHarness turn lifecycle + environment** (S05): Thread-per-session management (first turn creates thread, subsequent turns reuse); message history replay from NDJSON store (Codex runs ephemeral — DartClaw owns continuity); system prompt injection via generated `config.toml` with `developer_instructions`; MCP server config pointing to DartClaw's `/mcp` endpoint; per-worker temp directory with `CODEX_HOME`
- **Guard chain integration + approval flow** (S06): Codex approval requests routed through DartClaw's `GuardChain` with canonical tool names — allow → tool executes, deny → tool blocked; Claude Code switched from `--permission-prompt-tool stdio` to `--dangerously-skip-permissions` (hooks still fire — no security regression, eliminates one IPC round-trip per tool call)

#### Phase 3 — Integration & Hardening
- **Crash recovery + capability declaration** (S07): Exponential backoff restart on process exit (matching `ClaudeCodeHarness` pattern); post-crash: new thread created, history replayed, session resumes; harness capability getters (`supportsCostReporting`, `supportsToolApproval`, `supportsStreaming`, `supportsCachedTokens`) for graceful degradation
- **Heterogeneous pool + provider overrides** (S08): Mixed Claude + Codex workers in `HarnessPool` based on per-provider `pool_size`; `tryAcquireForProvider()` routes to matching provider worker (rejects — never falls back to different provider); per-task provider override via `Task.provider` field; per-session provider override at creation time

#### Phase 4 — Polish & Completeness
- **Provider status API + settings page** (S09): `GET /api/providers` endpoint returning configured providers with binary version, credential status, pool size, and default flag; settings page "Providers" section with read-only status display and clear error states for missing binaries/credentials
- **Provider indicators + cost display** (S10): Provider badge in session sidebar, task list, and task detail page; provider-aware cost display — USD cost for Claude, token counts with "cost unavailable" tooltip for Codex; `cached_input_tokens` displayed when available
- **Exec-mode fallback + container support** (S11): Lightweight `CodexExecHarness` using `codex exec --json` for one-shot task execution — `--full-auto --ephemeral`, no approval chain; Dockerfile updated with both `claude` and `codex` binaries (multi-arch with `TARGETARCH` fallback); sandbox interaction matrix documented
- **Architecture docs + ADR finalization** (S12): ADR-016 status set to "Accepted"; ADR-007 addendum documenting Codex prompt injection approach; `system-architecture.md`, `control-protocol.md`, `security-architecture.md` updated for multi-provider; all marked "Current through 0.13"

### Changed

- **Guard evaluation**: All guards now operate on canonical tool names instead of raw provider-specific strings
- **Claude Code permission model**: Switched to `--dangerously-skip-permissions` — guard chain via hooks is the sole interception point (eliminates redundant `can_use_tool` handler)
- **`ProviderIdentity` normalization**: Centralized provider family mapping (`codex-exec` → `codex`) for consistent credential lookup, validation, and UI labeling across the codebase
- **Unmapped tool kind default**: `CodexProtocolAdapter.mapToolName()` maps unknown `file_change` kinds to `CanonicalTool.fileWrite` (fail-closed) instead of returning `null`; aligns exec-mode adapter with app-server adapter
- **`CredentialEntry.toString()`**: Redacts API key value to prevent accidental log exposure
- **Shared protocol utilities**: Extracted duplicated `_stringifyMessageContent` and `_mapValue` helpers into `codex_protocol_utils.dart`

---

## [0.12.0] — 2026-03-21

Crowd Coding — multi-user collaborative AI agent steering via messaging channels. A group of people in a Google Chat Space (or WhatsApp/Signal group) can collaboratively drive an AI agent to build an application.

### Added

#### Phase 0 — Codebase Hardening
- **DartclawServer builder refactor** (S01): Replaced two-phase construction (factory + `setRuntimeServices()`) with builder pattern; extracted route assembly into composable route groups; WhatsApp pairing routes extracted to dedicated file; `server.dart` reduced from 828 to ~400 LOC
- **Task event centralization + optimistic locking** (S02): `TaskStatusChangedEvent` fired from `TaskService.updateStatus()` only — removed duplicate firing from scattered callers; `version` column on tasks table with conflict detection on stale updates; harness spawned with `--setting-sources` constraints
- **ChannelTaskBridge extraction** (S03): Extracted task logic (trigger parsing, review dispatch, recipient resolution) from `ChannelManager` into dedicated `ChannelTaskBridge`; consolidated duplicate recipient resolution; `ChannelManager` reduced from 487 to ~200 LOC
- **ServiceWiring decomposition** (S04): Split `service_wiring.dart` (1,741 LOC) into domain-specific modules (`SecurityWiring`, `ChannelWiring`, `TaskWiring`, `SchedulingWiring`, `StorageWiring`) with thin coordinator; cleaned 73 `catch (_)` silent catches; removed `ignore_for_file: implementation_imports` from all files

#### Phase A — Sender Attribution & Identity
- **Sender attribution end-to-end** (S05): `Task.createdBy` field with sender identity extraction from channel messages; "Created by" display in task list and Google Chat Cards v2 notifications; sender prefix in task detail chat view

#### Phase B — Thread-Bound Task Sessions
- **ThreadBinding model + thread-aware routing** (S06): Channel-agnostic `ThreadBinding` model mapping `(channelType, threadId) → (taskId, sessionKey)`; bound-thread messages route to task sessions, unbound messages route to shared session; JSON persistence with atomic writes
- **Binding lifecycle + thread commands** (S07): Auto-unbind on terminal task states; idle timeout cleanup; thread commands (accept/reject/push back in bound threads without specifying task ID)

#### Phase C — Runtime Governance
- **Governance config + rate limiting** (S08): `GovernanceConfig` section; `SlidingWindowRateLimiter` — per-sender and global turn rate limiting (admin exempt); all governance features default disabled for backward compatibility
- **Token budget enforcement** (S09): Daily token budget via existing `UsageTracker`; warn mode at 80%, block mode at 100%; midnight reset; per-sender budget tracking
- **Loop detection** (S10): Three-mechanism `LoopDetector` — turn chain depth limit, token velocity tracking, tool fingerprinting (repeated tool call patterns); configurable thresholds, all default disabled

#### Phase D — Emergency Controls
- **Emergency stop** (S11): `/stop` slash command — aborts all in-flight turns, cancels running tasks, admin-only authorization
- **Pause/resume** (S12): `/pause` and `/resume` slash commands — queues messages in-memory during pause, structured per-sender concatenation drain on resume, partitioned by session

#### Phase F — Documentation
- **Crowd coding recipe** (S13): User-facing recipe at `docs/guide/recipes/08-crowd-coding.md` — end-to-end crowd coding setup guide

#### Phase G — Config Restructure
- **`features:` config namespace** (S14): Crowd coding and thread binding config moved under `features:` namespace; prepares for future plugin system (`plugins:` reserved for third-party)

### Changed

- **Architecture docs updated**: `system-architecture.md`, `security-architecture.md`, `data-model.md` updated for crowd coding; new `crowd-coding.md` architecture deep-dive; all marked "Current through 0.12"

---

## [0.11.0] — 2026-03-21

Google Chat Space full participation — DartClaw can now receive ALL messages in Google Chat Spaces without requiring @mention, using Google Workspace Events API + Cloud Pub/Sub.

### Added

#### Phase 1 — Foundation
- **Configuration model extension** (S01): `PubSubConfig` and `SpaceEventsConfig` nested config sections on `GoogleChatConfig`; `ConfigMeta` registration; cross-field validation (enabling space events requires Pub/Sub fields); all new sections default to disabled — fully backward compatible
- **Cloud Pub/Sub pull client** (S02): `PubSubClient` (401 LOC) — REST API v1 pull client with configurable poll interval, batch pull (up to 100 messages), immediate ack/nack, exponential backoff on transient errors (429, 5xx, max 32s), graceful shutdown (drain in-flight within 5s), health reporting (last pull timestamp, consecutive error count); zero new dependencies — direct REST via `GcpAuthService`

#### Phase 2 — Core Pipeline
- **Workspace Events subscription manager** (S03): `WorkspaceEventsManager` (591 LOC) — creates/renews/deletes Google Workspace Events API subscriptions; persists subscription metadata to JSON with atomic writes; proactive renewal at 75% of TTL (1-hour buffer on 4-hour default); startup reconciliation (renew active, recreate expired, prune orphaned); rate-limit aware
- **CloudEvent message adapter** (S04): `CloudEventAdapter` (300 LOC) — parses Pub/Sub CloudEvent payloads into `ChannelMessage` objects; handles `google.workspace.chat.message.v1.created` events; filters bot self-messages; batch processing support
- **Message deduplication** (S05): `MessageDeduplicator` (60 LOC) in `dartclaw_core` — bounded FIFO with configurable capacity (default 1000); first-seen-wins prevents double-processing when @mentioned messages arrive via both webhook and Pub/Sub paths

#### Phase 3 — Integration & Hardening
- **Space join/leave automation + API** (S06): `ADDED_TO_SPACE` webhook auto-subscribes via `WorkspaceEventsManager`; `REMOVED_FROM_SPACE` auto-unsubscribes; REST API endpoints (`GET/POST /api/google-chat/subscriptions`, `DELETE` with body-based `spaceId`) for manual operator control
- **Graceful degradation + health** (S07): `PubSubHealthReporter` tracks Pub/Sub status and surfaces it to health endpoint and dashboard; automatic fallback to webhook-only mode if Pub/Sub becomes unavailable; auto-recovery when connectivity restores

### Changed

- **Health dashboard**: Pub/Sub status section added — shows pull status, last pull timestamp, active subscription count, degradation warnings
- **`docs/guide/use-cases/`** renamed to **`docs/guide/recipes/`**

---

## [0.10.2] — 2026-03-19

Composed config model — decomposed `DartclawConfig` from a 72-field flat class into typed section classes.

### Changed

- **Typed config sections** (S01): 14 typed section classes extracted into `packages/dartclaw_core/lib/src/config/` — `ServerConfig`, `AgentConfig`, `AuthConfig`, `GatewayConfig`, `SessionConfig`, `ContextConfig`, `SecurityConfig`, `MemoryConfig`, `SearchConfig`, `TaskConfig`, `SchedulingConfig`, `WorkspaceConfig`, `LoggingConfig`, `UsageConfig`; each section owns its fields, defaults, and YAML parsing
- **Composed `DartclawConfig`** (S02): `DartclawConfig` rewritten from 72 flat fields to 16 composed section fields; section accessors replace top-level getters
- **Consumer migration** (S03): ~280 access sites across all packages migrated from flat-field access (`config.port`, `config.authToken`) to section-based access (`config.server.port`, `config.auth.token`)
- **Config pipeline updated** (S04): `ConfigSerializer` updated for section-based serialization and deserialization; `ConfigMeta`, `ConfigValidator`, and `ConfigWriter` unchanged (operate on flat YAML paths as before)

### Added

- **Extension config registration** (S05): `registerExtensionParser()` API for P7 custom config sections; typed `extension<T>()` lookup on `DartclawConfig`; enables third-party packages to register and retrieve their own config sections without modifying core

### Removed

- **Deprecated forwarding getters** (S06): all `@Deprecated` flat-field forwarding getters on `DartclawConfig` removed; `dart analyze` clean across all packages; 2,205 tests pass

---

## [0.10.1] — 2026-03-17

SDK architecture hardening before publish.

### Changed

- `dartclaw_core`: removed the config ↔ channel cycle by introducing a neutral `src/scoping/` module for channel config and session scope types, then removed the residual `channel ↔ scoping` edge by moving `ChannelType` to a neutral runtime module
- `dartclaw_core`: narrowed the public barrel while keeping it self-contained; types still referenced by exported public APIs remain available from `package:dartclaw_core/dartclaw_core.dart`, while deeper internals continue to require `package:dartclaw_core/src/...` imports
- `dartclaw_core`: `ChannelManager` now depends on `TaskCreator` / `TaskLister` callbacks instead of the concrete task service
- `dartclaw_server`: `TaskService` and `GoalService` now live here instead of `dartclaw_core`

### Fixed

- First-party packages and tests now compile and run cleanly against the narrowed core barrel
- Wrapper packages now re-export the core types their public APIs expose, so downstream consumers no longer need `dartclaw_core/src/...` imports for channel packages or `dartclaw_testing`
- Google Chat session-key test expectation updated to match the current default DM scope (`perChannelContact`)

## [0.10.0] — 2026-03-16

Design system overhaul, context management foundations, restricted session hardening.

### Added

#### Phase A — Design System Implementation
- **Token alignment** (S01): production `tokens.css` replaced with full design system spec — 7 surface levels (`pit` through `surface2`), hue-aware blue-violet tint shadows, snappy easing curve, `--transition-glow`, light theme semantic color alignment
- **Base, shell & animations** (S02): body diagonal gradient background, mobile sidebar `translateX` slide animation (replacing instant show/hide), sidebar scrim `<button>` with opacity transition, logo gradient text animation (accent→info→accent, 6s)
- **Container taxonomy** (S03): 4 well types (`.well`, `.well-deep`, `.well-content`, `.well-flush`) and 8 card types (default, sunken, elevated, active, panels, metric, tint, featured) with sub-elements, hover effects, and free nesting
- **Status indicators & gradient dividers** (S04): status dots with glow animations (live/error/warning/idle), restyled status badges (pill shape, semantic variants, muted), status pills with gradient fill, scanning bar (animated gradient sweep), gradient dividers (fade and center)
- **Accessibility & reduced motion** (S05): comprehensive `@media (prefers-reduced-motion: reduce)` disabling all animations and transitions; `.sr-only` utility; focus ring treatments on interactive elements; WCAG AA contrast verification for both themes
- **Template migration** (S06): all 18 Trellis templates migrated to new container taxonomy — health dashboard metrics → `.card-metric`, settings cards → card with `.card-header`, task items → `.card-tint-*`, chat code blocks → `.well-deep`; legacy class aliases removed

#### Phase B — Context Management Tier 1
- **Compact instructions** (S07): `# Compact instructions` section appended to system prompt via `BehaviorFileService.composeSystemPrompt()`; configurable via `context.compact_instructions` in `dartclaw.yaml`; included for long-running sessions (web, channel DM, long cron), skipped for short-lived sessions; "Context" section in settings UI
- **Exploration summaries** (S08): `ExplorationSummarizer` produces deterministic structural summaries for files exceeding `context.exploration_summary_threshold` (default 25K tokens); JSON/YAML → key-path + value-type schema; CSV/TSV → column names + row count + samples; source code → top-level declarations; silent fallback to `ResultTrimmer` head+tail for unrecognized types or parse failures
- **Context warning banner** (S09): `ContextMonitor.checkThreshold()` emits SSE `context_warning` event when context usage exceeds `context.warning_threshold` (default 80%); dismissable web UI banner; one-shot per session; per-session scope; `ConfigMeta` registered as live-mutable

#### Phase C — Restricted Session Hardening
- **Restricted session env flag** (S10): `CLAUDE_CODE_SIMPLE=1` passed to `claude` binary for restricted container sessions; disables MCP server loading, hook execution, and CLAUDE.md file loading; workspace and direct sessions unaffected

### Changed
- **Design system tokens**: all CSS custom properties now follow the full design system spec palette; shadows use `rgba(9,9,26,...)` hue-aware tints instead of plain black
- **Sidebar interaction model**: mobile sidebar uses CSS transform transitions instead of JS display toggle; scrim is a semantic `<button>` element driven by CSS combinators
- **Status dot class names**: old `.status-dot.active` / `.status-dot.error` patterns replaced with BEM-style `.status-dot--live` / `.status-dot--error` modifiers (no aliases)

### Fixed
- TD-038: context window usage warning now surfaces to user before session becomes unresponsive

## [0.9.1] — 2026-03-16

Scheduling unification, model/effort overrides, config consistency fixes.

### Added

- **Unified scheduling** (F01): `scheduling.jobs` now supports both `prompt` and `task` job types via a `type` field; `automation.scheduled_tasks` is a deprecated alias — existing configs are converted automatically with a deprecation warning
- **Per-job model/effort overrides** (F02): prompt jobs support `model` and `effort` fields; `ScheduleService` passes overrides to turn dispatch so individual cron jobs can run on a different model or effort level than the global default
- **Per-task overrides** (F03): `ScheduledTaskDefinition` accepts `model`, `effort`, and `token_budget` fields; `ScheduledTaskRunner` merges these into task creation config
- **`agent.effort` config field**: per-agent effort level (`low`, `medium`, `high`, `max`); propagated through `HarnessConfig` to the `--effort` flag on harness spawn
- **Bare model aliases**: `opus`, `sonnet`, `haiku`, and context-window suffixes (`opus[1m]`) accepted as `model` values throughout config; mapped to full model IDs at harness spawn
- **`ScheduledJobType` enum**: `ScheduledJob.fromConfig()` factory with unified `prompt`/`task` branching; task jobs carry a resolved `ScheduledTaskDefinition` instead of a prompt string
- **Missing `ConfigMeta` fields registered**: `search.qmd.host`, `search.qmd.port`, `search.default_depth`, `logging.file`, `logging.redact_patterns`

### Changed

- **Session scope default**: `SessionScopeConfig.defaults()` now uses `DmScope.perChannelContact` (was `DmScope.perContact`); each channel gets its own DM session per contact
- **Agent tool defaults**: non-search agents with no `tools` configured now default to an empty allowlist and log a startup warning; search agents (`id: search`) continue to default to `[WebSearch, WebFetch]`
- **`agent.effort` is now a constrained enum** in `ConfigMeta` (`low`, `medium`, `high`, `max`); the settings UI renders it as a select instead of a free-text input
- **Settings memory field corrected**: `memory_max_bytes` form field renamed to `memory.max_bytes` to match `ConfigMeta` and the config API JSON shape
- **Task CRUD API unified**: `/api/scheduling/tasks` POST/PUT/DELETE now read and write `scheduling.jobs` (type=task entries) instead of the deprecated `automation.scheduled_tasks` path; task jobs created or edited through the web UI are stored under the canonical schema
- **`delivery` not required for task jobs**: `POST /api/scheduling/jobs` with `type: task` no longer requires a `delivery` field
- **Job lookup by `id` or `name`**: job CRUD routes (`PUT`/`DELETE /api/scheduling/jobs/<id>`) resolve jobs by either the `id` or `name` field, consistent with how docs-authored configs use `id:`
- **Scope YAML normalization**: `DmScope` and `GroupScope` now accept both snake_case and kebab-case in YAML; values are normalized to kebab-case on parse

### Fixed

- **`configJson.budget` deprecation warning**: `TaskExecutor` logs a deprecation warning when a task config uses the old `budget` key; use `tokenBudget` instead
- `memory_max_bytes` removed from `ConfigMeta` (superseded by `memory.max_bytes` since 0.6); submitting the old key via config API now returns a validation error instead of silently writing an unknown field

### Removed

- `context_1m` model alias removed from config parser (use `opus[1m]` or `sonnet[1m]`)

## [0.9.0] — 2026-03-15

Package decomposition, SDK publish-readiness, channel-to-task integration, Google Chat enhancements, cookbook audit fixes.

### Added

#### Phase A — Package Decomposition
- **Channel config decoupling** (S01): `ChannelConfigProvider` interface; `TextChunker`, `MentionGating`, `ChannelConfig` moved to core channel base; channel-specific configs isolated from core config barrel
- **`dartclaw_security` package** (S02): guard framework extracted from core (~1,936 LOC); `Guard`, `GuardContext`, `GuardVerdict`, `GuardChain`, all concrete guards, `GuardAuditSubscriber`; callback-based decoupling for event firing (wired at server layer); zero dependency on core
- **`dartclaw_whatsapp` package** (S03): WhatsApp channel extracted from core (~1,078 LOC); `WhatsAppChannel`, `WhatsAppConfig`, `GowaManager`, response formatter, media extractor
- **`dartclaw_signal` package** (S04): Signal channel extracted from core (~1,000 LOC); `SignalChannel`, `SignalConfig`, `SignalCliManager`, `SignalSenderMap`, `SignalDmAccess`
- **`dartclaw_google_chat` package** (S05): Google Chat channel extracted from core (~595 LOC); `GoogleChatChannel`, `GoogleChatConfig`, `GcpAuthService`, `GoogleChatRestClient`; removes `googleapis_auth` from core's transitive dependency graph
- **Leaf services moved to server** (S06): `BehaviorFileService`, `HeartbeatScheduler`, `SelfImprovementService`, `WorkspaceService`, `WorkspaceGitSync`, `SessionMaintenanceService`, `UsageTracker` moved from core to server (~1,278 LOC); core reduced to ≤8,000 LOC
- **`dartclaw_config` package** (S09): config subsystem extracted from server (~1,335 LOC); `ConfigMeta`, `ConfigValidator`, `ConfigWriter`, `ScopeReconciler`; usable from both server and CLI
- **`dartclaw_testing` package** (S09): test doubles for SDK consumers; `FakeAgentHarness`, `InMemorySessionService`, `InMemoryTaskRepository`, `FakeChannel`, `FakeGuard`, `TestEventBus`, `FakeProcess`; example test in package
- **Extension APIs** (S09): `server.registerGuard()`, `server.registerChannel()`, `server.onEvent<T>()` — power user hooks callable before `server.start()`; documented in umbrella README

#### Phase B — SDK Publish-Readiness
- **Package metadata** (S10): MIT LICENSE added to all packages; `repository`, `homepage`, `issue_tracker`, `topics` in all pubspecs; lock-step versioning strategy; per-package CHANGELOGs with 0.9.0 entries
- **Package READMEs** (S11): focused READMEs for all packages (purpose, installation, minimal usage, API reference link); umbrella README rewritten as pub.dev landing page with architecture overview, quick start, package choice table; server + CLI framed as reference implementations
- **Doc comments + pana** (S12): `///` doc comments on all barrel-exported symbols (~50); expanded doc comments on data model classes; `example/` directories with recognized entrypoints; pana validation on zero-dependency packages

#### Phase C — SDK Documentation
- **SDK documentation** (S13): Quick Start guide (`docs/sdk/quick-start.md`) — minimal working agent in <30 lines; Package Choice Guide (`docs/sdk/packages.md`) — decision tree for consumer profiles; `single_turn_cli` runnable example project; repo README with dual-track navigation (User Guide + SDK Guide)

#### Phase D — Channel-to-Task Integration
- **Task trigger config** (S14): per-channel `task_trigger` section in `dartclaw.yaml` (enabled, prefix, default_type, auto_start); `ConfigMeta` registration; trigger parser (prefix-based, case-insensitive, start-of-message only); config API and settings UI toggles
- **Channel→task bridge + notifications** (S15): task trigger messages intercepted in `ChannelManager` before `MessageQueue`; task created via `TaskService.create()` with expanded `TaskOrigin` (recipientId, channelType, contactId); acknowledgment sent to originating channel; `TaskLifecycleEvent` notifications routed to originating channel only; best-effort delivery with logged failures
- **Review-from-channel** (S16): accept/reject tasks via channel message; exact-match parsing ("accept"/"reject" with optional task ID); shared `TaskReviewService` extracted from HTTP route handler; disambiguation prompt for multiple tasks in review; merge conflict → "Review in web UI" fallback

#### Phase E — Google Chat Enhancements
- **Google Chat Cards v2** (S17): `ChatCardBuilder` in `dartclaw_google_chat`; task notification cards (title, status badge, description, Accept/Reject buttons); `CARD_CLICKED` webhook handling; button payloads use flat `Map<String, String>` parameters; plain text fallback; card description truncation at ~2,000 chars
- **Google Chat slash commands** (S18): `/new [<type>:] <description>` → create task, `/reset` → archive session, `/status` → show active tasks/sessions; compatibility parser for both `MESSAGE+slashCommand` and `APP_COMMAND` event shapes; Cards v2 responses

#### Cookbook Audit Fixes
- **Announce delivery** (S19): `DeliveryService` class replaces standalone `deliverResult()` stub; cron job results broadcast to connected SSE web clients + active DM contacts on all registered channels; best-effort channel delivery with per-target error handling; deprecated `deliverResult()` retained for backward compat
- **Memory consolidator extraction** (S19): `MemoryConsolidator` extracted from `HeartbeatScheduler`; shared between heartbeat and `ScheduleService`; post-cron consolidation runs after successful jobs when MEMORY.md exceeds threshold
- **Memory config unification** (S19): `memory.max_bytes` as canonical nested key; backward-compatible fallback to top-level `memory_max_bytes` with deprecation warning; CLI override support for `memory.pruning.*` fields
- **Contact identifier documentation** (S19): WhatsApp JID format (`<phone>@s.whatsapp.net`, `<group-id>@g.us`) documented in `whatsapp.md`; Google Chat resource names (`users/<id>`, `spaces/<id>`) documented in `google-chat.md`

#### Recipes
- **Personal Assistant composite guide**: `docs/guide/recipes/00-personal-assistant.md` — turnkey setup combining morning briefing, knowledge inbox, daily journal, nightly reflection; "Day in the Life" 24-hour walkthrough; complete `dartclaw.yaml` + behavior files; step-by-step getting started
- **Troubleshooting guide**: `docs/guide/recipes/_troubleshooting.md` — common issues for scheduled jobs, memory, git sync, channels, cost optimization
- **Common patterns expanded**: heartbeat vs cron comparison table; monitoring guide (dashboards, logs, agent metrics); concrete SOUL.md example; session maintenance reference; channel-to-task integration guide

### Changed
- **Umbrella re-exports**: `dartclaw` umbrella now re-exports core + security + all channel packages; individual package imports work independently
- **Package DAG**: `dartclaw_core` reduced from ~12,500 LOC to ≤8,000 LOC; zero circular dependencies between extracted packages
- **Config guide updated**: unified Memory section with `memory.max_bytes` (preferred) and `memory_max_bytes` (deprecated alias); `memory.pruning.*` documented
- **Use-case guides updated to 0.9**: all 7 guides audited for config accuracy; `guards.content_guard` → `guards.content`; multi-channel references (WhatsApp/Signal/Google Chat); session scoping and maintenance config; task system and task triggers; announce delivery status noted
- **Example configs updated**: `personal-assistant.yaml` expanded with sessions, maintenance, content guard, input sanitizer, multi-channel comments, task triggers; `production.yaml` model references simplified

### Fixed
- **`announce` delivery stub**: `delivery: announce` was a no-op since 0.2 — now routes results to SSE clients and channel DM contacts
- **Memory consolidation gap**: consolidation only ran during heartbeat; now also runs after successful cron jobs via shared `MemoryConsolidator`
- **`memory_max_bytes` schema inconsistency**: related memory settings split across top-level and nested config; unified under `memory:` section with backward compat
- **Use-case guide `content_guard` references**: guides 04 and 05 used renamed config key `content_guard` instead of `content`
- **Internal session keys exposed in guides**: removed `agent:main:cron:<jobId>:<ISO8601>` format from user-facing workflow descriptions

### Documentation
- **Architecture docs**: `system-architecture.md` updated with new package DAG; `security-architecture.md` updated for `dartclaw_security` package extraction
- **SDK docs**: Quick Start, Package Choice Guide, runnable example project
- **Channel guides**: WhatsApp JID format, Google Chat resource name format, contact identifier sections
- **Configuration guide**: Memory section with `max_bytes` + `pruning`; deprecated `memory_max_bytes` documented
- **Use-case cookbook**: 2 new guides (composite PA, troubleshooting); 9 existing guides updated for 0.9 accuracy

---

## [0.8.0] — 2026-03-08

Task orchestration, parallel execution, coding tasks with git worktree isolation, task dashboard, Google Chat channel, agent observability. Post-implementation security hardening, performance, and documentation.

### Added
- **PageRegistry + SDK API** (S01): `DashboardPage` abstract class + `PageRegistry` with `register()`, `resolve()`, `navItems()`; all system pages migrated to registry-based registration; `server.registerDashboardPage()` SDK API for external page plugins
- **Per-profile containers** (S02): per-type container isolation (ADR-012); `workspace` profile (workspace:rw, project:ro) and `restricted` profile (no workspace mount); deterministic naming via `ContainerManager.generateName()`; `ServiceWiring` manages both profiles
- **Task domain model** (S03): `TaskStatus` enum (9 states: draft/queued/running/interrupted/review/accepted/rejected/cancelled/failed) with validated state machine transitions; `TaskType` enum (coding/research/writing/analysis/automation/custom); `Task` + `TaskArtifact` value classes
- **Task persistence** (S04): `TaskService` with SQLite persistence in `tasks.db` (WAL mode); CRUD + lifecycle operations; list queries filterable by status and type
- **Task REST API** (S05): full lifecycle API — `POST /api/tasks`, `GET /api/tasks`, `GET /api/tasks/<id>`, start/checkout/cancel/review actions, artifact endpoints; `TaskStatusChangedEvent` + `TaskReviewReadyEvent` fired via event bus
- **Task executor** (S06): `TaskExecutor` polls queued tasks (FIFO); `SessionKey.taskSession(taskId)` factory; `ArtifactCollector` gathers outputs by type; push-back injects comment and re-queues; task sessions hidden from main sidebar
- **HarnessPool + TurnRunner** (S07): `TurnRunner` extracted from `TurnManager`; `HarnessPool` manages multiple `AgentHarness` instances with acquire/release lifecycle; configurable `tasks.max_concurrent` (default: 3); per-session turn serialization
- **Container dispatch routing** (S08): task type → security profile routing (research → `restricted`, others → `workspace`); `ContainerStartedEvent` / `ContainerCrashedEvent`; container crash transitions in-flight tasks to `failed`
- **WorktreeManager** (S09): git worktree lifecycle — `create(taskId, baseRef)` creates `dartclaw/task-<id>` branch; `FileGuard` integration for worktree path isolation; `--directory` flag passed to `claude` binary; stale detection; configurable base ref via `tasks.worktree.base_ref`
- **Diff review + merge** (S10): diff artifact generated from worktree vs base branch; structured diff data (file list, additions, deletions, hunks); configurable merge strategy (`squash`/`merge` via `tasks.worktree.merge_strategy`); accept → squash-merge + cleanup; merge conflicts keep task in `review` with conflict details
- **Task dashboard** (S11): `/tasks` page registered via `PageRegistry`; filterable list by status/type; running task status cards with elapsed time; SSE live updates; review queue at `/tasks?status=review`; sidebar badge count for pending reviews
- **Task detail page** (S12): `/tasks/<id>` with embedded chat view, type-specific artifact panel (markdown, structured diff), Accept/Reject/Push Back review controls, "New Task" form with type-conditional fields
- **Scheduled tasks** (S13): new `task` job type alongside existing `prompt`; cron fires → auto-creates task with `autoStart: true`; completed tasks enter review queue; scheduling UI updated for task-type jobs
- **Google Chat config + auth** (S14): `GoogleChatConfig` model with YAML parsing; GCP service account OAuth2 (inline JSON / file path / env var); inbound JWT verification (app-url OIDC + project-number self-signed modes); 10min certificate cache
- **Google Chat channel** (S15): `GoogleChatChannel` implementing `Channel` interface; webhook handler at `POST /integrations/googlechat` with JWT verification; Chat REST API client (send, edit, download); per-space rate limiting (1 write/sec); typing indicator pattern for async turns; message chunking at ~4,000 chars
- **Google Chat session + access** (S16): session keying via `SessionScopeConfig.forChannel("googlechat")`; `DmAccessController` reuse (pairing/allowlist/open/disabled); mention gating; `ServiceWiring` registration
- **Google Chat config UI** (S17): `/settings/channels/google_chat` channel detail page; mode selectors, allowlist editor, mention toggle, connection status; config API extended for Google Chat fields
- **Goal model** (S18): `Goal` class (id, title, parentGoalId, mission); `goals` table in `tasks.db`; tasks reference goals via `goalId`; goal + parent goal context injection into task sessions (~200 tokens, 2 levels max); `POST/GET/DELETE /api/goals`
- **Agent observability** (S19): `AgentObserver` tracks per-harness metrics (tokens, turns, errors, current task); `GET /api/agents` + `GET /api/agents/<id>` endpoints; pool status (active/available/max); agent overview section on `/tasks` with SSE live updates
- **Google Chat user guide**: `docs/guide/google-chat.md` — setup, GCP auth, request verification modes, DM/group access, troubleshooting
- **Tasks user guide**: `docs/guide/tasks.md` — task types, lifecycle, review workflow, coding tasks, scheduling integration, configuration
- **Guard audit configurable retention**: `guard_audit.max_retention_days` config (default 30); date-partitioned audit files with scheduled retention cleanup
- **Task artifact disk reporting**: per-task `artifactDiskBytes` in task API responses; aggregate metric on health dashboard
- **Merge conflict UX**: task detail shows conflicting files list + resolution instructions when conflict artifact exists
- **Message tail-window loading**: `getMessagesTail()` + `getMessagesBefore()` APIs; initial chat/task-detail load returns last 200 messages; "Load earlier messages" button for backward pagination
- **Write queue backpressure**: `BoundedWriteQueue` caps pending writes at 1000; warning at 80% capacity; explicit overflow error (no silent drops)

### Security
- **Cookie `Secure` flag**: `auth.cookie_secure` config controls `Secure` attribute on session cookies; enables safe deployment behind TLS
- **Timing side-channel fix**: `constantTimeEquals` no longer leaks string length — pads shorter input to match longer before constant-time byte comparison
- **Auth rate limiting**: `AuthRateLimiter` returns 429 after 5 failed auth attempts per minute; `FailedAuthEvent` fired on all auth failure paths (gateway, login, webhook); successful auth resets counter
- **Auth trusted-proxy model**: `auth.trusted_proxies` config (list of IPs); `X-Forwarded-For` only accepted when connecting socket IP is in the trusted list; defaults to socket address for direct deployments
- **CommandGuard hardening**: broadened interpreter escape patterns to catch combined flag forms (`bash -lc`, `bash -xc`, `sh -lc`); third match path checks interpreter escapes and pipe targets against original command text before quote normalization; blocks `bash -lc 'rm -rf /'` and `cat script | 'bash -x'`

### Changed
- **MessageService cursor tracking**: in-memory `_lineCounts` map for O(1) cursor assignment on insert; one-time file scan on first access per session
- **KvService write-through cache**: reads served from in-memory cache after initial load; cache invalidated on write failure; atomic write pattern preserved
- **Shared `WriteOp`**: extracted from duplicated `_WriteOp` in `MessageService` and `KvService` to `write_op.dart` (internal, not public API)
- **DartclawServer fail-fast validation**: missing required runtime services for enabled features now throw `StateError` at handler build time

### Fixed
- **Task executor parallel dispatch**: pool-mode scheduling now dispatches across all compatible idle runners instead of waiting for one task to finish before starting the next
- **Task cancel propagation**: cancelling a running task now forwards cancellation to the active turn before returning the UI to the task list
- **Squash-merge conflict cleanup**: coding-task review no longer uses `git merge --abort` after `git merge --squash`; squash conflicts now restore state with a squash-safe reset path
- **Login fallback deep links**: browser auth redirects now preserve the requested route via `/login?next=...`, and successful manual sign-in returns to that route
- **Settings Google Chat status**: the settings page now receives live config context and can show configured Google Chat instances even when the channel is not connected
- **Task SSE bootstrap**: the client only opens `/api/tasks/events` when the shell actually renders task UI or the task badge
- **Task detail live refresh**: `/tasks/<id>` now transitions from draft to queued/running state without requiring a manual reload; task SSE refreshes target the active detail page and queued/running detail views use a scoped refresh fallback while a session is being attached
- **Queued task UX**: task detail pages show an explicit queued-state shell and more accurate no-session copy while waiting for a runner
- **Token deep-link bootstrap**: `?token=<valid>` sign-in now works on any GET route, not just `/`, and redirects back to the original path without the token while preserving other query params
- **WhatsApp sidecar adoption**: the server now adopts an already healthy external GOWA service instead of spawning into an occupied port and falling into a reconnect loop

### Tests
- Added regression coverage for parallel task dispatch, squash-vs-merge conflict cleanup, login `next` handling, settings Google Chat configured state, and the repaired dashboard route test harness
- Added task detail template coverage for queued-state rendering and made template tests workspace-root-safe
- Added auth middleware coverage for deep-link token bootstrap and query-param preservation
- Added `GowaManager` coverage for adopting an already healthy external service without spawning
- Added `auth_utils` unit tests for `constantTimeEquals`, `readBounded`, and `requestRemoteKey` trust-boundary cases (direct, trusted proxy, spoofed header)
- Added `AuthRateLimiter` unit tests (threshold, expiry, reset)
- Added `CommandGuard` regression tests for multi-word quoted wrapper bypasses and combined `-lc`/`-xc` flag forms

### Documentation
- Updated the UI smoke test to match the current System navigation and tabbed Settings editor
- Extended UI smoke coverage for `/tasks`, task detail progression, and `/memory`; corrected smoke-test numbering after the audit pass
- Closed the remaining 0.8 validation ledger gaps for empty-task and channel-enabled wireframes after live browser verification

---

## [0.7.0] — 2026-03-09

Session scoping, session maintenance, event bus infrastructure, channel DM access management.

### Added
- **Configurable session scoping** (S02): `SessionScopeConfig` model with `DmScope` (`shared`, `per-contact`, `per-channel-contact`) and `GroupScope` (`shared`, `per-member`) enums; parsed from `sessions:` block in `dartclaw.yaml`; per-channel overrides via `sessions.channels.<name>`; registered in `ConfigMeta` for API exposure
- **Session maintenance service** (S05): `SessionMaintenanceConfig` + `SessionMaintenanceService` — 4-stage pipeline (prune stale → count cap → cron retention → disk budget); `warn`/`enforce` mode; configurable thresholds for `prune_after_days`, `max_sessions`, `max_disk_mb`, `cron_retention_hours`; scheduled via internal cron job (default daily 3 AM)
- **CLI cleanup command** (S06): `dartclaw sessions cleanup` with `--dry-run` and `--enforce` flags; structured summary output (sessions archived, deleted, disk reclaimed)
- **Session scope settings UI** (S07): "Sessions" section on `/settings` with DM/group scope selectors and per-channel overrides; session scope section on channel detail pages (`/settings/channels/<type>`); restart-required banner for scope changes
- **Sidebar archive separation** (S08): collapsible "Archived" subsection with count badge; DM/Group channel subsections; `localStorage` persistence for collapse state
- **Auto-create group sessions** (S09): `GroupSessionInitializer` pre-creates sessions for allowlisted groups on startup and config changes via `EventBus`
- **EventBus** (S10): typed event bus using `StreamController.broadcast()`; sealed `DartclawEvent` hierarchy — `GuardBlockEvent`, `ConfigChangedEvent`, `SessionCreatedEvent`, `SessionEndedEvent`, `SessionErrorEvent`; wired as singleton in `service_wiring.dart`
- **Event bus migrations** (S11): guard audit logging, config change propagation, and session lifecycle all migrated from direct coupling to event bus subscribers
- **Unified DM access controller**: shared `DmAccessController` in `dartclaw_core/channel/`; Signal gains `pairing` mode; `DmAccessMode` enum (`open`, `disabled`, `allowlist`, `pairing`) shared across both channels; Signal allowlist accepts phone numbers and ACI UUIDs
- **Channel access config API**: `GET/PATCH /api/config` includes channel DM/group access fields; dedicated allowlist CRUD (`GET/POST/DELETE /api/config/channels/<type>/dm-allowlist`); live allowlist changes without restart
- **Channel access config UI**: `/settings/channels/whatsapp` and `/settings/channels/signal` detail pages; DM mode selector, allowlist editor, group mode selector, mention gating toggle; closes wireframe deviation #8
- **Pairing flow**: `createPairing()` for unknown senders in `pairing` mode; approval UI with Approve/Reject buttons, expiry countdown, HTMX polling; pairing management API endpoints; notification badge on channel cards

### Changed
- **SessionKey factory refactor** (S01): new factories `dmShared()`, `dmPerContact()`, `dmPerChannelContact()`, `groupShared()`, `groupPerMember()`; old overloaded `channelPeerSession()` removed; `webSession()` scope renamed from `main` to `web`
- **Group session fix** (S03): group messages now route to shared per-group session (was per-user-in-group — P0 bug); `ChannelManager.deriveSessionKey()` uses `SessionScopeConfig` and new factories
- **Signal sender normalization** (S04): `UUID ↔ phone` mapping via `signal-sender-map.json` prevents duplicate sessions from sealed-sender identity shifts; UUID-only messages resolve to cached phone; graceful degradation on missing/corrupt map

---

## [0.6.0] — 2026-03-05

Config editing, guard audit UI, memory dashboard, MCP tool extensions, SDK prep.

### Added
- **YAML config writer** (S02): `ConfigWriter` — round-trip YAML edits via `yaml_edit`, preserves comments and formatting; automatic backup before write
- **Config validation** (S03): `ConfigMeta` field registry + `ConfigValidator`; typed field descriptors with constraints; validation errors surfaced in UI
- **Config read/write API** (S04): `GET /api/config` + `PATCH /api/config` for live config updates; job CRUD endpoints (`POST /api/scheduling/jobs`, `PUT /api/scheduling/jobs/<name>`, `DELETE /api/scheduling/jobs/<name>`)
- **Settings page form mode** (S05): data-driven editable forms for all config sections; live-mutable toggles; restart-required badge on fields that need a server restart
- **Scheduling job management UI** (S06): inline add/edit/delete jobs on the scheduling page; cron expression human-readable preview
- **Graceful restart** (S07): `RestartService` — drains active turns then exits; SSE broadcast notifies connected clients; persistent banner survives the restart; client overlay blocks interaction during drain
- **Guard audit storage** (S08): `GuardAuditSink` — persistent NDJSON file log of every guard decision; automatic rotation at 10 000 entries
- **Guard audit web UI** (S09): guard audit table on `/health-dashboard` — paginated table of audit entries; filter by guard type and verdict
- **Guard config detail viewer** (S10): per-guard configuration cards on `/settings`; `FileGuard` rule display
- **Memory status API** (S11): `MemoryStatusService` — memory file sizes, entry counts, last-prune timestamp; pruner run history stored in KV
- **Memory dashboard** (S12): `/memory` page with 5 sections (status, files, pruner history, archive stats, manual prune); 30-second HTMX polling; prune confirmation dialog
- **`web_fetch` MCP tool** (S13): `WebFetchTool` — fetches URLs and converts HTML to Markdown for agent consumption
- **Search MCP tools** (S14): `SearchProvider` interface; `BraveSearchTool` and `TavilySearchTool` implementations; provider selected via config
- **`registerTool()` SDK API** (S15): public API on `DartClaw` for registering external MCP tools without forking
- **Harness auto-config for MCP** (S16): registered MCP tools automatically wired into harness `--mcp-config` at spawn time; no manual config required

### Changed
- **Package split** (S17): new `packages/dartclaw_models/` extracted from `dartclaw_core` — `models.dart` + `session_key.dart`; consumers depend on `dartclaw_models` directly
- **API surface + doc comments** (S18): `///` doc comments on all exported symbols across `dartclaw_core`, `dartclaw_models`, `dartclaw_storage`, `dartclaw_server`; barrel exports tightened; pana score 145/160; all packages bumped to 0.6.0

---

## [0.5.0] — 2026-03-03

Security hardening, memory lifecycle, MCP foundation, package split, Signal/WhatsApp E2E verification.

### Added
- **Input sanitizer** (S01): `InputSanitizer` — regex-based prompt injection prevention on all inbound channel messages; 4 built-in pattern categories (instruction override, role-play, prompt leak, meta-injection); content length cap to bound backtracking
- **Outbound redaction** (S02): `MessageRedactor` strips secrets and PII from agent output across all 4 delivery paths (channel, SSE, tool output, logs)
- **Content classifier** (S03): `ContentClassifier` abstract interface; `ClaudeBinaryClassifier` (OAuth-compatible, default) and `AnthropicApiClassifier` implementations; config-driven via `content_guard.classifier`
- **Webhook hardening** (S05): shared-secret validation on incoming webhooks; payload size limit; `UsageTracker` records per-agent token usage to `usage.jsonl` with daily KV aggregates
- **Memory pruning** (S07): `MemoryPruner` — deduplication and age-based archiving of MEMORY.md entries to `MEMORY.archive.md`; FTS5-searchable archive; registered as built-in `ScheduledJob` (visible in scheduling UI, supports pause/resume)
- **Self-improvement files** (S06): `SelfImprovementService` — `errors.md` auto-populated on turn failures/guard blocks; `learnings.md` writable via `memory_save`; both loaded in behavior cascade
- **Signal `formatResponse`** (S12): implementation + DM/group access config
- **Signal voice verification** (S13): voice verification flow + route tests
- **WhatsApp E2E tests** (S14): end-to-end test suite for WhatsApp channel
- **Signal E2E tests** (S15): end-to-end test suite for Signal channel
- **MCP foundation** (S16): `McpTool` interface, MCP router with 1 MB body size limit, tool registration scaffolding
- **MCP tool migration** (S17): `SessionsSendTool`, `SessionsSpawnTool`, `MemorySaveTool`, `MemorySearchTool`, `MemoryReadTool` implementing `McpTool` interface
- **Search agent model config** (S04): configurable model for search agent via `dartclaw.yaml`
- **Live config tier 1** (S18): `RuntimeConfig` ephemeral state; runtime toggles for heartbeat and git sync via `/api/settings/*`; per-job pause/resume via `/api/scheduling/jobs/<name>/toggle`
- **Use-case cookbook** (S08+S09): `docs/guide/` expanded with WhatsApp, Signal, scheduling, and deployment recipes
- **Stateless auth**: HMAC-signed session cookies replace in-memory `SessionStore`; sessions survive server restarts; `token rotate` auto-invalidates
- **SPA fragment detection**: pairing pages (Signal, WhatsApp) return HTMX fragments for SPA navigation
- **HTMX history restore handler**: re-initializes markdown rendering and UI state after browser back/forward navigation

### Changed
- **Package split** (S11): new `packages/dartclaw_storage/` extracts sqlite3-backed services from `dartclaw_core` (`MemoryService`, `SearchDb`, FTS5/QMD backends, `MemoryPruner`); `dartclaw_core` is now sqlite3-free
- **API surface audit** (S10): barrel exports narrowed with `show` clauses; `///` doc comments added to all exported symbols
- **Channel dispatcher**: extracted shared `_dispatchTurn()` helper for ChannelManager and HeartbeatScheduler

---

## [0.4.0] — 2026-03-03

Template engine migration, SPA navigation, search agent wiring, Signal channel.

### Added
- SPA-style navigation via `hx-get` + `hx-target="#main-content"` + `hx-select-oob` for topbar/sidebar
- Two-path server rendering: full page for direct requests, fragment for HTMX requests (`HX-Request` detection)
- Streaming guard: disables nav links during SSE stream, re-enables on `htmx:sseClose`
- View Transitions API integration with CSS fade animations
- `HX-Location` redirect for session create/reset, `Vary: HX-Request` for caching correctness
- `htmx:afterSwap` re-init for `marked`/`hljs` content rendering
- Wired `SessionDelegate`, `ContentGuard`, `ToolPolicyGuard` into `serve_command.dart`
- Search agent session directory created at startup; graceful degradation when `ANTHROPIC_API_KEY` missing
- FTS5 `SearchBackend` wired into memory service handlers; memory consolidation in heartbeat
- Content-guard fail-closed when API key available
- `SignalConfig`, `SignalCliManager` (exponential backoff 1s→30s), `SignalChannel` implementing `Channel` interface
- `SignalDmAccessController` + `SignalMentionGating` for DM/group access control
- Webhook route (`/webhook/signal?secret=<token>`) with constant-time secret validation
- Pairing page (SMS/voice/linked device registration flows)
- Settings status card + conditional sidebar nav item
- Message deduplication, Docker-unavailable degradation
- `constantTimeEquals` extracted to `auth/auth_utils.dart`, shared across webhook/signal/token auth

### Changed
- Migrated all 13 templates from inline Dart string builders to `.html` files with Trellis engine (`tl:text` auto-escaping, `tl:utext` trusted HTML, `tl:fragment` for partial rendering)
- `TemplateLoader` pre-loads and validates all templates at startup (smoke-render with empty context)
- 42 render tests covering all templates and fragments
- Trellis upgraded to 0.2.1 (resolves `<tl:block>` fragment, null `tl:each`, `!` negation)
- Version fallback `'unknown'` instead of hardcoded `'0.2.0'`

---

## [0.3.0] — 2026-03-01

Consolidation milestone — template DX, tech debt resolution, system prompt correctness, GOWA v8 alignment. No new features or dependencies.

### Added
- `pageTopbarTemplate()` — single function replaces 4 pages' inline topbar markup
- `KvService.getByPrefix()` for key-range queries
- `Channel.formatResponse()` virtual method for per-channel response formatting
- `PromptStrategy` enum (`append`/`replace`) on `AgentHarness`
- `BehaviorFileService.composeStaticPrompt()` for spawn-time prompt composition

### Changed
- Extracted ~215 lines of inline `<style>` blocks from 6 templates to `components.css`
- Decomposed monolithic templates (`healthDashboard`, `settings`) into sub-functions
- Consolidated formatting helpers (`formatUptime`, `formatBytes`) into `helpers.dart`
- **Per-session concurrency** (TD-003): same-session requests now queue behind active turn instead of returning 409; `SessionLockManager` with `Completer`-based async wait
- **Crash recovery** (TD-004): turn state persisted to `kv.json`; orphaned turns detected and cleaned on restart; client receives recovery banner
- **SessionKey** (TD-008): moved to `dartclaw_core` with composite key format (`agent:<id>:<scope>:<identifiers>`); factory methods for web/peer/channel/cron sessions; lazy migration for existing UUID keys
- **System prompt** (ADR-007): switched to `--append-system-prompt` to preserve Claude Code's built-in prompt (tools, safety, git protocols); MEMORY.md access via MCP tools instead of prompt injection
- Full API realignment to GOWA v8.3.2 contract — CLI args (`rest` subcommand, `--webhook`, `--db-uri`), endpoint paths (`/app/status`, `/send/message`, `/app/login-with-code`), response envelope unwrapping
- Multipart media upload with type-specific routing (image/video/file)
- Webhook parsing for v8 nested envelope (`{event, device_id, payload}`) with `is_from_me` filtering
- Webhook shared secret (`?secret=<token>`) for lightweight endpoint protection
- Config defaults: binary `whatsapp` (was `gowa`), port `3000` (was `3080`)
- Startup cleanup: kill orphaned GOWA process on health check failure
- Guard integration tests (TD-017), search backend contract tests (TD-018)

---

## [0.2.0] — 2026-02-27

Initial actual release. Core agent runtime with security hardening.

### Added
- 2-layer architecture: Dart host → native `claude` binary via JSONL control protocol
- File-based storage (NDJSON sessions, JSON KV, FTS5 search index)
- Memory system (MEMORY.md, MCP tools, FTS5/QMD hybrid search)
- HTMX + SSE web UI with session management
- REST API, CLI (`serve`, `status`, `rebuild-index`, `deploy`)
- Behavior files (SOUL.md, USER.md, TOOLS.md, AGENTS.md)
- Guard plugin architecture (command, file, network guards)
- HTTP auth (token/cookie), security headers, CSP, CORS
- Per-session concurrency, structured logging, health endpoint
- Docker container isolation + credential proxy
- Cron scheduling with deterministic session keys
- WhatsApp channel (GowaManager sidecar, webhook receiver, DM/group access control, mention gating, pairing UI)
- Deployment tooling (launchd/systemd, firewall rules)
