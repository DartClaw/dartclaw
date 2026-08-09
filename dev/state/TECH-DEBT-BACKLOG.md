# Tech Debt Backlog

Open items only. Resolved or obsolete historical entries were removed during backlog cleanup; milestone docs, specs, and CHANGELOG entries are the historical record.

## 0.23 release-close decision debt

| Ledger | Deferred cleanup | Reason |
|---|---|---|
| D02 | Resolve seven remaining app-owned CSS shadows | Seven app-owned shadows remain; deleting them needs a page-by-page ownership decision so live-only behavior is not lost. |
| D04 | Define an orphan/unstyled-class scanner contract | An orphan/unstyled-class scanner needs an exemption contract for JS hooks, state classes and third-party markup. |
| D15 | Stabilize knowledge total-page semantics | Stable total-page semantics need a product decision and service-query correction. |
| D16 | Define legal effort/provider metadata values | Legal effort/provider value sets require product decisions and `FieldMeta.allowedValues` changes. |
| D17 | Define an effective-default metadata contract | `FieldMeta` has no effective-default surface, so settings cannot truthfully display defaults without a metadata contract change. |
| D29 | Retire ignored task SSE icon fields | Removing `iconChar` and `compactEventIconChar` needs an API-compatibility ownership decision; all UI consumers already ignore them. |
| C01 | Repair the light foreground ladder | `.delivery-badge` is 3.62:1 and existing 10–12px badge/code pairings remain below AA; repairing them requires coordinated foreground-ladder re-spacing rather than isolated retunes. |
| C02 | Retone the fifth identicon gradient | `.identicon--5`'s second `--sky` stop measures 2.31:1 against its initials; the gradient needs a coordinated design retone. |
| C05 | Inject deterministic time into relative-date tests | The same-year test can go vacuous early each year; a deterministic fix needs an injected `now` contract across shared callers. |
| C08 | Reconcile the dialog-tab selector contract | Canon's descendant `.dialog .tabs` rule is gate-pinned while the intended direct-child contract needs a specification amendment. |
| C10 | Unify live-task timestamp formatting ownership | Live task polling still writes raw ISO values; changing it needs one owner for server/local formatting across the update path. |
| C11 | Define the restart-required dispatch contract | A listener exists but no producer dispatches `restart-required`; defining the trigger is a product/runtime contract decision. |
| RP01 | Bound audit-dashboard reads | The dashboard polls and fully scans every retained audit partition. A cap changes filter/pagination completeness, while caching or indexing adds state; define the supported event volume and whether the dashboard promises full retained-history queries before choosing the mechanism. |

**0.26 candidates (flagged 2026-08-07)**: the UI-canon rows above (C01, C02, C08, C10, C11) touch the same surfaces and canon that 0.26 Chat & Session Experience reworks — decide take-or-defer at 0.26 PRD time, alongside the decided items below.

### Decided 2026-08-07 (operator) – awaiting scheduling, raise at 0.26 planning

| Ledger | Decision |
|---|---|
| D13 | Link-style chips never carry a selected state. Switch the knowledge-hub layer filter from `a.chip` + unstyled `aria-current` to the canon tabs pattern (as the workflow-list status filter already does). Zero canon change; selection vocabulary belongs to tabs and toggle chips. |
| D14 | Add a muted/disabled status-dot variant to the canon status ladder; stop mapping disabled to idle. |
| C06 | Dedupe repeated-poll outage feedback to one persistent toast per failing poll source, cleared on recovery. Polling cadence unchanged. |
| C09 | Amend canon with a keyboard/ARIA disclosure primitive (native button/details-summary + `aria-expanded`), aligned with the tool-call disclosure card, and apply it to workflow-step disclosure. |

## TD-119 – Delegated MCP cancellation lacks caller-to-child causality

**Status**: Scheduled for 0.27 Phase A alongside TD-110's MCP dispatch seam
**Severity**: Medium (cancelled/timed-out callers can leave a child holding a worker and delegation slot)
**Found**: 2026-08-09, 0.24 delegation retrospective
**Affects**: inbound MCP dispatch context, `sessions_spawn`, `sessions_send`, delegated session ownership, turn cancellation

