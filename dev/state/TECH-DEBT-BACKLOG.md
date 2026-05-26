# Tech Debt Backlog

Open items only. Resolved or obsolete historical entries were removed during backlog cleanup; milestone docs, specs, and CHANGELOG entries are the historical record.

## TD-106 – Investigate deeper Codex restriction surface

**Severity**: Medium (security hardening; provider capability gap)
**Found**: 2026-05-14 21:22 CEST, complete-discover-project-split remediation FIS
**Affects**: Codex workflow task execution, MCP server scoping, profile config, `shell_environment_policy`

**Context**: Codex CLI currently has no native per-tool allowlist equivalent to Claude permission patterns. `allowedTools` is advisory for Codex, while read-only sandbox and approval policy carry the actual enforcement. A stronger restriction surface may exist through MCP server scoping, profile config, or shell environment policy, but that requires provider-specific investigation.

**Fix**: Research Codex-supported restriction levers, choose a minimal enforceable mapping for DartClaw workflow tool categories, and add contract tests for the selected behavior.

**Trigger**: Need to run non-read-only Codex workflow steps with a narrowed tool surface, or upstream Codex adds a stable per-tool allowlist/profile capability.

Last reviewed: 2026-05-18

---

## TD-103 – Refactor server-side `_workflow*` task-config reads behind a typed accessor

**Severity**: Low (architectural boundary; not blocking – fitness allowlist absorbs it)
**Found**: 2026-05-02 0.16.4 restructure release-prep (split off from TD-100)
**Affects**: `packages/dartclaw_server/lib/src/task/{workflow_one_shot_runner,task_config_view}.dart`

**Context**: The 2026-05-02 widening of `check_no_workflow_private_config.sh` accepted that `_workflowNeedsWorktree` and `_workflowMergeResolveEnv` are intentionally persisted in `task.configJson` and read by server-side code (`task_config_view.dart:52,54`, `workflow_one_shot_runner.dart:77`). That was the pragmatic call to clear CI; the cleaner shape is for those server reads to go through a typed accessor on `TaskConfigView` (or an equivalent typed view object) so the raw `_workflow*` literal stays scoped to the workflow package.

**Current state**: Allowlisted, not blocking. The boundary remains soft but the surface is enumerated and documented.

**Fix**: Add a typed view (e.g. `TaskConfigView.workflowNeedsWorktree`, `TaskConfigView.workflowMergeResolveEnv`) and migrate the two server call sites. Then drop those two entries from `ALLOWED_FILES` in the fitness script.

**Trigger**: 0.16.5 S34 (workflow task-config accessors/constants) – that story already enumerates `_workflowFollowUpPrompts`, `_workflowStructuredSchema`, `_workflowMergeResolveEnv`, `_dartclaw.internal.validationFailure`, and the token-metric keys for centralisation through a typed/constant surface. Adding `_workflowNeedsWorktree` to the same surface and migrating the two server reads is the natural extension.

**References**: Fitness function `dev/tools/fitness/check_no_workflow_private_config.sh`; allowlist comment header tracks the same follow-up.

Last reviewed: 2026-05-18

---

## TD-097 – Re-run live workflow e2e under the S80 runtime-artifacts path scheme

**Severity**: Medium (release-gate verification freshness)
**Found**: 2026-04-30 S80 mixed-review remediation
**Affects**: `packages/dartclaw_workflow/test/workflow/workflow_e2e_integration_test.dart`

**Context**: S80 moved runtime review reports to `<data_dir>/workflows/runs/<runId>/runtime-artifacts/reviews/`, but the live `plan-and-implement` e2e and explicit cross-harness suites were not re-run after that path move. Component and integration tests cover the path contract, and the live e2e assertions are currently path-agnostic, so this is a release-gate freshness gap rather than a known failing behavior.

**Current state**: Acceptable for completing S80 remediation; not acceptable as a final "still green" release-gate signal unless the live e2e is re-run or consciously waived for the release.

