# Tech Debt Backlog

Open items only. Resolved or obsolete historical entries were removed during backlog cleanup; milestone docs, specs, and CHANGELOG entries are the historical record.

## TD-069 — 0.16.4 advisory DECIDE cluster (deferred to 0.16.5+)

**Severity**: Mixed (one HIGH advisory, two MEDIUM advisories beyond what TD-066 already tracks; none gating 0.16.4)
**Found**: Workflow E2E test + runtime code review (2026-04-28); booked as DECIDE-not-FIX in `0.16.4-consolidated-review.md` (advisory row).
**Affects**: `packages/dartclaw_workflow/lib/src/workflow/` runtime + tests, `packages/dartclaw_workflow/lib/src/workflow/definitions/*.yaml` built-ins, `packages/dartclaw_workflow/test/workflow/workflow_e2e_integration_test.dart` fixture handling, `packages/dartclaw_workflow/lib/src/workflow/workflow_definition_validator.dart` `stepDefaults` glob handling.

**Context**: Six advisory findings the 0.16.4 review tagged "DECIDE not FIX" — each is a defensible policy or design choice with a clear alternative the team has not committed to. They were intentionally deferred to keep 0.16.4 focused on tagging the workflow stabilization line. Bundled here so they don't fall off the radar after tag.

1. **H1 — `paused`-as-success policy.** Workflow runs that end in `paused` (deliberate hold for operator input) currently pass the release gate's "succeeded" check. Decide whether `paused` should remain a success outcome, become a distinct neutral outcome, or fail the gate; align test fixtures and operator docs with the chosen policy.
2. **H2 — functional-bug-fix verification (diff-touches-expected-files vs fixture-grown regression tests).** The e2e test asserts the bug-fix story's diff touches expected files; it does not run a regression test that would have caught the bug pre-fix. Decide whether to grow the fixture with a paired regression test (stronger signal, more fixture maintenance) or keep the diff-touches assertion (cheaper, weaker).
3. **M6 — `_ensureKnownDefectsBacklogEntries` mutates cloned fixture.** The helper currently writes into the cloned fixture working tree to seed defects. Decide between deleting the mutation step (and fail-fasting if the fixture is missing the entries) versus keeping the mutation as a deliberate test-time setup (and documenting the cloned-tree write contract).
4. **M11 — token metrics on `task.configJson` with `_workflow*` prefix.** Already tracked as **TD-066**. Cross-referenced here for cluster completeness; do not duplicate the entry.
5. **M12 — `stepDefaults` validator literal-vs-glob workaround.** The validator currently treats `stepDefaults` keys as literals; the workaround for glob-style patterns lives in caller code. Decide between teaching the validator about globs (cleaner caller code) or formalizing the literal-only contract and removing the workaround (smaller validator surface).
6. **M13 — hardcoded `dart format/analyze/test` in built-in YAMLs.** Built-in workflow definitions hard-code `dart format`, `dart analyze`, `dart test` invocations. Decide whether to keep them hardcoded (Dart-only project assumption explicit) or route them through `project_index.verification.*` so non-Dart projects can configure equivalents.

**Why deferred**: each item is a policy or scope decision rather than a bug. Bundling them under a 0.16.5+ triage pass is cheaper than spec'ing six independent FIS for what may be a few line changes apiece once decided. M11 already has a dedicated entry (TD-066) because its fix shape is invasive enough to warrant standalone tracking.

**Source review**: `docs/specs/0.16.4/0.16.4-consolidated-review.md` (private repo) advisory DECIDE row; original findings in `docs/specs/0.16.4/workflow-e2e-test-and-runtime-code-review-claude-2026-04-28.md` (private repo) H1, H2, M6, M11, M12, M13.

**Trigger**: 0.16.5 milestone planning; an operator hits the `paused` gate question; a non-Dart workspace tries to use the built-in workflows; the `stepDefaults` glob workaround spreads to a third caller.

---

## TD-068 — `HarnessPool` is a single shared pool with mixed providers; should be per-provider pools