**Context**: Conversation delegation creates and awaits a child session without receiving the caller session/turn identity. Caller cancellation therefore cannot identify its child, and the MCP server's 120-second `Future.timeout` returns without cancelling the underlying delegated future. A global “cancel active child” shortcut is unsafe with concurrent callers.

**Decision**: Add typed caller-aware MCP call context, a parent-turn → delegated-turn registry, and exact-child cancellation on parent cancellation or MCP timeout. Prove child-first completion, parent-first cancellation, timeout, sibling isolation, and exactly-once runner/limit release. Design the shared context once with TD-110's dispatch-level guard/audit seam.

**Target**: 0.27 Phase A.

## TD-118 – Inline remediation loop halts on `maxIterations` before the verify-fix gate

**Status**: Open – deferred as the deterministic floor under ADR-044 (orchestration agent); needs loop-control integration decision
**Severity**: Medium (remediation can stop with unverified fixes and report loop exhaustion as completion)
**Found**: during 0.19 workflow hardening; recorded 2026-08-07 (memory graduation)
**Affects**: built-in review-and-remediate inline loop YAMLs, workflow loop control

**Context**: The inline review/remediate loop keys its exit on `gating_findings_count == 0` and halts on `maxIterations` without consuming AndThen's `Auto-Remediation`/convergence signal, so it can terminate before the deterministic verify-fix gate runs. Engine-side gap, not an AndThen bug.

## TD-117 – Working-directory / project-template resolution re-derived at ≥4 sites

**Status**: Open – needs an architecture decision (consolidate into one resolved-once value)
**Severity**: Low (individual sites are patched; duplication invites regressions)
**Found**: during 0.18/0.19 standalone fixes; recorded 2026-08-07 (memory graduation)
**Affects**: workspace-root, session-binding, and artifact-commit template-resolve sites; task-executor preflight

**Context**: Effective working directory / project-template resolution is derived independently at four-plus sites with subtly different fallback logic (unset `{{PROJECT}}` null-resolution was fixed site-by-site). Structural consolidation is needed to stop whack-a-mole fixes.

## TD-116 – One-shot workflow agents inherit the operator's global MCP set unfiltered

**Status**: Open – needs a requirements decision on a project-config MCP curation surface
**Severity**: Medium (security/attack-surface gap)
**Found**: during 0.19 one-shot review runs; recorded 2026-08-07 (memory graduation)
**Affects**: one-shot codex/claude spawn paths (workflow one-shot runner, provider CLIs)

**Context**: One-shot review/implement agents spawn with no MCP config of their own, so they inherit the operator's full `~/.codex` / `~/.claude` global MCP server set (context7, fetch, etc.). No DartClaw config surface exists to curate or trim MCP servers per project for these spawns.

**Candidate**: 0.27 Phase A (flagged 2026-08-07) — same guarded-MCP theme as TD-110's dispatch-level `GuardChain` seam; decide at 0.27 PRD re-scoping whether the per-project MCP curation surface rides that milestone.

## TD-115 – Residual SQLite on PostgreSQL deployments (`state.db` + webhook ledger)

**Status**: Scheduled 2026-08-07 (owner) – folded into 0.25 story S14 "Instance-local storage hygiene" (`dartclaw-private/docs/specs/0.25/s14-instance-local-storage-hygiene.md`, PRD FR13); close when S14 ships
**Severity**: Low (conceptual cleanliness; zero operational impact today)
**Found**: 2026-08-07, owner design discussion during 0.25 rider planning
**Affects**: `packages/dartclaw_storage/lib/src/storage/turn_state_store.dart`, `packages/dartclaw_storage/lib/src/storage/webhook_delivery_store.dart`, their open sites in `apps/dartclaw_cli/.../storage_wiring.dart` and `packages/dartclaw_server/lib/src/server.dart`

**Context**: A `database.backend: postgres` deployment still runs embedded SQLite for two instance-local stores – `state.db` (active-turn crash-recovery state, transient) and the webhook delivery ledger (per-instance dedup markers, TTL-purged). The owner flags this three-datastore shape (Postgres + SQLite + files) as an architectural smell. Both stores are touched only by the `serve` process (turn runner/cancellation; webhook routes) – no maintenance-command consumers – so the cross-process-locking argument for SQLite does not actually apply. Both are small, transient, and single-writer, making filesystem alternatives plausible: atomic write-temp-rename JSON for turn state (the `meta.json` pattern), file-per-event-id with `O_CREAT|O_EXCL` plus mtime-based purge for the ledger. That would make PostgreSQL deployments touch SQLite zero times at runtime (the library still ships in the one binary per ADR-045 OQ3 – one binary, no build flavors, a settled decision this item does not reopen; a separate-install SQLite would break the zero-ops default story).