**Fix**: Before tagging the next 0.16.4 release candidate, run the live `plan-and-implement` e2e against the `workflows-dartclaw` profile and the explicit Codex/Claude cross-harness suites. If the live e2e remains path-agnostic, either strengthen it to assert the runtime-artifacts path or record why the broader e2e signal is sufficient.

**Trigger**: 0.16.4 tag preparation, release-gate sign-off, or any future change to workflow runtime artifact paths.

**References**: `dartclaw-private/docs/specs/0.16.4/s80-workflow-runtime-artifacts-dir-mixed-review-claude-2026-04-30-3.md` M1.

Last reviewed: 2026-05-18

---

## TD-096 – Workflow runtime-artifacts retention and garbage collection

**Severity**: Low (operational cleanup)
**Found**: 2026-04-30 S80 mixed-review remediation
**Affects**: `<data_dir>/workflows/runs/<runId>/runtime-artifacts/`

**Context**: S80 intentionally keeps per-run runtime artifacts for post-mortem inspection and does not purge them. That is useful during the experimental phase, but long-lived operators running many workflows can accumulate review reports and merge-resolve attempt JSON indefinitely.

**Current state**: Acceptable for S80 because retention policy was explicitly out of scope and runtime artifacts are useful for debugging.

**Fix**: Add an operator-visible retention policy for workflow runtime artifacts, either as a configurable age/count-based cleanup job or as documented manual cleanup guidance backed by a CLI command.

**Trigger**: operator reports of `<data_dir>/workflows/runs/` disk-usage growth, first 0.16.5+ multi-tenant operator, or a runtime-data retention policy pass.

**References**: `dartclaw-private/docs/specs/0.16.4/fis/s80-workflow-runtime-artifacts-dir.md` retention hand-off; `dartclaw-private/docs/specs/0.16.4/s80-workflow-runtime-artifacts-dir-mixed-review-claude-2026-04-30-3.md` L3.

Last reviewed: 2026-05-18

---

## TD-095 – Runtime-artifacts subdirectory ownership convention

**Severity**: Medium (design coupling)
**Found**: 2026-04-30 S80 mixed-review remediation
**Affects**: `packages/dartclaw_workflow/lib/src/workflow/workflow_executor_helpers.dart`

**Context**: `WorkflowExecutor` pre-creates `<runtime-artifacts>/reviews/` so the current built-in `dartclaw-review --output-dir "{{workflow.runtime_artifacts_dir}}/reviews"` steps satisfy AndThen's existing output-directory precondition. This works for S80, but it couples the engine to one consumer's subdirectory convention. A future user-authored workflow that uses `{{workflow.runtime_artifacts_dir}}/screenshots` with a tool that requires the directory to exist would need its own preflight convention or a broader engine policy.

**Current state**: Acceptable for S80 because the FIS explicitly requires the built-in review steps to use `/reviews`, and changing them to the root would be a re-spec rather than a remediation.

**Fix**: Decide the runtime-artifact subdirectory ownership contract before adding another consumer: either consumers must create their own subdirectories, or workflow YAMLs should pass the runtime-artifacts root directly and let artifact filenames disambiguate.

**Trigger**: adding a second runtime-artifacts consumer, introducing architecture/e2e/screenshot artifacts, or revising the S80 `/reviews` convention.

**References**: `dartclaw-private/docs/specs/0.16.4/s80-workflow-runtime-artifacts-dir-mixed-review-claude-2026-04-30.md` M1.

Last reviewed: 2026-05-18

---

## TD-093 – Runtime-artifacts claims lose tie-breaks to colliding worktree-relative files

**Severity**: Low (edge-case artifact resolution)
**Found**: 2026-04-30 S80 mixed-review remediation
**Affects**: `packages/dartclaw_workflow/lib/src/workflow/context_extractor.dart`