**Status**: **Promoted to 0.18** (Phase A foundation, story `F01` in `docs/specs/0.18/prd-draft.md` of the private repo). The 0.18 scope (universal `AcpHarness` adding N providers) fires the documented "third built-in provider being added" trigger. Entry retained for trace from the original review (L4) → backlog → milestone; remove on 0.18 completion when the refactor lands.

**Severity**: Low (architectural smell — head-of-line blocking + magic-number floor on shared capacity)
**Found**: Workflow E2E test + runtime code review (2026-04-28; finding L4) and follow-up
**Affects**: `packages/dartclaw_server/lib/src/harness_pool.dart` (single-pool design), `apps/dartclaw_cli/lib/src/commands/workflow/cli_workflow_wiring.dart` (`_standaloneTaskRunnerCapacity` minimum-3 floor, `ensureTaskRunnersForProviders`), call sites of `pool.tryAcquireForProvider`.

**Context**: `HarnessPool` carries a single `_busy` counter against `_maxConcurrentTasks` for all providers combined, and acquisition by provider is a linear scan over a mixed set. Standalone CLI wiring layers a `_standaloneTaskRunnerCapacity` floor on top — `max(configuredProviders.length, 3, config.tasks.maxConcurrent)` — to leave headroom for non-default providers (built-in workflows can target Claude when the default is Codex). The "3" is a guess based on "two harness families today + a slot of slack."

The configured `providers.<id>.pool_size` from dartclaw.yaml drives initial spawn for the default provider — that part is correct and already per-provider. The smell is on the runtime side: the pool itself doesn't enforce per-provider limits at acquisition time, so when `_busy` saturates with one provider's tasks, every other provider's tasks block even when the matching runner is idle. That's head-of-line blocking, not a deliberate fairness policy. The minimum-3 floor is a symptom — the cure is structural, not a bigger magic number.

**Fix shape**: replace the single shared pool with a `HarnessPoolGroup` carrying one `HarnessPool` per provider. Each pool's capacity is the configured `providers.<id>.pool_size`. Acquisition routes by `providerId` to the matching pool. The `_standaloneTaskRunnerCapacity` magic 3 disappears naturally — adding a third built-in provider becomes "configure `pool_size` for it" not "bump a magic number." Optional: keep a small "primary" runner outside the per-provider pools for interactive use (mirroring the current `_runners[0]` carve-out).

**Why deferred**: today's two-family setup (Codex, Claude) makes head-of-line blocking mostly invisible — both pools are typically sized comfortably above the working set. The magic 3 is correct for the current built-in workflow set. Refactor cost is moderate but the ROI only appears when (a) a third built-in provider lands, (b) a workload genuinely saturates one provider's capacity, or (c) per-provider quota / rate-limit / billing controls become a requirement.

**Source review**: `docs/specs/0.16.4/workflow-e2e-test-and-runtime-code-review-claude-2026-04-28.md` (private repo) finding L4.

**Trigger**: a third built-in provider being added; observed head-of-line blocking in production traces; a per-provider quota / rate-limit / billing requirement.

---

## TD-067 — Workflow E2E test re-clones GitHub fixture every run with no retry or cache

**Severity**: Low (test reliability — single point of failure on transient network)
**Found**: Workflow E2E test + runtime code review (2026-04-28; finding L1)
**Affects**: `packages/dartclaw_workflow/test/workflow/workflow_e2e_integration_test.dart` (`_cloneTodoAppFixtureRepo`).

**Context**: Every e2e test `setUp` does a fresh `git clone --depth 1 git@github.com:DartClaw/workflow-test-todo-app.git` into a temp dir. No retry, no fallback, no cached copy. A transient GitHub outage during that single second is enough to fail an entire 60–75 minute test budget. The clone itself is cheap (shallow), so the ROI on caching is not obvious until the failure mode actually surfaces — which it has not yet.