**Resolution (owner, 2026-08-07)**: decided – conceptual cleanliness wins while pre-release. Folded into the existing 0.25 rider story S14 (keeping the plan at 14 stories) rather than a new story: filesystem stores with fault-injection parity against the current suites, Windows rename coverage, tightened sqlite3-import fitness check, and an ADR-045 #3/Q4 mechanism amendment (locality rationale unchanged).

## TD-110 – KG MCP write tools sit outside the guard pipeline with no audit trail; `kg_invalidate` id is unscoped

**Severity**: Medium (security / auditability – decision made, implementation pending)
**Found**: 2026-05-30 0.17 S03 knowledge-systems remediation (claude review S-1)
**Affects**: `packages/dartclaw_server/lib/src/mcp/kg_tools.dart`; `service_wiring_mcp_tools.dart`
**Target**: 0.27 (Knowledge Interop & Steward, Phase A – shifted 2026-08-07 from 0.25)

**Context**: `kg_add`/`kg_invalidate` are registered with no `contentGuard` and no audit logging, and MCP `tools/call` dispatch does not traverse `GuardChain`; `kg_invalidate` accepts an arbitrary integer id with no session/ownership check. The PRD claims KG writes are logged via existing audit infrastructure, which is not wired.

**Decision**: made (operator, 2026-07-29): dispatch-level enforcement – bring MCP `tools/call` dispatch under `GuardChain` at one seam (all write-capable tools, not just KG), wire KG writes/invalidations into the existing audit sink, add an ownership/scope check on `kg_invalidate` ids. ADR to be authored in the 0.27 milestone. Note: the affected wiring files may move under the 0.25 storage refactor – re-verify paths at 0.27 planning.

**Fix**: Implement the dispatch-level guard traversal + audit wiring + `kg_invalidate` ownership check per the decision above.