**Context**: `_fileSystemOutputRoots` checks the worktree before the runtime-artifacts root. For `review_findings` claims that are relative paths, a stale colliding worktree file such as `reviews/foo.md` can win over the actual runtime-artifacts file. The built-in happy path asks agents to emit absolute paths, so this is only exposed by stale or malformed relative claims.

**Current state**: Acceptable for S80; absolute runtime-artifacts claims and runtime-root-relative claims are covered, and no concrete operator failure exists.

**Fix**: For output keys that preserve runtime-artifacts roots, try the runtime-artifacts root before the worktree; alternatively document the tie-break rule if worktree-first remains intentional.

**Trigger**: operator report of a remediation step reading a stale worktree review report, or any context-extractor refactor that touches `_fileSystemOutputRoots`.

**References**: `dartclaw-private/docs/specs/0.16.4/s80-workflow-runtime-artifacts-dir-mixed-review-claude-2026-04-30.md` L2.

Last reviewed: 2026-05-18

---

## TD-092 – Revisit `ArtifactCommitResult.skippedPaths` after runtime-artifact cleanup

**Severity**: Low (API cleanup)
**Found**: 2026-04-30 S80 mixed-review remediation
**Affects**: `packages/dartclaw_workflow/lib/src/workflow/workflow_artifact_committer.dart`

**Context**: S80 removed the runtime-artifact advisory skip path, leaving `ArtifactCommitResult.skippedPaths` mostly useful only for general failure reporting. The FIS explicitly left the keep-vs-drop choice to implementer judgment.

**Current state**: Acceptable for S80; production failure paths still populate `skippedPaths`, and tests still inspect it.

**Fix**: On the next artifact-committer API cleanup, decide whether `skippedPaths` remains a generally useful failure-detail field. Drop it only if no production caller or test still relies on the value.

**Trigger**: workflow artifact committer refactor, resolver result-shape cleanup, or repeated confusion around skipped path semantics.

**References**: `dartclaw-private/docs/specs/0.16.4/s80-workflow-runtime-artifacts-dir-mixed-review-claude-2026-04-30.md` L3.

Last reviewed: 2026-05-18

---

## TD-089 – `WorkflowService` god-shaped constructor + nullable-but-required dependencies

Promoted: 0.17 planning candidate
Last reviewed: 2026-05-18

**0.16.5 disposition**: **Deferred to 0.17 stabilization (S23 triage decision).** Changing the 18-collaborator constructor requires updating all callers in `dartclaw_server` wiring and test harnesses – a cross-cutting refactor beyond housekeeping scope. The nullable-but-required `StateError` path is harmless in the current single-deployment model where all deps are always wired in production.

**Severity**: Medium (DX/maintainability – runtime `StateError` for what should be compile-time required deps)
**Found**: 2026-04-30 deeper code review of `dartclaw_workflow` (H25)
**Affects**: `workflow_service.dart:83-128`; `workflow_task_factory.dart:48-57`

**Context**: `WorkflowService` constructor takes 18 collaborators, ~10 of them nullable (`taskRepository?`, `agentExecutionRepository?`, `workflowStepExecutionRepository?`, `executionRepositoryTransactor?`, `projectService?`, …). The "optional" deps then throw runtime `StateError` deep in `workflow_task_factory.dart:48-57` ("Workflow task spawn requires AgentExecution + WorkflowStepExecution persistence …") – meaning they're required in practice, just smuggled in as `?`. Either make them required at the type level or extract a `WorkflowExecutionDependencies` value object so the contract is compile-time visible.

**Fix shape**: introduce `WorkflowExecutionDependencies` (or split into `WorkflowExecutionServices` + `WorkflowExecutionRepositories` + `WorkflowExecutionGitPort`) value objects; bind required vs optional explicitly; constructor signature collapses to ≤6 args; `StateError` smuggling sites become unreachable.

**Trigger**: 0.17 stabilization pass.

**References**: 2026-04-30 deeper code review consolidated report (H25). Sibling to 0.16.5 S16 (task_executor ctor reduction) but a different file – not in S16 scope.

