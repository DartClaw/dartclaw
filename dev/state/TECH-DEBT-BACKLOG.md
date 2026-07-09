# Tech Debt Backlog

Open items only. Resolved or obsolete historical entries were removed during backlog cleanup; milestone docs, specs, and CHANGELOG entries are the historical record.

## TD-114 – Mixed finalizer + `outputMode: prompt` outputs on one agent step drop the opt-out output's main-prompt contract

**Status**: Closed 2026-07-05 — resolved by `dev/bundle/docs/specs/0.20/per-key-main-prompt-output-contract-filtering.md` (approach (a): per-key main-prompt output-contract filtering in `PromptAugmenter`; `spec_source` / `outputMode: prompt` opt-outs stay instructed, host-ownership boundary intact).

**Severity**: Low (latent; not hit by any built-in workflow – custom-workflow trap)
**Found**: 2026-07-04 S03 (execution-envelope finalization) quick-review, Critic finding 3
**Affects**: `packages/dartclaw_workflow/lib/src/workflow/prompt_augmenter.dart` (`finalizerHandlesOutputs` early-return), `execution_envelope_schema.dart` (`stepNeedsFinalizer` / `_isPromptOptOut`)

**Context**: `stepNeedsFinalizer` is true when *any* declared output is a model-derived finalizer output, so `finalizerHandlesOutputs` suppresses the entire main-prompt output contract. A `format: json` + `outputMode: prompt` output is excluded from the finalizer envelope (`_isPromptOptOut`) yet, on a step that also declares a finalizer-eligible output, its legacy main-prompt contract section is suppressed too – the model is never told how to emit it, and it resolves to `''`. This contradicts the ratified `outputmode-prompt-opt-out-fate` decision that prompt-opt-out outputs keep their legacy main-prompt contract. No shipped built-in mixes the two on one step.

**Related facet — envelope-excluded `*_source` keys (same root cause)**: `isModelDerivedFinalizerOutput` also excludes every `key.endsWith('_source')` output as a host-owned canonical default (the `*_source → synthesized` default in `context_output_defaults.dart`). But `spec_source` in the shipped `spec-and-implement.yaml` is a *model-authored* narrative decision (`existing` vs `synthesized`) that gates the `spec` step (`entryGate: spec_source == synthesized`). On the (finalizer-eligible) `detect-spec-input` step, `spec_source` is excluded from the envelope *and* its main-prompt contract is suppressed, so the only channel left is the legacy inline `<workflow-context>` fallback (`context_extractor` layer 2). If the model omits it there, the `*_source` canonical default forces `synthesized`, misclassifying a reused existing spec as needing synthesis. The two candidate fixes mirror this entry's: (a) per-key main-prompt-contract filtering keeps `spec_source`'s instruction, or reverse the blanket `*_source` finalizer exclusion so the envelope carries model-authored `*_source` values — the latter reverses the ratified `S03 Structural Criterion` that canonical defaults stay host-owned, so it is itself a decision. Surfaced by the codex mixed-review (F2), 2026-07-05; deferred here as the same root cause rather than fixed speculatively.

**Blocker**: design decision required – either (a) render the output-contract section only for envelope-excluded (opt-out / `*_source`) outputs while suppressing finalizer-handled ones (per-key section filtering in `PromptAugmenter`, which must learn per-output finalizer eligibility), or (b) reject/warn at validation when a single agent step mixes finalizer-eligible and `outputMode: prompt` outputs (and separately decide whether model-authored `*_source` keys belong in the envelope, which touches the ADR-041 host-ownership boundary).

**Fix**: Pick (a) or (b) above; add a `prompt_augmenter`/validator test pinning that a mixed step retains the prompt-opt-out output's contract (or is rejected), plus a `spec-and-implement` canary/test proving a reused existing spec conveys `spec_source: existing` and suppresses the `spec` step.