**Trigger**: scheduled – 0.27 Phase A (this is the enforcement point for the 0.27 steward workflow's human-acceptance invariant).

**References**: `dev/bundle/docs/specs/0.17/0.17-mixed-review-claude-2026-05-30-9.md` (S-1, MEDIUM).

Last reviewed: 2026-07-29

---

## TD-108 – Slash-command discovery is session-type aware, not permission/capability aware

**Severity**: Medium (decision needed – no differentiated command-permission model exists in 0.17)
**Found**: 2026-05-30 0.17 mixed review (codex F-009)
**Affects**: `packages/dartclaw_server/lib/src/api/session_routes.dart` (`_availableCommands`); `Session` model; S08 chat composer FIS

**Context**: `GET /api/sessions/<id>/commands` (`_availableCommands`) returns a constant workflow command list gated only on session type (empty for archive/task) and handler presence. The `Session` model has no permission field; command gating is enforced at execution time via guards, not at discovery time. The S08 FIS (`dev/bundle/docs/specs/0.17/fis/s08-chat-composer.md` lines 25, 220) requires command availability to "vary by permissions", which the current discovery path cannot satisfy.

**Decision required**: either build a session/user command-permission model that `_availableCommands` consults, or narrow the S08 FIS to drop the per-permission availability requirement. Cannot be resolved without that product/requirements decision.

**Trigger**: S08 chat composer implementation needs permission-varying command lists, or a differentiated command-permission model is introduced.

**References**: `dev/bundle/docs/specs/0.17/0.17-mixed-review-codex-2026-05-30-5.md` finding F-009.

Last reviewed: 2026-05-30

---

## TD-106 – Investigate deeper Codex restriction surface

**Severity**: Medium (security hardening; provider capability gap)
**Found**: 2026-05-14 21:22 CEST, complete-discover-project-split remediation FIS
**Affects**: Codex workflow task execution, MCP server scoping, profile config, `shell_environment_policy`

**Context**: Codex CLI currently has no native per-tool allowlist equivalent to Claude permission patterns. `allowedTools` is advisory for Codex, while read-only sandbox and approval policy carry the actual enforcement. A stronger restriction surface may exist through MCP server scoping, profile config, or shell environment policy, but that requires provider-specific investigation.

**Fix**: Research Codex-supported restriction levers, choose a minimal enforceable mapping for DartClaw workflow tool categories, and add contract tests plus a pinned-binary matrix showing which command, file-change, MCP, and web-search operations actually emit approvals.

**Trigger**: Need to run non-read-only Codex workflow steps with a narrowed tool surface, or upstream Codex adds a stable per-tool allowlist/profile capability.

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

**Context**: `_fileSystemOutputRoots` checks the worktree before the runtime-artifacts root. For `review_report_path` claims that are relative paths, a stale colliding worktree file such as `reviews/foo.md` can win over the actual runtime-artifacts file. The built-in happy path asks agents to emit absolute paths, so this is only exposed by stale or malformed relative claims.

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

## TD-081 – `_resolveReapWorkingDirectory` orphan-task fallback uses `_defaultProjectDir`

**Severity**: Low (bounded operational risk – orphan reaping for true-orphan tasks)
**Found**: 2026-04-30 0.16.4 sub-plan inventory (originally documented inline in `phase-22-s37-s39-implementation-notes-2026-04-21.md` §"Open residual gaps")
**Affects**: orphan-turn detection / reaper paths around `WorktreeManager` / project-dir resolution

**Context**: `_resolveReapWorkingDirectory` falls back to `_defaultProjectDir` when no project binding is recoverable for an orphan task. The full fix encodes `projectId` into the worktree path scheme so the reaper can recover the correct project dir without a fallback. Explicitly out of scope per S37 boundary; documented inline rather than booked.

**Fix shape**: encode `projectId` into the worktree path scheme; teach the reaper to parse it; remove the `_defaultProjectDir` fallback.

**Trigger**: orphan-task reaping observed using the wrong project dir in production; or any worktree-path-scheme refactor.

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

## TD-070 – `WorkflowCliRunner` lives in `dartclaw_server` despite being workflow/task boundary infrastructure

**Severity**: Medium (maintainability)
**Found**: 0.16.4 final baseline review remediation (2026-04-30 05:20 CEST); narrowed 2026-05-16 (LOC/race/resume closed in S15) and 2026-05-28 (S34-tracked typed-config surface closed; only the S31-tracked runner location remains)
**Affects**: `packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart`

**Context**: Of the original carry-overs, three closed in S15 (executor LOC decomposition, `_waitForTaskCompletion` race, map/foreach resume cursor) and the typed `_workflow*` task-config surface closed in S34 (`WorkflowTaskConfig` constants + `readMergeResolveEnv`, with the two server-side reads now routing through it). The remaining residual is structural: `WorkflowCliRunner` still lives in `dartclaw_server` despite acting as workflow/task boundary infrastructure. The seam decision is owned by S31.

**Decision (2026-06-27, [ADR-043](../adrs/043-cli-task-execution-provider-placement.md))**: **defer — keep status quo.** The unit is a self-contained cluster (`workflow_cli_runner` + `cli_provider` + `claude_cli_provider` + `codex_cli_provider` + `cli_process_supervisor`) importing only core/config/security, so relocation is dependency-feasible but unjustified at the current low severity: the cleanest home (a dedicated `dartclaw_task` package) trips the `arch_check` package-count ceiling (14→15), and moving into `dartclaw_workflow` conflates the control plane with CLI execution. No code change. This entry stays open, pinned to the ADR.

**Fix**: Deferred per ADR-043. Revisit on the trigger below; prefer the dedicated-package option and accept the ceiling bump when it fires.

**Trigger**: a second production consumer of the cluster; a dependency-cycle pressure that forces the seam; or a broader task-execution/harness-layer refactor that makes the relocation incidental rather than standalone churn.

**References**: [ADR-043](../adrs/043-cli-task-execution-provider-placement.md) (placement decision) · `dartclaw-private/docs/specs/0.16.4/workflow-requirements-baseline.md` §"Open Requirement Mismatches In Latest Review Material" · `workflow-requirements-baseline-gap-review-claude-2026-04-29.md` LOW advisory-carry-over finding.

Last reviewed: 2026-06-27