---

## TD-087 – `WorkflowService.dispose()` / `cancel()` perform `O(allTasksEver)` task scans

**Severity**: Low (perf – slow shutdowns at scale)
**Found**: 2026-04-30 deeper code review of `dartclaw_workflow` (H29)
**Affects**: `workflow_service.dart:556-579, 434-446`

**Context**: `dispose()` iterates `_activeExecutors.keys` then calls `_taskService.list()` over every task ever and filters; `cancel()` follows the same pattern. For any nontrivial deployment this is `O(allTasksEver)` per shutdown / cancel. Compounds because `dispose()` then waits on every executor to finish *after* signalling cancellation – slow shutdowns under load.

**Fix shape**: introduce `taskRepository.listByWorkflowRunIds(Iterable<String>)` (or equivalent indexed query); replace the broad list-and-filter pattern. Alternative: maintain a per-run task-id set in memory.

**Trigger**: a deployment with >10k tasks experiences slow `dartclaw serve` shutdown or a per-run cancel taking visible wall time; or any storage-side index refresh.

**References**: 2026-04-30 deeper code review consolidated report (H29).

Last reviewed: 2026-05-18

---

## TD-083 – `WorkflowTemplateEngine` has no escape mode (shared between prompts, commit messages, shell)

**Severity**: Low (security defence-in-depth – no known exploit; current callers happen to be safe)
**Found**: 2026-04-30 deeper code review of `dartclaw_workflow` (M35)
**Affects**: `workflow_template_engine.dart`

**Context**: The same `resolve()` method is used to build prompts, commit messages (via `WorkflowArtifactCommitter`), and shell-bound contexts (via `BashStepRunner`). `shell_escape.dart` exists but the template engine doesn't apply it; correctness depends on every caller doing the right thing. No current exploit, but the defensive-coding gap is worth closing – especially before any future caller forgets.

**Fix shape**: add an explicit `escape:` mode parameter to `resolve()` (`shell | json | html | raw`) or per-substitution opt-in via `{{var|shell}}` filter syntax. Default to `raw` for backward compatibility; flip default to `shell` for shell-bound contexts inside `BashStepRunner`.

**Trigger**: any new template-engine caller; report of an unescaped substitution causing a real-world issue; or 0.17+ security hardening pass.

**References**: 2026-04-30 deeper code review consolidated report (M35).

Last reviewed: 2026-05-18

---

## TD-081 – `_resolveReapWorkingDirectory` orphan-task fallback uses `_defaultProjectDir`

**Severity**: Low (bounded operational risk – orphan reaping for true-orphan tasks)
**Found**: 2026-04-30 0.16.4 sub-plan inventory (originally documented inline in `phase-22-s37-s39-implementation-notes-2026-04-21.md` §"Open residual gaps")
**Affects**: orphan-turn detection / reaper paths around `WorktreeManager` / project-dir resolution

**Context**: `_resolveReapWorkingDirectory` falls back to `_defaultProjectDir` when no project binding is recoverable for an orphan task. The full fix encodes `projectId` into the worktree path scheme so the reaper can recover the correct project dir without a fallback. Explicitly out of scope per S37 boundary; documented inline rather than booked.

**Fix shape**: encode `projectId` into the worktree path scheme; teach the reaper to parse it; remove the `_defaultProjectDir` fallback.

**Trigger**: orphan-task reaping observed using the wrong project dir in production; or any worktree-path-scheme refactor.

Last reviewed: 2026-05-18

---

## TD-077 – Cross-workflow output-key naming convention (`review_findings` vs `verdict`)

**Severity**: Low (refactor / consistency)
**Found**: 2026-04-30 0.16.4 sub-plan inventory (`workflow-output-contract-and-presets-implementation-note.md` §"Out of Scope")
**Affects**: built-in workflow YAMLs (`plan-and-implement`, `spec-and-implement`); chained-workflow consumers