**Source**: S03 phase (b) Critic review (finding 3), 2026-07-04; codex mixed-review F2 (`spec_source`), 2026-07-05.

**Spec (approach (a) ratified)**: `dev/bundle/docs/specs/0.20/per-key-main-prompt-output-contract-filtering.md` (2026-07-05) — per-key main-prompt output-contract filtering; option (a) chosen over (b) as smaller/safer/more-complete. Landed 2026-07-05 (see Status above).

Last reviewed: 2026-07-05

---

## TD-113 – Replace S01 turn-monitor real-time sleeps with controlled timer tests

**Status**: Closed 2026-07-08 — resolved by the 0.20 test-suite hardening (CHANGELOG [0.20.0]: "injected test timers into turn wait/stall monitors to remove fixed sleeps from unit coverage"). The controlled-timer seam now exists — `SessionLockManager` takes an injectable `SessionLockTimerFactory` + `SessionLockNow` (`session_lock_manager.dart`), and `TurnRunner` threads `turnMonitorTimerFactory`/`turnMonitorNow` through. The wait/stuck monitor assertions in `turn_runner_test.dart` all drive fake time via the `_TurnMonitorFakeTime` (`FakeAsync`) helper + `monitoredRunner` + `elapseAsync`; a grep confirms zero real-time `Future.delayed` sleeps remain (only `Duration.zero` microtask yields). Backlog entry was stale.

**Severity**: Low (test determinism – new test harness required)
**Found**: 2026-06-08 S01 remediation-loop iter 4
**Affects**: `packages/dartclaw_server/test/turn_runner_test.dart`
**Target**: Future turn-monitor test harness cleanup

**Context**: The S01 review flagged multiple wait/stuck monitor assertions that still use short `Future.delayed` sleeps. This pass added targeted recovery-boundary coverage and preserved focused test stability, but fully replacing the existing runner-level sleeps needs a controlled timer seam or fake-async-compatible runner fixture because the current tests compose async storage, harness, lock, event, and timer behavior.

**Blocker**: new test harness required – eliminating these sleeps without weakening coverage requires an injectable timer/clock seam or a fake-async-compatible runner fixture for `TurnRunner` and `SessionLockManager` monitor timers.

**Fix**: Introduce controlled timer support for turn-monitor tests, then migrate the S01 wait/stuck assertions from real-time sleeps to fake time.

**Source report**: `dev/tools/dartclaw-workflows/.data/workflows/runs/5a5c8177-4f86-4d9c-8c49-9401e1a7ab9d/runtime-artifacts/reviews/s01-stuck-turn-status-and-early-cancel-mixed-review-codex-2026-06-08-4.md` finding 6.

Last reviewed: 2026-06-08

---

## TD-111 – Move turn wait-state semantics out of server string fields

**Status**: Closed 2026-07-08 — resolved by the `turn-wait-state-typed-event-contract` FIS (0.20). `enum TurnWaitState` and `enum TurnWaitReason` moved into `dartclaw_core` (`turn_wait_events.dart`), exported via the core barrel `show` clause; `TurnWaitStateChangedEvent.state`/`.waitReason` retyped to the enums so an unknown-state string is now a compile error. `turn_wait_status.dart` keeps a core re-export bridge (server-only types unchanged). The SSE/REST wire JSON stays byte-identical (`state` via `.name`, `wait_reason` via `.jsonName`), pinned by whole-payload SSE tests plus an exhaustive `values`-driven wire-name mapping test.

**Severity**: Medium (architecture / API contract – caller API change required)
**Found**: 2026-06-08 S01 remediation of aggregated architecture review
**Affects**: `packages/dartclaw_core/lib/src/events/turn_wait_events.dart`, `packages/dartclaw_server/lib/src/turn_wait_status.dart`, `packages/dartclaw_server/lib/src/api/task_sse_routes.dart`
**Target**: Future turn-status contract hardening