**Fix shape**: cache the clone in `_fixturesRoot()` keyed by `git ls-remote origin HEAD` SHA; reuse when SHA matches, re-clone when stale. Add a `DARTCLAW_E2E_FIXTURE_OFFLINE=true` escape hatch for offline runs. Keep S72 TI04's fixture fail-fast assertion (the M6 remediation) as the line of defense against stale-fixture content masking upstream `BUG-001..003` regressions.

**Why deferred**: failure mode is "test errors out cleanly with a network message," not "test passes incorrectly." The clone is seconds of a 60–75 minute run. Caching introduces its own bug class (stale fixture versions silently masking upstream BUG entry regressions, which the test now relies on). Wait for an actual CI failure traced to a transient blip before adding the layer.

**Source review**: `docs/specs/0.16.4/workflow-e2e-test-and-runtime-code-review-claude-2026-04-28.md` (private repo) finding L1.

**Trigger**: a CI failure traced to a transient GitHub outage, or when offline e2e runs become a real workflow.

---

## TD-066 — Workflow token metrics live on `task.configJson` with `_workflow*` underscore-prefixed keys

**Severity**: Low (architectural smell — accounting state mixed with declarative config)
**Found**: Workflow E2E test + runtime code review (2026-04-28; finding M11)
**Affects**: `packages/dartclaw_core/lib/src/task/task.dart` (configJson surface), `packages/dartclaw_workflow/lib/src/workflow/foreach_iteration_runner.dart` and `packages/dartclaw_server/lib/src/task/task_executor.dart` (writers), `packages/dartclaw_workflow/test/workflow/workflow_e2e_integration_test.dart` `_tokenMetric` helper (reader), preserved-artifact JSON schema downstream of S25.

**Context**: Per-step workflow token accounting (`_workflowInputTokensNew`, `_workflowCacheReadTokens`, `_workflowOutputTokens`) is stored on `Task.configJson` with underscore-prefixed keys to keep them out of the canonical config surface. Mixing accounting state with declarative config is a real smell — convention-by-prefix instead of type system, no compile-time enforcement that readers go through the right helper, and refactoring is hand-wavy because every consumer has to know the prefix dance.