**Context**: Output keys vary across built-in workflows for what is conceptually the same datum: review steps emit `review_findings` in some places, `verdict` in others, and downstream gates branch on either. There is no documented convention; new workflows pick one inconsistently.

**Fix shape**: pick a canonical name per concept (e.g. `review_findings` for findings array, `verdict` for the boolean/enum gate value), document in the public workflow guide, sweep built-ins to align.

**Trigger**: a chained workflow breaks because the consumer expects one key and the producer emits another; UBIQUITOUS_LANGUAGE.md sweep; workflow author confusion.

Last reviewed: 2026-05-18

---

## TD-075 – Codex token-accounting follow-up (model-switch tax)

**Severity**: Low (accounting precision)
**Found**: 2026-04-30 0.16.4 sub-plan inventory (`final-gap-closure-ledger.md` Part 13 – TOKEN-EFFICIENCY F4 + F5)
**Affects**: Codex harness token accounting; cross-ref TD-066

**Context**: `continueSession` chains under Codex are not measured against the model-switch tax (Codex re-charges for state when the model changes mid-chain). The numbers are likely small but unmeasured.

**Fix shape**: Add token-tax measurement in the cross-harness consistency suite (private FIS `s43-token-tracking-cross-harness-consistency`). This fits alongside any TD-066 work on the Task model.

**Trigger**: TD-066 schema migration or a user reports unexplained token accounting drift on Codex.

**References**: `dartclaw-private/docs/specs/0.16.4/workflow-final-gap-remediation/final-gap-closure-ledger.md` Part 13.

Last reviewed: 2026-05-18

---

## TD-066 – Workflow token metrics live on `task.configJson` with `_workflow*` underscore-prefixed keys

Promoted: 0.17 planning candidate
Last reviewed: 2026-05-18

**Severity**: Low (architectural smell – accounting state mixed with declarative config)
**Found**: Workflow E2E test + runtime code review (2026-04-28; finding M11)
**Affects**: `packages/dartclaw_core/lib/src/task/task.dart` (configJson surface), `packages/dartclaw_workflow/lib/src/workflow/foreach_iteration_runner.dart` and `packages/dartclaw_server/lib/src/task/task_executor.dart` (writers), `packages/dartclaw_workflow/test/workflow/workflow_e2e_integration_test.dart` `_tokenMetric` helper (reader), preserved-artifact JSON schema downstream of S25.

**Context**: Per-step workflow token accounting (`_workflowInputTokensNew`, `_workflowCacheReadTokens`, `_workflowOutputTokens`) is stored on `Task.configJson` with underscore-prefixed keys to keep them out of the canonical config surface. Mixing accounting state with declarative config is a real smell – convention-by-prefix instead of type system, no compile-time enforcement that readers go through the right helper, and refactoring is hand-wavy because every consumer has to know the prefix dance.