**Context**: The S01 architecture review flagged that `TurnWaitStateChangedEvent.state` and `.waitReason` are raw strings in `dartclaw_core`, while the typed wait-state/reason model lives server-side. This keeps the current package dependency direction intact, but it leaves core/server/SSE/UI consumers coupled by semantic string names rather than compiler-checked values.

**Blocker**: caller API change required – moving the wait-state and wait-reason semantic types into `dartclaw_core` changes the public event contract and requires coordinated updates across server event emission, SSE serialization, tests, and any downstream event consumers.

**Fix**: Move the semantic wait-state/reason value types or enums into `dartclaw_core`, keep JSON names at the server API/SSE boundary, and add exhaustive serializer/event tests.

**Trigger**: Any future expansion of wait reasons/states, ACP/delegation status integration, or a planned core event contract cleanup.

**References**: `dev/tools/dartclaw-workflows/.data/workflows/runs/5a5c8177-4f86-4d9c-8c49-9401e1a7ab9d/runtime-artifacts/reviews/aggregated-review-aggregate.md` ARCH-002.

Last reviewed: 2026-06-08

---

## TD-112 – Decide whether SessionLockManager should keep wait/stuck timer policy

**Status**: Closed 2026-07-08 — decision made: **keep status quo, do not extract now.** The two-threshold wait/stuck policy on `SessionLockManager.acquire()` is acceptable at current scope; extracting a `TurnWaitMonitor` today would be the speculative abstraction the project's KISS/YAGNI mandate forbids (the entry itself notes it "risks broadening a narrow remediation"). Extraction is warranted only if a trigger fires — new wait categories, per-provider wait policy, or further operator-facing monitor behavior — at which point this becomes a live design task again. Recorded as a made decision, not a re-deferral (owner-endorsed 2026-07-08).

**Severity**: Low (architecture / cohesion – decision needed)
**Found**: 2026-06-08 S01 remediation of aggregated architecture review
**Affects**: `packages/dartclaw_server/lib/src/concurrency/session_lock_manager.dart`, `packages/dartclaw_server/lib/src/turn_runner.dart`
**Target**: Future wait-monitor extraction decision

**Context**: The S01 architecture review flagged that `SessionLockManager.acquire()` now accepts wait/stuck thresholds and callbacks, so a low-level queue primitive owns some operator-facing monitor timing. This is acceptable for the current two-threshold S01 scope, but could become a cohesion problem if wait categories or policy grow.

**Blocker**: decision needed – extraction is explicitly conditional on wait policy growth; creating a `TurnWaitMonitor` now would be speculative and risks broadening a narrow remediation.

**Fix**: If wait/stuck policy expands, decide whether to extract a `TurnWaitMonitor` owned by `TurnRunner`/`TurnManager` and leave `SessionLockManager` focused on lock ownership plus queue metadata.

**Trigger**: New wait categories, per-provider wait policy, or further operator-facing monitor behavior lands.

**References**: `dev/tools/dartclaw-workflows/.data/workflows/runs/5a5c8177-4f86-4d9c-8c49-9401e1a7ab9d/runtime-artifacts/reviews/aggregated-review-aggregate.md` ARCH-003.

Last reviewed: 2026-06-08

---

## TD-109 – Inbox extraction turn runs tool-capable over untrusted source (least-privilege / excessive agency)

**Status**: Closed 2026-07-08 — resolved and now regression-guarded. The premise ("`TurnManager.startTurn` exposes no per-turn tool scoping; the only levers are process-level mutable state") is stale: `startTurn` now carries per-turn `allowedTools` + `readOnly` (`turn_manager.dart`), and `_runExtractionTurn` dispatches with `allowedTools: ['__knowledge_inbox_no_tools__']` + `readOnly: true`. `TurnRunner` applies that policy **session-scoped** via `TaskToolFilterGuard.setSessionToolFilter`/`setSessionReadOnly` before the harness runs (`turn_runner.dart` :476-481) and clears it in `finally` (:808-813), so restrictions never leak onto concurrent turns on other sessions. Enforcement + the anti-leak property are unit-tested in `task_tool_filter_guard_test.dart`; the caller contract in `knowledge_inbox_service_test.dart`; and the previously-untested TurnRunner apply/clear wiring is now pinned by `turn_runner_test.dart` ("per-turn toolless policy is applied session-scoped during the turn and cleared after (TD-109)", red-checked against a sabotaged apply).