**Fix shape**: introduce a dedicated `Task.tokenMetricsJson` (or a sibling KV record) carrying the typed metrics. Phased migration: dual-write to both surfaces for one release, switch readers, drop the underscore-prefixed keys. Touches the `Task` model + repository schema, every writer (`TaskExecutor`, `ForeachIterationRunner` token bookkeeping), every reader (the test helper, the artifact-payload assembly in S72's `WorkflowExecutionRecorder`, any future analytics surface), and a small migration to delete legacy fields after readers cut over.

**Why deferred**: invasive cross-cutting refactor; wrong-sized for a remediation slot in 0.16.4 (S73's scope is already broad and mixes runtime + skill-doc + YAML changes). Better as a focused FIS in a future milestone where the `Task` model is naturally being touched.

**Source review**: `docs/specs/0.16.4/workflow-e2e-test-and-runtime-code-review-claude-2026-04-28.md` (private repo) finding M11.

**Trigger**: when the `Task` model is being touched for an unrelated reason, or when a third writer/reader of the per-step metrics surface needs to be added (the third call site is the signal that the prefix convention has officially outgrown its space).

---

## TD-020 — Reply-to-bot gating unavailable with GOWA v8

**Severity**: Low (feature gap — partial workaround exists)
**Found**: GOWA v8 API alignment review (2026-03-01)
**Affects**: `packages/dartclaw_whatsapp/lib/src/mention_gating.dart`, `whatsapp_channel.dart`

**Context**: Pre-v8, GOWA webhook payloads included `quoted_message_sender` (the JID of the person whose message was quoted/replied to). `MentionGating` used this to detect "reply to bot's message" as a group trigger. GOWA v8 changed to `replied_to_id` (a message ID), removing sender JID information.

**Current state**: The `quotedMessageSender` check was removed from `MentionGating` since it was dead code (v8 never populates it). Group messages now require explicit mention via `mentionPatterns` regex (for example `@DartClaw`) or native `mentionedJids` (also empty in v8).

**Workaround**: Users can configure `mentionPatterns` with the bot's display name. This covers the most common group interaction pattern.

**Future fix**: Track outbound message IDs (from GOWA send response) in a bounded in-memory set. On inbound webhook with `replied_to_id`, check if that ID is in the set and treat it as "reply to bot". Requires:
- GOWA send response to include message ID in `results`
- A bounded LRU set in `WhatsAppChannel` or `MentionGating`

**Trigger**: When users report friction with group interactions requiring reply-based triggering, or when GOWA upstream re-adds sender JID to webhook payloads.

---

## TD-029 — Global template loader remains process-global

**Severity**: Low (testability and coupling)
**Found**: 0.4 review (AS-6)
**Affects**: `packages/dartclaw_server/lib/src/templates/loader.dart`, template rendering call sites

**Context**: The old `late` initialization footgun has been reduced: the loader now uses a nullable backing field, throws a clearer `StateError`, and tests can call `resetTemplates()`. But template rendering still depends on a global `templateLoader`, which keeps runtime wiring and some test setups coupled to process-global state.

**Fix**: Consider dependency injection via a `TemplateLoaderService` parameter or a scoped renderer object instead of a global accessor.

**Trigger**: Next time template loading or server boot wiring is refactored, or if template tests start depending on global init order again.

---

## TD-035 — Phone-number pairing UI hidden on both channel pages

**Severity**: Low (QR device linking works for both channels)
**Found**: Channel E2E manual testing (2026-03-08)
**Affects**: `signal_pairing.html`, `signal_pairing_routes.dart`, `whatsapp_pairing.html`

**Context**: Both channel pairing pages had phone-number-based alternatives to QR linking. Signal's SMS registration requires a captcha that did not work during live testing. WhatsApp's phone-number pairing code flow was not tested. Both are hidden to keep the UI clean; QR device linking is the primary and tested pairing method for both channels.

**Current state**:
- **Signal**: SMS/captcha/verify template sections are gated by `tl:if="${captchaPending}"` and `tl:if="${verificationPending}"`; the GET `/pairing` handler no longer sets those flags. POST routes (`/register`, `/register-voice`, `/verify`) remain functional.
- **WhatsApp**: The "or" divider and phone-number form are gated by `tl:if="${showPairingCode}"`, which is never set in template context. POST `/whatsapp/pairing/code` remains functional.

**To re-enable Signal SMS**: In `signal_pairing_routes.dart` GET `/pairing`, restore `step` query param parsing and pass `captchaPending`, `verificationPending`, `captchaPhone`, and `configuredPhone` to the template. Restore the "or" divider and SMS phone input in the link-device section.

**To re-enable WhatsApp pairing code**: Set `'showPairingCode': true` in `whatsapp_pairing.dart` template context.

**Trigger**: When signal-cli captcha flow is confirmed working, or when WhatsApp phone-number pairing is validated with real hardware.

---

## TD-037 — NDJSON session messages grow unbounded (no compaction)

**Severity**: Low (performance degradation over time)
**Found**: Architecture diagram review (2026-03-09)
**Affects**: `packages/dartclaw_core/lib/src/storage/message_service.dart`

**Context**: `messages.ndjson` is append-only with no compaction or archival. Long-lived sessions (cron, channel DMs) accumulate thousands of lines. The full file is scanned on session load. Related: 0.7 F09 (session disk budget) addresses session-level pruning and caps, but not intra-session message compaction.

**Fix**: Truncate to the last N messages after archiving older ones to a `messages-archive-YYYY-MM.ndjson` sidecar, similar to `MemoryPruner`. Or introduce a message cursor window that loads only the tail on session open.

**Trigger**: When long-running cron or channel sessions exceed roughly 10k messages and load time becomes noticeable.

---

## TD-040 — Turn crash recovery has no user-facing retry UX

**Severity**: Low (UX gap — functional recovery exists)
**Found**: Architecture diagram review (2026-03-09)
**Affects**: `packages/dartclaw_server/lib/src/turn_manager.dart`, SSE stream handler
**Target**: 0.17

**Context**: `detectAndCleanOrphanedTurns()` marks orphaned turns as failed and `consumeRecoveryNotice()` shows a banner on next page load. But during a live session, if the harness crashes mid-turn, the SSE stream just stops. The user gets no immediate feedback or retry option; they must refresh and resend.

**Fix**: Emit a terminal SSE event such as `turn_error` when crash recovery kicks in, with a retry CTA in streamed HTML. The client can then show "Turn interrupted — retry?" inline.

**Trigger**: When harness crash recovery is exercised frequently enough to be a UX friction point.

---

## TD-043 — Merge conflict artifact format and resolution UX undefined

**Severity**: Medium (UX gap for coding tasks)
**Found**: Post-implementation PRD review (2026-03-12)
**Affects**: `packages/dartclaw_server/lib/src/tasks/merge_executor.dart`, task detail UI

**Context**: The 0.8 PRD states "Merge conflict -> stay in `review` with conflict details in artifact" and the error-handling table says "Resolve manually or reject." But the artifact format for conflict details (raw git markers, structured JSON, or list of conflicting files) and the resolution workflow are undefined.

**Current state**: `MergeExecutor` creates a conflict artifact when rebase or merge fails. The task stays in `review`. The user sees the conflict message. To resolve: (1) manually resolve conflicts in the worktree via git CLI, (2) push back the task so the agent can re-attempt, or (3) reject the task.

**Fix**: Document the current conflict artifact format in the PRD or data model. Consider adding a "Conflicts" section to the task detail page that shows the list of conflicting files. Resolution can remain manual via git CLI.

**Trigger**: When coding tasks are used frequently enough that merge conflicts become a regular occurrence.

---

## TD-046 — Kill/restart crash-recovery scenario lacks automated validation

**Severity**: Low (test coverage and operational confidence)
**Found**: Operational hygiene follow-up review (2026-03-15)
**Affects**: `packages/dartclaw_server/lib/src/turn_runner.dart`, `apps/dartclaw_cli/lib/src/commands/service_wiring.dart`, `packages/dartclaw_storage/lib/src/storage/turn_state_store.dart`
**Target**: 0.17

**Context**: The operational-hygiene follow-up fixed the rollback leak in `releaseTurn()`, `dart analyze` reran clean, workspace test suites reran successfully, and a plain-profile boot verified `state.db`, legacy `turn:*` cleanup, and `artifact_disk_bytes`. What is still missing is an automated end-to-end scenario that starts a real turn, kills the process before completion, restarts the server, and asserts orphan-turn detection and cleanup from SQLite plus the one-time recovery notice behavior.

**Fix**: Add an integration or smoke test that exercises reserve/start -> hard kill -> restart -> orphan cleanup/recovery notice. Prefer a scripted CLI/profile test over a unit test so real persistence and startup wiring are covered.

**Trigger**: Before calling the operational-hygiene hardening fully closed, before SDK publish, or whenever crash-recovery behavior is touched again.

---

## TD-051 — Task accept flow is coupled to review transitions

**Severity**: Medium (feature friction and lifecycle rigidity)
**Found**: 0.14.1 workshop polish plan review (2026-03-24)
**Affects**: `packages/dartclaw_server/lib/src/task/task_executor.dart`, `packages/dartclaw_server/lib/src/task/task_review_service.dart`, `packages/dartclaw_models/lib/src/task_status.dart`

**Context**: Task completion currently flows through `running -> review`, and the real accept-side effects live in `TaskReviewService`: local merge, project-backed push/PR creation, artifact persistence, and cleanup. This works well for manual review, but it makes "auto-accept on completion" awkward because acceptance behavior is not exposed as a reusable lifecycle operation. The state machine also does not permit `running -> accepted`, so any future simplification must either preserve the current review hop or refactor the lifecycle model deliberately.

**Current resolution for 0.14.1**: Keep the existing lifecycle and implement the simple path (`running -> review -> accepted` via immediate system accept) rather than expanding the state machine.

**Future fix**: Extract acceptance side effects into a shared accept service or method callable from both manual review and system-driven accept flows. Re-evaluate whether a direct `running -> accepted` transition is worth the broader lifecycle, UI, and SSE changes only when there is a stronger product reason than workshop polish.

**Trigger**: Any future work on auto-accept, review policy variants, approval automation, or task lifecycle simplification.

---

## TD-052 — `TaskExecutor._executeCore` is ~200 lines with mixed concerns

**Severity**: Low (maintainability)
**Found**: Post-0.14 code quality review (2026-03-24)
**Affects**: `packages/dartclaw_server/lib/src/task/task_executor.dart`

**Context**: `_executeCore` handles project resolution, worktree setup, session creation, message composition, behavior overrides, turn reservation, turn execution, token recording, tool call recording, trace persistence, artifact collection, budget checking, review transition, loop detection, and error handling in one method.

**Fix**: Extract sub-methods such as `_resolveProjectForTask`, `_setupWorktree`, `_recordTurnMetrics`, and `_handleTurnOutcome`.

**Trigger**: Next time task execution logic is modified.

---

## TD-053 — `TaskEventKind` sealed class should be an enum

**Severity**: Low (code simplification)
**Found**: Post-0.14 code quality review (2026-03-24)
**Affects**: `packages/dartclaw_models/lib/src/task_event.dart`

**Context**: `TaskEventKind` is a sealed class with six final subclasses and no additional fields; each only overrides `String get name`. This is a straightforward fit for an `enum`, and pattern matching with `switch` would still work.

**Trigger**: Next time `TaskEvent` is modified.

---

## TD-054 — Settings page badge variant round-trip

**Severity**: Low (unnecessary complexity)
**Found**: Post-0.14 code quality review (2026-03-24)
**Affects**: `packages/dartclaw_server/lib/src/templates/settings.dart`, `packages/dartclaw_server/lib/src/web/pages/settings_page.dart`

**Context**: The settings page receives badge CSS class strings such as `'status-badge-success'`, then `_badgeVariantFromClass()` reverse-engineers the variant string (`'success'`), only to pass it to `statusBadgeTemplate(variant: 'success', ...)`, which reconstructs the class. Callers already know the variant from their `ChannelStatus` enum.

**Fix**: Change the API to pass variant strings directly, eliminating `_badgeVariantFromClass()`.

**Trigger**: Next time the settings page or badge component is modified.

---

## TD-055 — `_readSessionUsage` repeats default record four times

**Severity**: Low (DRY violation)
**Found**: Post-0.14 code quality review (2026-03-24)
**Affects**: `packages/dartclaw_server/lib/src/web/web_routes.dart`

**Context**: `_readSessionUsage` returns the same five-field default record in four different error or fallback branches. A single constant or early return would eliminate roughly 40 lines.

**Trigger**: Next time session usage display logic is modified.

---

## TD-056 — Duplicated `_cleanupWorktree` across routes and review service

**Severity**: Low (DRY violation)
**Found**: Post-0.14 code quality review (2026-03-24)
**Affects**: `packages/dartclaw_server/lib/src/api/task_routes.dart`, `packages/dartclaw_server/lib/src/api/project_routes.dart`, `packages/dartclaw_server/lib/src/task/task_review_service.dart`

**Context**: There are three near-identical implementations of worktree cleanup: try/catch on `worktreeManager?.cleanup`, then `taskFileGuard?.deregister`.

**Fix**: Extract a shared utility.

**Trigger**: Next time worktree cleanup logic is modified.

---

## TD-058 — Governance timezone only supports UTC offsets

**Severity**: Low (budget reset timing drift during DST)
**Found**: Crowd coding setup feedback (2026-03-25)
**Affects**: `packages/dartclaw_server/lib/src/governance/budget_enforcer.dart`

**Context**: `governance.budget.timezone` only accepts `UTC`, `GMT`, `UTC+N`, and `UTC-N`. IANA names like `Europe/Stockholm` silently fall back to UTC. Budget resets happen at midnight, so UTC-offset-only support means the reset drifts by one hour across DST transitions.

**Fix**: Add `package:timezone` support for IANA names, or accept IANA names and resolve the current UTC offset from them while keeping UTC-offset parsing as fallback.

**Trigger**: Next governance or budget work, or the next DST-related complaint.

---

## TD-059 — No `--project-dir` CLI flag or config option

**Severity**: Medium (DX friction when running from source)
**Found**: Crowd coding setup feedback (2026-03-25)
**Affects**: `apps/dartclaw_cli/lib/src/commands/serve_command.dart`, `packages/dartclaw_config/lib/src/dartclaw_config.dart`

**Context**: The implicit `_local` project always uses `Directory.current.path`. When running from source, the cwd must be the pub workspace root for package resolution, which conflicts with wanting `_local` to point at a different repo. External projects sidestep this for remote repos, but local-path overrides are not supported.

**Fix**: Add `project_dir` config and or `--project-dir` CLI flag that overrides `Directory.current.path` for `_local`. It needs to propagate to `WorktreeManager`, `ContainerManager` mount paths, and `BehaviorFileService`.

**Trigger**: Next crowd-coding or multi-project setup work.

**Resolution note**: Resolved by 0.16.4 S42, which generalized the need to named config/API projects via `projects.<id>.localPath:` instead of extending `_local` with a one-off `--project-dir` surface.

---

## TD-060 — `dartclawVersion` constant not bumped on release

**Severity**: Low (cosmetic — startup banner shows the wrong version)
**Found**: 0.14.3 prep (2026-03-25). Affected 0.14, 0.14.1, 0.14.2
**Affects**: `packages/dartclaw_server/lib/src/version.dart`
**Target**: 0.18

**Context**: The `dartclawVersion` constant is documented as the single source of truth but still requires a manual update. It was missed for three consecutive releases, leaving the banner stuck at `v0.13.1`.

**Fix**: Either add it to a release checklist or derive it from `pubspec.yaml` at build time via a pre-compile step.

---

## TD-061 — Codex stderr silently swallowed

**Severity**: Medium (observability — provider errors invisible)
**Found**: 0.14.3 crowd-coding setup feedback (2026-03-25)
**Affects**: `packages/dartclaw_core/lib/src/harness/codex_harness.dart`
**Target**: 0.18

**Context**: Codex stderr output is still not surfaced in logs. When Codex encounters errors such as invalid model selection, API failures, or rate limits, those diagnostics are effectively invisible. Combined with approval-related deadlocks, this makes Codex failures look like silent hangs.

**Fix**: Log Codex stderr at `WARNING` or `FINE`, following the same pattern used by `ClaudeCodeHarness`.

---

## TD-062 — Stuck Codex turn blocks session with no user feedback

**Severity**: High (availability — blocks an entire crowd-coding session)
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

## TD-063 — `dartclaw_testing` depends on `dartclaw_server`

**Severity**: Low (architectural — constrains future DAG evolution)
**Found**: 0.14.7 preparatory refactoring review (2026-04-02)
**Affects**: `packages/dartclaw_testing/pubspec.yaml`

**Context**: `dartclaw_testing` gained a regular dependency on `dartclaw_server` to support `FakeTurnManager` and `FakeGoogleJwtVerifier`. This makes `dartclaw_testing` heavyweight: any package using it as a dev dependency transitively resolves `dartclaw_server` and its transitive dependencies. Packages lower in the DAG than `dartclaw_server` cannot use `dartclaw_testing` without creating a cycle.

**Trigger for action**: When a package below `dartclaw_server` in the DAG needs shared test doubles from `dartclaw_testing`, split server-specific fakes into `dartclaw_server/test/` or a new `dartclaw_server_testing` package.

---

## TD-064 — Codex workflow-invocation skills directory is unscoped

**Severity**: Medium (token consumption)
**Found**: 0.16.4 S25 remediation (2026-04-17)
**Affects**: `packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart`, Codex workflow one-shot execution

**Context**: Workflow one-shot Codex invocations read skills from the caller's `~/.codex/skills/`, `~/.agent/skills/`, and `~/.agents/skills/` directories, which on typical workstations contain dozens of unrelated skills (~67 observed, ~5,700 tokens of developer preamble per invocation). S25/TI07 implemented a `HOME=<scratch>` override that symlinked only the workflow's `dartclaw-*` skills, but this silently broke Codex OAuth authentication because credentials live at `$HOME/.codex/auth.json` and config at `$HOME/.codex/config.toml` — the scoped `HOME` did not carry either. The override was reverted.

**Current state**: Unscoped — every workflow Codex invocation carries the caller's full installed skills set in its developer preamble. Token-accounting fixes (TI01/TI02/TI04/TI08) still landed, so the primary S25 wins are preserved.

**Fix options**:
1. Wait for Codex upstream to expose a native skills-dir config (`-c skills_dir=...`) or env var, then wire via `WorkflowCliRunner._buildCodexCommand`.
2. Implement a `.codex/` directory clone (symlink `auth.json`, `config.toml`, plus scoped `skills/`) under `HOME=<scratch>`. Fragile — follows upstream's `.codex/` layout, every new file Codex adds becomes a new symlink.
3. File an upstream issue on the Codex CLI repo requesting a skills-dir scoping surface.

**Trigger**: Codex CLI 0.121+ release notes mentioning skills-dir config, or a workflow-execution audit showing preamble token cost dominating step_delta_tokens.

---

## TD-065 — Polymorphic `TaskExecutionStrategy` (workflow-vs-interactive branch remains imperative after S16)

**Severity**: Low (maintainability, testability)
**Found**: 2026-04-21 workflow↔task boundary review (pre-ADR-023 drafting)
**Affects**: `packages/dartclaw_server/lib/src/task/task_executor.dart`, `packages/dartclaw_server/lib/src/task/workflow_cli_runner.dart`

**Context**: `TaskExecutor._executeCore` branches on `_isWorkflowOrchestrated(task)` to route workflow-orchestrated tasks through `_executeWorkflowOneShotTask()` (via `WorkflowCliRunner`) instead of the normal `reserveTurn()` → `HarnessPool` → `TurnRunner` path. After 0.16.5 S16 decomposes `task_executor.dart`, the branch becomes two methods on `_TaskTurnRunner` (`runWorkflowOneShot` / `runNormal`) — a structural improvement, but the `if (_isWorkflowOrchestrated(task))` dispatch still lives in `_executeCore` as an imperative statement, and the two execution strategies sit on the same concrete class rather than behind a polymorphic interface.

**Current state**: Acceptable. One branch with two clear destinations is not a maintenance burden today. ADR-023 names the branch as intentional; S28's fitness test guards the package boundary below it.

**Fix**: Introduce an abstract `TaskExecutionStrategy` interface with `WorkflowOneShotStrategy` and `InteractiveStrategy` implementations. `TaskExecutor._selectStrategy(task)` picks once at the start of `_executeCore`, and the hot path becomes `await strategy.execute(...)` with no conditional. Estimated ~80 LOC, low risk (pure delegation, no behaviour change), covered by existing task-execution tests.

**Trigger**: Any of the following — (a) a third execution mode lands (new harness pattern that is neither interactive nor one-shot, e.g. scheduled agent tasks with a fixed prompt set); (b) testing `_executeCore` requires mocking both paths separately and the dual-method shape makes fakes awkward; (c) per-strategy configuration (observability, budget, cancellation policy) diverges enough that method-level branching loses ergonomics.

**References**: ADR-023 (workflow↔task boundary) · 0.16.5 S16 (task_executor decomposition) · S-BOUND-3 proposal in 2026-04-21 conversation.