**Fix shape**: introduce a dedicated `Task.tokenMetricsJson` (or a sibling KV record) carrying the typed metrics. Phased migration: dual-write to both surfaces for one release, switch readers, drop the underscore-prefixed keys. Touches the `Task` model + repository schema, every writer (`TaskExecutor`, `ForeachIterationRunner` token bookkeeping), every reader (the test helper, the artifact-payload assembly in S72's `WorkflowExecutionRecorder`, any future analytics surface), and a small migration to delete legacy fields after readers cut over.

**Why deferred**: invasive cross-cutting refactor; wrong-sized for a remediation slot in 0.16.4 (S73's scope is already broad and mixes runtime + skill-doc + YAML changes). Better as a focused FIS in a future milestone where the `Task` model is naturally being touched.

**Source review**: `docs/specs/0.16.4/workflow-e2e-test-and-runtime-code-review-claude-2026-04-28.md` (private repo) finding M11.

**Trigger**: when the `Task` model is being touched for an unrelated reason, or when a third writer/reader of the per-step metrics surface needs to be added (the third call site is the signal that the prefix convention has officially outgrown its space).

---

## TD-029 – Global template loader remains process-global

**0.16.5 disposition**: **Carry forward (S23 triage decision).** `TemplateLoaderService` already exists as a real class in `packages/dartclaw_server/lib/src/templates/loader.dart`; the seam (class-vs-singleton) is the load-bearing piece and that already shipped. Adding the `@Deprecated('use injected TemplateLoaderService')` annotation to the global `templateLoader` getter would emit `deprecated_member_use_from_same_package` at every consumer site, cascading under `dart analyze --fatal-infos` – out of scope for housekeeping. Defer the deprecation push to a natural caller-migration window.

**Severity**: Low (testability and coupling)
**Found**: 0.4 review (AS-6)
**Affects**: `packages/dartclaw_server/lib/src/templates/loader.dart`, template rendering call sites

**Context**: The old `late` initialization footgun has been reduced: the loader now uses a nullable backing field, throws a clearer `StateError`, and tests can call `resetTemplates()`. The `TemplateLoaderService` class shape exists; what remains is migrating render call sites away from the `templateLoader` global getter.

**Fix**: Add `@Deprecated('use injected TemplateLoaderService')` to the global getter and migrate `ServerBuilder` / page-render call sites to receive an injected instance. The cascading caller migration is the bulk of the work.

**Trigger**: Next time template loading or server boot wiring (`ServerBuilder`, `lib/src/web/pages/`) is materially refactored – the deprecation push then rides along with the natural caller-touching work instead of becoming its own cascade.

Last reviewed: 2026-05-18

---

## TD-051 – Task accept flow is coupled to review transitions

**Severity**: Medium (feature friction and lifecycle rigidity)
**Found**: 0.14.1 workshop polish plan review (2026-03-24)
**Affects**: `packages/dartclaw_server/lib/src/task/task_executor.dart`, `packages/dartclaw_server/lib/src/task/task_review_service.dart`, `packages/dartclaw_models/lib/src/task_status.dart`

**Context**: Task completion currently flows through `running -> review`, and the real accept-side effects live in `TaskReviewService`: local merge, project-backed push/PR creation, artifact persistence, and cleanup. This works well for manual review, but it makes "auto-accept on completion" awkward because acceptance behavior is not exposed as a reusable lifecycle operation. The state machine also does not permit `running -> accepted`, so any future simplification must either preserve the current review hop or refactor the lifecycle model deliberately.

**Current resolution for 0.14.1**: Keep the existing lifecycle and implement the simple path (`running -> review -> accepted` via immediate system accept) rather than expanding the state machine.

**Future fix**: Extract acceptance side effects into a shared accept service or method callable from both manual review and system-driven accept flows. Re-evaluate whether a direct `running -> accepted` transition is worth the broader lifecycle, UI, and SSE changes only when there is a stronger product reason than workshop polish.

**Trigger**: Any future work on auto-accept, review policy variants, approval automation, or task lifecycle simplification.

Last reviewed: 2026-05-18

---

## TD-062 – Stuck Codex turn blocks session with no user feedback

Promoted: 0.18 planning candidate
Last reviewed: 2026-05-18

**Severity**: High (availability – blocks an entire crowd-coding session)
**Found**: 0.14.3 crowd-coding setup feedback (2026-03-25)
**Affects**: `SessionLockManager`, `CodexHarness`
**Target**: 0.18

**Context**: When Codex app-server hangs on a tool-use turn (upstream bug `openai/codex#11816`), the `SessionLockManager` per-session lock is held until `worker_timeout` fires. During that time, all messages to the same session queue behind the lock with no feedback to the user. In crowd-coding with a shared session, this blocks the entire workshop.

**Workaround**: Use `approval: never` and `sandbox: danger-full-access` in provider config. Reduce `worker_timeout` to 120s for crowd-coding.

**Fix**:
- Log when a session lock is being waited on
- Add a per-session stuck-turn detector that cancels turns earlier than the global timeout
- Add a `/cancel` or equivalent admin escape hatch to force-release a stuck session

---

## TD-065 – Polymorphic `TaskExecutionStrategy` (workflow-vs-interactive branch remains imperative after S16)

**Severity**: Low (maintainability, testability)
**Found**: 2026-04-21 workflow↔task boundary review (pre-ADR-023 drafting)
**Affects**: `packages/dartclaw_server/lib/src/task/task_executor.dart`, `packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart`

**Context**: `TaskExecutor._executeCore` branches on `_isWorkflowOrchestrated(task)` to route workflow-orchestrated tasks through `_executeWorkflowOneShotTask()` (via `WorkflowCliRunner`) instead of the normal `reserveTurn()` → `HarnessPool` → `TurnRunner` path. After 0.16.5 S16 decomposes `task_executor.dart`, the branch becomes two methods on `_TaskTurnRunner` (`runWorkflowOneShot` / `runNormal`) – a structural improvement, but the `if (_isWorkflowOrchestrated(task))` dispatch still lives in `_executeCore` as an imperative statement, and the two execution strategies sit on the same concrete class rather than behind a polymorphic interface.

**Current state**: Acceptable. One branch with two clear destinations is not a maintenance burden today. ADR-023 names the branch as intentional; S28's fitness test guards the package boundary below it.

**Fix**: Introduce an abstract `TaskExecutionStrategy` interface with `WorkflowOneShotStrategy` and `InteractiveStrategy` implementations. `TaskExecutor._selectStrategy(task)` picks once at the start of `_executeCore`, and the hot path becomes `await strategy.execute(...)` with no conditional. Estimated ~80 LOC, low risk (pure delegation, no behaviour change), covered by existing task-execution tests.

**Trigger**: Any of the following – (a) a third execution mode lands (new harness pattern that is neither interactive nor one-shot, e.g. scheduled agent tasks with a fixed prompt set); (b) testing `_executeCore` requires mocking both paths separately and the dual-method shape makes fakes awkward; (c) per-strategy configuration (observability, budget, cancellation policy) diverges enough that method-level branching loses ergonomics.

**References**: ADR-023 (workflow↔task boundary) · 0.16.5 S16 (task_executor decomposition) · S-BOUND-3 proposal in 2026-04-21 conversation.

Last reviewed: 2026-05-18

---

## TD-070 – Workflow boundary residuals (open surface)

**Severity**: Medium (maintainability)
**Found**: 0.16.4 final baseline review remediation (2026-04-30 05:20 CEST); narrowed 2026-05-16 after the LOC/race/resume sub-items closed in S15
**Affects**: `packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart`, workflow-created `task.configJson` keys

**Context**: Two of the three original carry-overs are closed (executor LOC decomposition – S15; `_waitForTaskCompletion` race – S15; map/foreach resume cursor – S15). Two open residuals remain, both targeted by mapped 0.16.5 stories:

- `WorkflowCliRunner` still lives in `dartclaw_server` despite acting as workflow/task boundary infrastructure. The seam decision is owned by S31.
- Several inter-package workflow task-config keys remain stringly typed (`_workflowFollowUpPrompts`, `_dartclaw.internal.validationFailure`, etc.). Centralisation behind a typed/constant surface is owned by S34. Closely related to TD-103 (the server-side `_workflow*` task-config reads), which would land on the same typed accessor.

**Fix**: Complete S31 and S34. Drop this entry when both ship; if either slips past 0.16.5, narrow further to the specific remaining surface.

**Trigger**: any new workflow runner type; any change that adds another `_workflow*` / `_dartclaw.internal.*` task-config key.

**References**: `dartclaw-private/docs/specs/0.16.4/workflow-requirements-baseline.md` §"Open Requirement Mismatches In Latest Review Material" · `workflow-requirements-baseline-gap-review-claude-2026-04-29.md` LOW advisory-carry-over finding.

Last reviewed: 2026-05-18