**Severity**: High (security – OWASP LLM06 excessive agency over untrusted input)
**Found**: 2026-05-30 0.17 S03 knowledge-systems remediation (codex review)
**Affects**: `packages/dartclaw_server/lib/src/knowledge/knowledge_inbox_service.dart` (`_runExtractionTurn`); `packages/dartclaw_core/lib/src/turn/turn_manager.dart` (`startTurn`); `packages/dartclaw_security/lib/src/task_tool_filter_guard.dart`
**Target**: 0.18

**Context**: The bounded cron-session extraction turn over an untrusted dropped-in file is dispatched through `TurnManager.startTurn` with no per-turn tool allowlist or read-only constraint, so a prompt-injected source could induce tool use (OWASP LLM06 excessive agency). The parser-side forgery vector (markdown fence escape) was fixed in this pass by JSON-encoding the source; this entry covers the remaining tool-agency aspect only.

**Blocker**: Caller API change required – `TurnManager.startTurn` exposes no per-turn tool scoping; the only levers (`setTaskToolFilter`/`setTaskReadOnly`) are process-level mutable state on the shared `_primary` TurnRunner. Mutating that state from the cron inbox path would apply tool restrictions to concurrent user turns running on the same runner. A safe fix needs a per-turn tool-scope/structured-output dispatch capability that does not exist today.

**Fix**: Add a per-turn tool-scope (or toolless structured-output) dispatch path and route inbox extraction through it.

**Trigger**: Per-turn tool scoping is added to the turn-dispatch API, or untrusted-source ingestion is enabled in a multi-session deployment.

**References**: `dev/bundle/docs/specs/0.17/0.17-mixed-review-codex-2026-05-30-7.md` (HIGH "Untrusted inbox files run as unrestricted agent turns").

Last reviewed: 2026-05-31

---

## TD-110 – KG MCP write tools sit outside the guard pipeline with no audit trail; `kg_invalidate` id is unscoped

**Severity**: Medium (security / auditability – decision needed)
**Found**: 2026-05-30 0.17 S03 knowledge-systems remediation (claude review S-1)
**Affects**: `packages/dartclaw_server/lib/src/mcp/kg_tools.dart`; `service_wiring_mcp_tools.dart`
**Target**: 0.18

**Context**: `kg_add`/`kg_invalidate` are registered with no `contentGuard` and no audit logging, and MCP `tools/call` dispatch does not traverse `GuardChain`; `kg_invalidate` accepts an arbitrary integer id with no session/ownership check. The PRD claims KG writes are logged via existing audit infrastructure, which is not wired.

**Decision required**: whether MCP write tools should traverse `GuardChain` and which audit sink KG writes/invalidations should use is an architecture decision, not a local defect fix.

**Fix**: Decide guard scope for MCP write tools; at minimum wire audit logging for KG writes/invalidations and an ownership/scope check for `kg_invalidate`.

**Trigger**: MCP tool dispatch is brought under the guard pipeline, or a multi-operator deployment needs auditable KG mutations.

**References**: `dev/bundle/docs/specs/0.17/0.17-mixed-review-claude-2026-05-30-9.md` (S-1, MEDIUM).

Last reviewed: 2026-05-31

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

**Fix**: Research Codex-supported restriction levers, choose a minimal enforceable mapping for DartClaw workflow tool categories, and add contract tests for the selected behavior.

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
