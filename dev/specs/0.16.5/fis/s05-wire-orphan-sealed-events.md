# FIS S05: Wire 7 Orphan Sealed Events (SSE + Alert Mapping)

**Plan**: ../plan.md
**Story-ID**: S05

## Feature Overview and Goal

Close the orphan-event consumer gap so all 7 currently-unwired `sealed DartclawEvent` subtypes — `LoopDetectedEvent`, `EmergencyStopEvent`, `TaskReviewReadyEvent`, `AdvisorInsightEvent`, `CompactionStartingEvent`, `MapIterationCompletedEvent`, `MapStepCompletedEvent` — have at least one production listener (SSE broadcast and/or severity-aware alert routing) flowing from the `EventBus`. Lifts S01's `NOT_ALERTABLE: pending S05` annotations on the events that S05 promotes to alertable, and adds `AdvisorInsightEvent` severity-by-status logic (`stuck` → warning, `concerning` → critical, `on_track` / `diverging` → null + `NOT_ALERTABLE`). SSE envelope format stays byte-stable (no new transport, no new event-name namespace, no new envelope keys).

> **Technical Research**: [.technical-research.md](../.technical-research.md) _(File Map § "S05 — Wire 7 Orphan Sealed Events"; Shared Decision #1 S01→S05; Decision #16 sealed events; Binding Constraints #1, #8, #9, #10, #74, #76, #80, #81, #82)_


## Required Context

> Cross-doc reference rules: see [`fis-authoring-guidelines.md`](${CLAUDE_PLUGIN_ROOT}/references/fis-authoring-guidelines.md#cross-document-references).

### From `../plan.md` — "S05 Scope"
<!-- source: ../plan.md#s05-wire-7-orphan-sealed-events-sse--alert-mapping -->
<!-- extracted: e670c47 -->
> Wire consumers for all 7 orphan sealed events. (a) `LoopDetectedEvent` — S01 handles classify; add SSE broadcast in the appropriate route. (b) `EmergencyStopEvent` — SSE broadcast + critical alert (via S01's classify path). (c) `TaskReviewReadyEvent` — SSE broadcast (the UI already renders; only the bridge is missing). (d) `AdvisorInsightEvent` — SSE broadcast + `classifyAlert` mapping: warning severity on `status: stuck`, critical on `concerning`, info on `on_track | diverging` (no delivery for info). (e) `CompactionStartingEvent` — SSE broadcast paired with existing `CompactionCompletedEvent`. (f) `MapIterationCompletedEvent` + (g) `MapStepCompletedEvent` — SSE broadcast via `workflow_routes.dart` mirroring existing `LoopIterationCompletedEvent` / `ParallelGroupCompletedEvent` handlers. Excludes: new UI components (SSE only; UI work deferred to Block H stretch if needed).

### From `../plan.md` — "S05 Acceptance Criteria"
<!-- source: ../plan.md#s05-wire-7-orphan-sealed-events-sse--alert-mapping -->
<!-- extracted: e670c47 -->
> - Every one of the 7 listed events has at least one production listener (SSE, alert, or both)
> - Exhaustiveness test from S01 remains green
> - `AdvisorInsightEvent` with `status: stuck` triggers a warning alert; `concerning` triggers critical; `on_track` / `diverging` do not alert
> - `workflow_routes.dart` handles `MapIterationCompletedEvent` and `MapStepCompletedEvent` mirroring sibling events
> - Existing SSE envelope format is unchanged (no breaking protocol change)

### From `../prd.md` — "FR1: Safety & Observability Completeness"
<!-- source: ../prd.md#fr1-safety--observability-completeness -->
<!-- extracted: e670c47 -->
> All 7 orphan events wired: `EmergencyStopEvent`, `LoopDetectedEvent`, `TaskReviewReadyEvent`, `AdvisorInsightEvent` (SSE + warn/critical on `status: stuck|concerning`), `CompactionStartingEvent`, `MapIterationCompletedEvent`, `MapStepCompletedEvent`. Any new `DartclawEvent` subtype without coverage fails `dart analyze` (compile-time, not runtime).

### From `../prd.md` — "US10"
<!-- source: ../prd.md#user-stories -->
<!-- extracted: e670c47 -->
> As a dashboard viewer, I want workflow map-iteration and step-completion events visible in real time, so progress is observable. AC: `MapIterationCompletedEvent` + `MapStepCompletedEvent` routed through SSE in `workflow_routes.dart` mirroring sibling events.

### From `../prd.md` — "Decisions Log: severity-by-status for AdvisorInsightEvent"
<!-- source: ../prd.md#decisions-log -->
<!-- extracted: e670c47 -->
> `AdvisorInsightEvent` wires to SSE + severity-aware alert on `status: stuck|concerning`. Wire all 7 orphan events (not delete) — events carry semantic payload.

### S01 dependency note (consumed contract)
<!-- source: dev/specs/0.16.5/fis/s01-alert-classifier-safety.md -->
<!-- extracted: feat/0.16.5 -->
> S01 lands `classifyAlert` and `AlertFormatter._body`/`_details` as exhaustive `switch (event)` expressions over `sealed DartclawEvent`, with **`NOT_ALERTABLE: pending S05 — wired to SSE only / status-driven alert added in S05`** annotations on the orphan event class declarations whose arm currently returns `null`. S05 flips the relevant arms (`AdvisorInsightEvent`) and rewrites their class-level `NOT_ALERTABLE` comments to either remove the annotation (now alertable) or update the rationale (SSE-only).


## Deeper Context

- `../.technical-research.md#s05--wire-7-orphan-sealed-events-sse--alert-mapping` — File Map for this story.
- `../.technical-research.md#shared-architectural-decisions` — Decision #1 (S01 → S05 sealed-event contract); Decision #16 (sealed events).
- `../.technical-research.md#binding-prd-constraints` — rows #1, #8, #9, #10, #74, #76, #80, #81 anchor S05; row #82 (envelope stability) intersects via the no-new-format invariant.
- `dev/specs/0.16.5/fis/s01-alert-classifier-safety.md` — upstream switch-expression baseline; S05 mutates the same `alert_classifier.dart` switch and the same per-class `NOT_ALERTABLE` comments.
- `packages/dartclaw_server/CLAUDE.md` — package conventions: "Routes go under `lib/src/api/*_routes.dart` … SSE streams use `sse_broadcast.dart` / `stream_handler.dart` — don't roll new SSE plumbing."


## Success Criteria (Must Be TRUE)

> Each criterion has a proof path (Scenario or Verify line); criterion → upstream source noted in trailing parens.

- [x] Every concrete event in the orphan-7 set has at least one production-side consumer in `packages/dartclaw_server/lib/`: SSE broadcast (per-run via `workflow_routes.dart` for `MapIterationCompletedEvent` + `MapStepCompletedEvent`; global via `SseBroadcast` for `LoopDetectedEvent`, `TaskReviewReadyEvent`, `AdvisorInsightEvent`, `CompactionStartingEvent`) and/or alert (`classifyAlert` arm returning non-null for `EmergencyStopEvent`, `LoopDetectedEvent`, and `AdvisorInsightEvent` with `status` ∈ {`stuck`,`concerning`}). `rg "EventBus\.on<(LoopDetected|TaskReviewReady|AdvisorInsight|CompactionStarting|MapIterationCompleted|MapStepCompleted)Event>" packages/dartclaw_server/lib/` returns ≥1 hit per SSE-bridged type, and `AlertRouter` consumes `EmergencyStopEvent` through `EventBus.on<DartclawEvent>()`. (plan AC #1, PRD FR1, binding #8, #74, #81)
- [x] `classifyAlert(AdvisorInsightEvent(status: 'stuck', …))` returns `(alertType: 'advisor_insight', severity: AlertSeverity.warning)`; `status: 'concerning'` returns `(advisor_insight, critical)`; `status: 'on_track'` and `status: 'diverging'` return `null`; any other status string returns `null` and logs at `fine` (graceful malformed-payload handling). (plan AC #3, PRD FR1, binding #80)
- [x] `MapIterationCompletedEvent` and `MapStepCompletedEvent` are subscribed inside `_workflowRunSseHandler` filtered by `runId`, with `_sendSse` payloads modeled on the existing `loop_iteration_completed` / `parallel_group_completed` handlers (envelope keys: `type`, `runId`, plus the event's own primitive fields). The two new SSE `type` strings are `map_iteration_completed` and `map_step_completed`. (plan AC #4, PRD US10, binding #10)
- [x] S01's compile-time exhaustiveness over `sealed DartclawEvent` remains green: `dart analyze --fatal-warnings --fatal-infos packages/dartclaw_server packages/dartclaw_core` clean, with the `classifyAlert` and `AlertFormatter._body`/`_details` switches still containing one arm per concrete leaf and **no** `default:` branches. (plan AC #2, PRD FR1, binding #9)
- [x] SSE envelope wire format is byte-stable for previously-shipping event types: per-run handler still emits `data: ${jsonEncode(...)}\n\n` frames via `_sendSse`; global broadcaster still emits `event: <name>\ndata: ${jsonEncode(...)}\n\n` frames via `SseBroadcast.broadcast`; no existing `type` / `event:` strings renamed. (plan AC #5, PRD Out of Scope, binding #1, #76)
- [x] Every orphan-event class declaration in `packages/dartclaw_core/lib/src/events/*_events.dart` whose `classifyAlert` arm now returns non-null has its S01-era `NOT_ALERTABLE: pending S05 …` annotation **removed**; arms still returning `null` carry an updated `NOT_ALERTABLE: <stable-reason>` rationale (e.g. `lifecycle telemetry — SSE only`). (binding #74, S01 dependency note)

### Health Metrics (Must NOT Regress)

- [x] All pre-existing `alert_classifier_test.dart`, `alert_formatter_test.dart`, `workflow_routes_test.dart`, and advisor-suite tests pass with unchanged assertions. The 7 currently-mapped events keep their byte-identical `(alertType, severity)` tuples; the existing per-run SSE event names (`workflow_status_changed`, `workflow_step_completed`, `parallel_group_completed`, `loop_iteration_completed`, `task_status_changed`, `approval_requested`, `approval_resolved`) are unchanged.
- [x] No new package dependencies added to any `pubspec.yaml` (binding #2). New SSE plumbing reuses `SseBroadcast` and `_sendSse` per `dartclaw_server/CLAUDE.md`.
- [x] Workspace-wide `strict-casts` + `strict-raw-types` remain on; `dart analyze --fatal-warnings --fatal-infos` is clean (binding #3, #73).
- [x] No regression in `EmergencyStopHandler` direct-imperative `_sseBroadcast?.broadcast('emergency_stop', …)` call — that path stays as a defence-in-depth fallback even after the EventBus-driven bridge is added (intentional double-delivery; the bridge is the future-proof seam, the imperative call is the legacy seam — see § Constraints).


## Scenarios

### Happy: Map-iteration completion reaches per-run SSE subscribers
- **Given** a workflow run is in progress, a client is subscribed to `GET /api/workflows/runs/<runId>/events`, and `MapIterationCompletedEvent(runId: <runId>, stepId: 's2', iterationIndex: 3, totalIterations: 10, taskId: 't-x', success: true, tokenCount: 120, …)` is fired on the `EventBus`
- **When** the per-run SSE handler routes the event
- **Then** the subscriber receives a frame whose decoded `data:` JSON contains `{"type":"map_iteration_completed","runId":"<runId>","stepId":"s2","iterationIndex":3,"totalIterations":10,"taskId":"t-x","success":true,"tokenCount":120}` (key set mirrors `LoopIterationCompletedEvent` envelope shape)

### Happy: Map-step completion reaches per-run SSE subscribers
- **Given** the same per-run SSE subscription, and `MapStepCompletedEvent(runId: <runId>, stepId: 's2', stepName: 'fanout', totalIterations: 10, successCount: 9, failureCount: 1, cancelledCount: 0, totalTokens: 1200, …)` fires
- **When** the handler routes the event
- **Then** the subscriber receives a frame whose decoded `data:` JSON contains `{"type":"map_step_completed","runId":"<runId>","stepId":"s2","stepName":"fanout","totalIterations":10,"successCount":9,"failureCount":1,"cancelledCount":0,"totalTokens":1200}`

### Happy: Emergency stop classified critical AND broadcast on global SSE via EventBus bridge
- **Given** an admin runs `/stop` and `EmergencyStopHandler.execute(...)` fires both an `EmergencyStopEvent` on the `EventBus` and the legacy imperative `_sseBroadcast?.broadcast('emergency_stop', …)`
- **When** `AlertRouter` consumes the event (S01's switch returns `(emergency_stop, critical)`) and the new EventBus → `SseBroadcast` bridge mirrors it under SSE event name `emergency_stop`
- **Then** the configured alert target receives a critical alert, and global SSE subscribers see exactly one `emergency_stop` frame per real stop (the bridge dedupes against the imperative broadcast — see § Constraints; alternative: keep the imperative call and let the bridge skip `EmergencyStopEvent`. Implementation chooses one — cf. TI03)

### Happy: Loop detected → critical alert + global SSE broadcast
- **Given** the loop detector fires `LoopDetectedEvent(sessionId: 's-1', mechanism: 'turnChainDepth', message: '…', action: 'abort', …)` on the `EventBus`
- **When** the alert router and the new EventBus → `SseBroadcast` bridge consume it
- **Then** `AlertRouter` delivers a critical alert (S01 path), and global SSE subscribers receive a frame `event: loop_detected\ndata: {"sessionId":"s-1","mechanism":"turnChainDepth","action":"abort", …}\n\n` via `SseBroadcast.broadcast('loop_detected', …)`

### Happy: Compaction starting paired with completion
- **Given** `CompactionStartingEvent(sessionId: 's-1', trigger: 'auto', …)` fires before `CompactionCompletedEvent`
- **When** the bridge consumes both
- **Then** global SSE subscribers receive a `compaction_starting` frame followed by the existing `compaction_completed` frame in order; SSE envelope keys mirror the existing `compaction` family (the existing imperative `compaction` SSE frame, if any, stays — no rename)

### Happy: Task review ready bridges to global SSE
- **Given** `TaskReviewReadyEvent(taskId: 't-1', artifactCount: 3, artifactKinds: ['file_diff','console_log','plan'], …)` fires
- **When** the bridge consumes it
- **Then** global SSE subscribers receive `event: task_review_ready\ndata: {"taskId":"t-1","artifactCount":3,"artifactKinds":["file_diff","console_log","plan"]}\n\n`

### Happy: AdvisorInsightEvent with `status: on_track` → SSE only, no alert
- **Given** the advisor produces `AdvisorInsightEvent(status: 'on_track', observation: '…', triggerType: '…', taskIds: [...], sessionKey: '…', …)`
- **When** `AlertRouter` consumes it and the SSE bridge consumes it
- **Then** `classifyAlert` returns `null` (no alert delivered, but the event class declaration carries a stable `NOT_ALERTABLE: informational status — SSE only`); global SSE subscribers receive an `advisor_insight` frame containing `status`, `observation`, `suggestion`, `triggerType`, `taskIds`, `sessionKey`

### Edge: AdvisorInsightEvent with `status: stuck` → warning alert + SSE
- **Given** `AdvisorInsightEvent(status: 'stuck', observation: 'Tasks stalled in review', …)` fires
- **When** `AlertRouter` consumes it and the SSE bridge consumes it
- **Then** `classifyAlert` returns `(alertType: 'advisor_insight', severity: AlertSeverity.warning)`, the warning alert is delivered, and the SSE frame is emitted as in the on_track scenario

### Edge: AdvisorInsightEvent with `status: concerning` → critical alert + SSE
- **Given** `AdvisorInsightEvent(status: 'concerning', …)` fires
- **When** `AlertRouter` consumes it
- **Then** `classifyAlert` returns `(alertType: 'advisor_insight', severity: AlertSeverity.critical)` and the critical alert is delivered

### Negative: AdvisorInsightEvent with malformed status string
- **Given** `AdvisorInsightEvent(status: 'unknown_value', …)` fires (e.g. an upstream advisor change introduces a new status before the classifier learns it)
- **When** `classifyAlert` runs
- **Then** the call returns `null` (no alert), the SSE bridge still emits the `advisor_insight` frame so dashboards can render it, and a `_log.fine('AdvisorInsightEvent unrecognised status: $status — no alert')` line is recorded. The classifier does **not** throw, does **not** crash `AlertRouter`, and does **not** require a new switch arm (default case is folded into the `AdvisorInsightEvent()` arm via a `when` guard or trailing `_` pattern returning `null`).

### Edge: Compile-time exhaustiveness still enforced
- **Given** a hypothetical new `final class FooSafetyEvent extends DartclawEvent { … }` is introduced into `packages/dartclaw_core/lib/src/events/governance_events.dart`
- **When** `dart analyze --fatal-warnings --fatal-infos packages/dartclaw_server` runs
- **Then** the analyzer fires `non_exhaustive_switch_expression` at the three S01 sites (`alert_classifier.dart`, `alert_formatter.dart` `_body`, `_details`) naming `FooSafetyEvent` (S01 contract preserved by S05)


## Scope & Boundaries

### In Scope

- Add `MapIterationCompletedEvent` + `MapStepCompletedEvent` subscriptions inside `_workflowRunSseHandler` in `packages/dartclaw_server/lib/src/api/workflow_routes.dart`, mirroring the existing `LoopIterationCompletedEvent` / `ParallelGroupCompletedEvent` handlers (SSE `type` strings: `map_iteration_completed`, `map_step_completed`); register their `cancel()` calls in the `controller.onCancel` block.
- Add a small `EventBus` → `SseBroadcast` bridge for the 5 non-`runId` orphans (`LoopDetectedEvent`, `EmergencyStopEvent`, `TaskReviewReadyEvent`, `AdvisorInsightEvent`, `CompactionStartingEvent`) that listens on `EventBus` and calls `SseBroadcast.broadcast(<event>, <payload>)` with stable event-name strings (`loop_detected`, `emergency_stop`, `task_review_ready`, `advisor_insight`, `compaction_starting`). Wire the bridge in `ServerBuilder` next to the existing `TaskEventRecorder` / `TaskProgressTracker` subscriber wiring.
- Extend `classifyAlert` in `packages/dartclaw_server/lib/src/alerts/alert_classifier.dart` so the `AdvisorInsightEvent` arm becomes `AdvisorInsightEvent(status: final s) when s == 'stuck' || s == 'concerning' => (alertType: 'advisor_insight', severity: ...)` (or equivalent destructuring); the catch-all returns `null` and `_log.fine`s the unrecognised status. Update `AlertFormatter._body` + `_details` to produce the human-readable body / detail map for `AdvisorInsightEvent` when alertable.
- Update the `NOT_ALERTABLE: …` annotations on `AdvisorInsightEvent`, `TaskReviewReadyEvent`, `MapIterationCompletedEvent`, `MapStepCompletedEvent`, `CompactionStartingEvent`, `LoopDetectedEvent`, `EmergencyStopEvent` class declarations in `packages/dartclaw_core/lib/src/events/*_events.dart`: the alertable ones (`LoopDetectedEvent`, `EmergencyStopEvent` — already shipped by S01; `AdvisorInsightEvent` — newly alertable here) lose the annotation; the SSE-only ones get a stable rationale (`NOT_ALERTABLE: lifecycle / progress telemetry — SSE only`).
- Add unit tests covering: `classifyAlert(AdvisorInsightEvent)` for the four canonical statuses + one malformed; per-run SSE delivery for `MapIterationCompletedEvent` + `MapStepCompletedEvent` (using the existing `workflow_routes_test.dart` `EventBus` injection harness); global SSE bridge delivery for the 5 non-`runId` orphans (using a `TestEventBus` + `SseBroadcast` with a pseudo-client controller).

### What We're NOT Doing

- **No new UI components or HTMX fragments.** SSE-only wiring; dashboard rendering (e.g. a "map progress" panel, a "compaction in flight" badge) is deferred to Block H stretch (S26). Existing dashboard panels that already render `loop_iteration_completed` / `compaction_completed` frames continue to do so unchanged.
- **No new alert sinks.** Alert delivery flows through the existing `AlertRouter` → `AlertDeliveryAdapter` chain. No new transport, no new envelope.
- **No deduplication of `EmergencyStopHandler`'s imperative `SseBroadcast.broadcast('emergency_stop', …)` against the new EventBus bridge.** Per PRD edge case (and the canvas-Advisor double-delivery precedent), intentional double-delivery is acceptable; one path is fire-and-forget telemetry, the other is the operational seam — both should land. (See § Constraints for the implementation choice.)
- **No alert/SSE wiring for `WorkflowCliTurnProgressEvent`, `AdvisorMentionEvent`, `ConfigChangedEvent`, `FailedAuthEvent`** — those are out-of-scope orphans; their S01 `NOT_ALERTABLE` annotations stay (UI progress / mention is routed elsewhere; auth/config events feed dedicated subscribers).
- **No SSE envelope re-shaping.** New event types follow the existing per-run handler key convention (`type`, `runId`, plus event-native primitive fields) for `Map*` events; new event types follow `SseBroadcast.broadcast(eventName, payload)` shape (event name in `event:` line, payload in `data:` line) for the 5 non-`runId` events. No shared "envelope" record/typedef refactor.
- **No retroactive renumbering of S01's `alertType` strings.** New `alertType: 'advisor_insight'` is additive; `loop_detected` / `emergency_stop` already shipped via S01.


## Architecture Decision

**We will**: follow the existing sibling-event SSE pattern in `workflow_routes.dart` (the `LoopIterationCompletedEvent` and `ParallelGroupCompletedEvent` handlers at lines 615–635) for the two `runId`-bearing events, and a small `EventBusSseBridge` subscriber wired in `ServerBuilder` for the 5 non-`runId` events that fans `EventBus.on<…>()` into `SseBroadcast.broadcast(eventName, payload)`. **No new SSE envelope type, no new event-name namespace.** Severity for `AdvisorInsightEvent` is mapped per its `status` field at classify-time inside the existing S01 switch arm, not in the route handler — keeping classification policy in `AlertClassifier` and route plumbing in `*_routes.dart` matches existing separation of concerns. The `AlertRouter` already iterates `bus.on<DartclawEvent>()`, so adding a non-null `classifyAlert` arm is sufficient for alert delivery — no new subscriber wiring.

See plan Decisions Log row "Wire all 7 orphan events (not delete) — events carry semantic payload" (`prd.md#decisions-log`) and shared decision #1 in `.technical-research.md`.


## Technical Overview

### Data Models

The 7 orphan events split into two groups by SSE delivery shape:

- **Per-run events (`runId`-keyed)**: `MapIterationCompletedEvent`, `MapStepCompletedEvent` — both extend `WorkflowLifecycleEvent` and expose `runId`. These belong in `_workflowRunSseHandler` filtered by `e.runId == runId`, mirroring `LoopIterationCompletedEvent` and `ParallelGroupCompletedEvent` at `workflow_routes.dart:615–635`. Field reference (verbatim from `packages/dartclaw_core/lib/src/events/workflow_events.dart`):
  - `MapIterationCompletedEvent`: `runId`, `stepId`, `iterationIndex`, `totalIterations`, `itemId?`, `taskId`, `success`, `tokenCount`, `timestamp`.
  - `MapStepCompletedEvent`: `runId`, `stepId`, `stepName`, `totalIterations`, `successCount`, `failureCount`, `cancelledCount`, `totalTokens`, `timestamp`.
- **Non-run events (no `runId`)**: `LoopDetectedEvent` (sessionId/mechanism/action/detail), `EmergencyStopEvent` (stoppedBy/turnsCancelled/tasksCancelled), `TaskReviewReadyEvent` (taskId/artifactCount/artifactKinds), `AdvisorInsightEvent` (status/observation/suggestion/triggerType/taskIds/sessionKey), `CompactionStartingEvent` (sessionId/trigger). These flow through the global `SseBroadcast` channel served at `GET /api/events`. Field reference: `packages/dartclaw_core/lib/src/events/{governance,task,advisor,compaction}_events.dart`.

### Integration Points

- **Producers (existing, unchanged)**: `EventBus.fire(MapIterationCompletedEvent(...))` in `packages/dartclaw_workflow/lib/src/workflow/foreach_iteration_runner.dart:282`; `MapStepCompletedEvent` at `foreach_iteration_runner.dart:376` and `map_iteration_runner.dart:402`; `LoopDetectedEvent` at `turn_governance_enforcer.dart:119`; `EmergencyStopEvent` at `emergency_stop_handler.dart:93`; `CompactionStartingEvent` at `turn_runner.dart:481`; `AdvisorInsightEvent` at `advisor_subscriber.dart:364`; `TaskReviewReadyEvent` at `task_service.dart:499`. **S05 does not touch any producer.**
- **Consumers (added by this story)**:
  - `_workflowRunSseHandler` in `packages/dartclaw_server/lib/src/api/workflow_routes.dart` — two new `bus.on<MapIterationCompletedEvent>().where((e) => e.runId == runId).listen(...)` and `bus.on<MapStepCompletedEvent>().where((e) => e.runId == runId).listen(...)` subscriptions, with corresponding `_sendSse(...)` payload shape and `cancel()` registration in `controller.onCancel`.
  - New `EventBusSseBridge` (single-purpose subscriber class) in `packages/dartclaw_server/lib/src/api/event_bus_sse_bridge.dart` — listens on the 5 non-`runId` events and calls `SseBroadcast.broadcast(...)`. Wired in `ServerBuilder.build()` after the existing subscriber wiring, only when both `eventBus` and `sseBroadcast` are non-null. Disposed via the standard `cancel()` pattern.
  - `classifyAlert` in `packages/dartclaw_server/lib/src/alerts/alert_classifier.dart` — `AdvisorInsightEvent(status: final s)` arm gets a `when s == 'stuck' || s == 'concerning'` guard returning `(advisor_insight, warning|critical)`; trailing arm returns `null`. `AlertFormatter._body` + `_details` get matching arms.
  - `NOT_ALERTABLE` annotation maintenance in `packages/dartclaw_core/lib/src/events/{governance,task,advisor,compaction,workflow}_events.dart`.
- **Downstream coupling (out of scope)**: dashboard rendering of the new SSE event types. The HTMX dashboard already consumes `/api/events` — adding new event names to the upstream is harmless because existing consumers ignore unknown `event:` names.


## Code Patterns & External References

```
# type | path/url                                                                                  | why needed
file   | packages/dartclaw_server/lib/src/api/workflow_routes.dart:615-635                         | Sibling LoopIterationCompletedEvent / ParallelGroupCompletedEvent handlers — verbatim pattern for Map* SSE wiring
file   | packages/dartclaw_server/lib/src/api/workflow_routes.dart:676-684                         | controller.onCancel block — register cancel() for the two new subscriptions
file   | packages/dartclaw_server/lib/src/api/workflow_routes.dart:692-699                         | _sendSse helper — reuse, do not reimplement
file   | packages/dartclaw_server/lib/src/api/sse_broadcast.dart                                   | Global SseBroadcast.broadcast(event, payload) — used by the bridge for 5 non-runId events
file   | packages/dartclaw_server/lib/src/advisor/advisor_subscriber.dart:358-381                  | Reference wiring pattern: structured event firing + downstream routing
file   | packages/dartclaw_server/lib/src/alerts/alert_classifier.dart                             | S01 switch — add AdvisorInsightEvent severity-by-status guard
file   | packages/dartclaw_server/lib/src/alerts/alert_formatter.dart                              | _body + _details switches — add AdvisorInsightEvent body/detail formatting
file   | packages/dartclaw_server/lib/src/alerts/alert_router.dart:49,70-85                        | Existing bus.on<DartclawEvent>().listen(_onEvent) — confirms classifyAlert is the only seam needed for alert delivery
file   | packages/dartclaw_server/lib/src/server_builder.dart:185-225                              | Existing subscriber wiring (TaskEventRecorder, TaskProgressTracker) — wire EventBusSseBridge here
file   | packages/dartclaw_server/lib/src/emergency/emergency_stop_handler.dart:92-106             | Existing imperative emergency_stop SSE broadcast — coexists with new EventBus bridge
file   | packages/dartclaw_core/lib/src/events/workflow_events.dart:251-295,360-405                | MapIterationCompletedEvent + MapStepCompletedEvent field definitions (used to author payload)
file   | packages/dartclaw_core/lib/src/events/advisor_events.dart:46-81                           | AdvisorInsightEvent.status field type (String) — drives the when-guard pattern
file   | packages/dartclaw_core/lib/src/events/governance_events.dart:1-63                         | LoopDetectedEvent + EmergencyStopEvent — payload shape for SSE
file   | packages/dartclaw_core/lib/src/events/task_events.dart:47-72                              | TaskReviewReadyEvent — payload shape for SSE
file   | packages/dartclaw_core/lib/src/events/compaction_events.dart:20-34                        | CompactionStartingEvent — payload shape for SSE
file   | packages/dartclaw_server/test/api/workflow_routes_test.dart                               | Existing test harness with EventBus injection — extend for Map* SSE assertions
file   | packages/dartclaw_server/test/alerts/alert_classifier_test.dart                           | Existing classifier test pattern — extend for AdvisorInsightEvent statuses
file   | dev/specs/0.16.5/fis/s01-alert-classifier-safety.md                                       | Upstream contract producing the switch baseline
url    | https://dart.dev/language/patterns#guard-clauses                                          | Dart 3 `when` guard syntax for AdvisorInsightEvent severity-by-status
```


## Constraints & Gotchas

- **Constraint (binding #1, #76)**: SSE envelope format is byte-stable for shipped event types. Per-run handler frames stay `data: ${jsonEncode(map)}\n\n`; global `SseBroadcast` frames stay `event: <name>\ndata: ${jsonEncode(map)}\n\n`. **New event types use the same shapes** — no new envelope fields, no new framing.
- **Constraint (binding #9 / S01 contract)**: The S01 exhaustive switch in `alert_classifier.dart` and `alert_formatter.dart` must remain compile-time exhaustive after S05's edits. Encode `AdvisorInsightEvent` severity-by-status with a single arm using a `when` guard or destructuring + trailing `null` arm — **do not** introduce a `default:` branch (would defeat enforcement; ref. S01 § Constraints "Avoid: Adding `default:` branches").
- **Constraint (binding #2)**: No new package dependencies. Bridge implementation uses existing `SseBroadcast`, `EventBus`, `dart:async`, `package:logging` only.
- **Critical (intentional double-delivery)**: `EmergencyStopHandler.execute` already calls `_sseBroadcast?.broadcast('emergency_stop', …)` imperatively at `emergency_stop_handler.dart:102-106`, alongside firing `EmergencyStopEvent` on the bus. Two implementation choices:
  1. **Bridge skips `EmergencyStopEvent`** (the imperative call remains canonical for `emergency_stop`; bridge only handles the other 4 non-`runId` events).
  2. **Bridge emits `emergency_stop` frame too** and `EmergencyStopHandler` keeps the imperative call as legacy/defence-in-depth — accepting one duplicate frame per real stop.
  **Choose option 1** to keep wire output identical and avoid duplicate-frame churn for the most operationally-critical event. Document this in the bridge's class dartdoc.
- **Critical (`AdvisorInsightEvent.status` typing)**: the field is `String`, not an enum (see `advisor_events.dart:48`). Pattern arm must work on raw strings: `AdvisorInsightEvent(status: final s) when s == 'stuck' => (advisor_insight, warning), AdvisorInsightEvent(status: final s) when s == 'concerning' => (advisor_insight, critical), AdvisorInsightEvent() => null`. The trailing `AdvisorInsightEvent()` arm must explicitly return `null` and a separate `_log.fine` line in the consumer (or a small private helper called from the arm) handles the malformed-status case.
- **Critical (`NOT_ALERTABLE` discipline)**: After S05, `AdvisorInsightEvent`'s class declaration loses S01's `NOT_ALERTABLE: pending S05 …` annotation entirely (it now alerts conditionally — annotation does not fit). For the SSE-only orphans (`TaskReviewReadyEvent`, `MapIterationCompletedEvent`, `MapStepCompletedEvent`, `CompactionStartingEvent`), update the annotation to a stable rationale (`NOT_ALERTABLE: lifecycle telemetry — surfaced via SSE only`) — drop the `pending S05` text. Per S01 § Constraints, the comment lives on the **class declaration**, not at the classifier arm.
- **Avoid (envelope drift)**: do **not** invent a new "advisor" SSE event-name namespace (e.g. `advisor:insight`). Use a flat `advisor_insight` event name to match the existing convention (`emergency_stop`, `compaction_completed`, …).
- **Avoid (synchronous bridge work)**: the bridge must be fire-and-forget. Do not `await` anything inside the EventBus listener — callers expect `EventBus.fire` to return immediately. If payload construction needs async resolution (e.g. task lookup), do it in a separate subscriber, not the bridge.
- **Gotcha (duplicate canvas advisor delivery)**: `AdvisorSubscriber.route` at `advisor_subscriber.dart:358-381` already pushes the advisor card into the canvas service before firing `AdvisorInsightEvent`. The new SSE bridge will deliver `advisor_insight` to global SSE clients in addition to the canvas push — intentional, per PRD edge case "intentional double-delivery with existing canvas Advisor renderer". Document this in the bridge dartdoc.
- **Gotcha (ServerBuilder ordering)**: wire `EventBusSseBridge` **after** `eventBus` and `sseBroadcast` are confirmed non-null, mirroring the `progressTracker` guard at `server_builder.dart:188-190`. Pass the bridge through to `DartclawServer.compose` so its `cancel()` is invoked on server dispose.


## Implementation Plan

> **Vertical slice ordering**: Land the four "simple" non-`runId` SSE bridges first (smallest end-to-end demonstration), then add the two per-run `Map*` handlers (next sibling-pattern repetition), then add `AdvisorInsightEvent` classify/format severity logic, then verify S01 exhaustiveness and run the integration suite.

### Implementation Tasks

- [x] **TI01** Create `packages/dartclaw_server/lib/src/api/event_bus_sse_bridge.dart` housing `class EventBusSseBridge` with constructor `({required EventBus bus, required SseBroadcast broadcast})`, four internal `StreamSubscription`s for `LoopDetectedEvent`, `TaskReviewReadyEvent`, `AdvisorInsightEvent`, `CompactionStartingEvent`, and a `Future<void> cancel()` that cancels them all. Each listener calls `broadcast.broadcast('<eventName>', <payloadMap>)` with the event-name and payload-key conventions specified in § Technical Overview. **Excludes** `EmergencyStopEvent` (per § Constraints, that path is owned by `EmergencyStopHandler`'s imperative broadcast). Class dartdoc documents the design choice + the canvas-double-delivery note.
  - Add re-export to `packages/dartclaw_server/lib/src/api/api_exports.dart` (mirroring the existing `export 'sse_broadcast.dart' show SseBroadcast;` line).
  - **Verify**: `dart analyze --fatal-warnings --fatal-infos packages/dartclaw_server` clean; `rg "EventBus\.on<(LoopDetected|TaskReviewReady|AdvisorInsight|CompactionStarting)Event>" packages/dartclaw_server/lib/src/api/event_bus_sse_bridge.dart` returns 4 hits.

- [x] **TI02** Wire `EventBusSseBridge` in `packages/dartclaw_server/lib/src/server_builder.dart`: after the existing subscriber wiring (line ~188), add `final eventBusSseBridge = (eventBus != null && sseBroadcast != null) ? EventBusSseBridge(bus: eventBus!, broadcast: sseBroadcast!) : null;` and pass it through to `DartclawServer.compose(...)`. Update `DartclawServer` to accept and store the bridge, and to call `bridge?.cancel()` inside the existing dispose path (alongside `_sseBroadcast?.dispose()`).
  - **Verify**: `dart analyze` clean; on server start with both `eventBus` and `sseBroadcast` configured, the bridge is constructed (assert via a unit test on `ServerBuilder` or via debug log).

- [x] **TI03** Extend `_workflowRunSseHandler` in `packages/dartclaw_server/lib/src/api/workflow_routes.dart` (after the existing `loopSub` declaration at line 626): add `mapIterationSub` listening to `eventBus.on<MapIterationCompletedEvent>().where((e) => e.runId == runId)` emitting `_sendSse(controller, {'type': 'map_iteration_completed', 'runId': event.runId, 'stepId': event.stepId, 'iterationIndex': event.iterationIndex, 'totalIterations': event.totalIterations, if (event.itemId != null) 'itemId': event.itemId, 'taskId': event.taskId, 'success': event.success, 'tokenCount': event.tokenCount})`. Add `mapStepSub` listening to `eventBus.on<MapStepCompletedEvent>().where((e) => e.runId == runId)` emitting `_sendSse(controller, {'type': 'map_step_completed', 'runId': event.runId, 'stepId': event.stepId, 'stepName': event.stepName, 'totalIterations': event.totalIterations, 'successCount': event.successCount, 'failureCount': event.failureCount, 'cancelledCount': event.cancelledCount, 'totalTokens': event.totalTokens})`. Add both to the import-`show` clause at the top of the file. Register `mapIterationSub.cancel()` and `mapStepSub.cancel()` in the `controller.onCancel` block (line 676–684).
  - **Verify**: `dart analyze` clean; `rg "map_iteration_completed|map_step_completed" packages/dartclaw_server/lib/src/api/workflow_routes.dart` returns 2 hits each (declaration + onCancel-touch optional).

- [x] **TI04** Extend `classifyAlert` in `packages/dartclaw_server/lib/src/alerts/alert_classifier.dart`: replace the existing `AdvisorInsightEvent` arm (which under S01 returns `null` with `NOT_ALERTABLE: pending S05 …` on the class) with the severity-by-status pattern:
  ```dart
  AdvisorInsightEvent(status: 'stuck') => (alertType: 'advisor_insight', severity: AlertSeverity.warning),
  AdvisorInsightEvent(status: 'concerning') => (alertType: 'advisor_insight', severity: AlertSeverity.critical),
  AdvisorInsightEvent() => null,
  ```
  (or equivalent destructuring with `when` guards if the literal-status pattern doesn't compile). Update the dartdoc table at the top of `classifyAlert` (lines 12-19) to add `[AdvisorInsightEvent] stuck → warning, concerning → critical, else → null`.
  - **Verify**: `dart analyze` clean; `dart test packages/dartclaw_server/test/alerts/alert_classifier_test.dart` passes; new test cases for the four canonical statuses (`stuck` / `concerning` / `on_track` / `diverging`) and one malformed string assert the correct return values.

- [x] **TI05** Extend `AlertFormatter._body` and `_details` in `packages/dartclaw_server/lib/src/alerts/alert_formatter.dart`: the `AdvisorInsightEvent` arms now produce non-null bodies/details for the alertable statuses. `_body`: `'Advisor flagged status \"${event.status}\" — ${event.observation}'`. `_details`: `{'Status': status, 'Observation': observation, if (suggestion != null) 'Suggestion': suggestion!, 'Trigger': triggerType, 'Tasks': taskIds.join(', '), 'Session': sessionKey}`. For non-alertable statuses, `_body` is only invoked when `classifyAlert` returns non-null, so the trailing `AdvisorInsightEvent()` arm in `_body` is unreachable in practice — return a stable placeholder (`'Advisor insight (status: ${event.status})'`) to satisfy the analyzer (matches S01 § TI02 pattern at `alert_formatter.dart:108`).
  - **Verify**: `dart analyze` clean; `dart test packages/dartclaw_server/test/alerts/alert_formatter_test.dart` passes; new test asserts `[WARNING]` prefix + body + detail-map keys for `stuck` and `[CRITICAL]` for `concerning`.

- [x] **TI06** Update `NOT_ALERTABLE` annotations in `packages/dartclaw_core/lib/src/events/`:
  - `advisor_events.dart` `AdvisorInsightEvent` (line ~46): **delete** the S01-era `// NOT_ALERTABLE: pending S05 …` comment entirely (now conditionally alertable; not annotated).
  - `task_events.dart` `TaskReviewReadyEvent` (line ~47): replace S01 placeholder with `// NOT_ALERTABLE: lifecycle telemetry — surfaced via SSE only`.
  - `compaction_events.dart` `CompactionStartingEvent` (line ~20): replace with `// NOT_ALERTABLE: lifecycle telemetry — surfaced via SSE only`.
  - `workflow_events.dart` `MapIterationCompletedEvent` (line ~251) and `MapStepCompletedEvent` (line ~360): replace with `// NOT_ALERTABLE: progress telemetry — surfaced via SSE only`.
  - `governance_events.dart` `LoopDetectedEvent` + `EmergencyStopEvent`: **no annotation** (both alert at critical via S01 — already correct from S01).
  - **Verify**: `rg "NOT_ALERTABLE: pending S05" packages/dartclaw_core/lib/src/events/` returns zero hits; `rg "NOT_ALERTABLE:" packages/dartclaw_core/lib/src/events/` count matches the set of `classifyAlert == null` arms (cross-checked against the switch in `alert_classifier.dart`).

- [x] **TI07** Add unit tests:
  - `packages/dartclaw_server/test/alerts/alert_classifier_test.dart` — five new cases for `AdvisorInsightEvent` (statuses `stuck`, `concerning`, `on_track`, `diverging`, plus one malformed e.g. `'unknown_value'`).
  - `packages/dartclaw_server/test/alerts/alert_formatter_test.dart` — one case per alertable status (`stuck` warning body+details; `concerning` critical body+details).
  - `packages/dartclaw_server/test/api/workflow_routes_test.dart` — extend the per-run SSE test harness to fire `MapIterationCompletedEvent` + `MapStepCompletedEvent` and assert the decoded `data:` JSON contains the prescribed keys + correct `type` strings. Use the existing `EventBus` injection at `workflow_routes_test.dart:189-199`.
  - New `packages/dartclaw_server/test/api/event_bus_sse_bridge_test.dart` — for each of the 4 bridged events, fire on a `TestEventBus`, assert `SseBroadcast.broadcast` was called with the matching `eventName` and a payload containing the prescribed keys. Use a thin fake `SseBroadcast` (or capture via a `subscribe()`-derived controller).
  - **Verify**: `dart test packages/dartclaw_server/test/alerts/ packages/dartclaw_server/test/api/` passes; new tests show in the test report; existing tests remain green.

### Testing Strategy

> Derive test cases from the **Scenarios** section. Tag with task ID(s) the test proves.

- [TI03,TI07] Scenario "Happy: Map-iteration completion reaches per-run SSE subscribers" → SSE harness test in `workflow_routes_test.dart`.
- [TI03,TI07] Scenario "Happy: Map-step completion reaches per-run SSE subscribers" → SSE harness test in `workflow_routes_test.dart`.
- [TI01,TI07] Scenario "Happy: Loop detected → critical alert + global SSE broadcast" → bridge test (SSE side) + existing S01 classifier test (alert side).
- [TI01,TI07] Scenario "Happy: Compaction starting paired with completion" → bridge test (asserts ordering when both fire).
- [TI01,TI07] Scenario "Happy: Task review ready bridges to global SSE" → bridge test.
- [TI01,TI07] Scenario "Happy: Emergency stop classified critical AND broadcast" → S01 classifier test (alert side) + manual smoke (imperative SSE path remains, bridge **excludes** this event per § Constraints).
- [TI04,TI05,TI07] Scenario "Happy: AdvisorInsightEvent with `status: on_track` → SSE only, no alert" → classifier test (`null` return) + bridge test (frame emitted).
- [TI04,TI05,TI07] Scenario "Edge: AdvisorInsightEvent with `status: stuck` → warning alert + SSE" → classifier + formatter test (warning body) + bridge test.
- [TI04,TI05,TI07] Scenario "Edge: AdvisorInsightEvent with `status: concerning` → critical alert + SSE" → classifier + formatter test (critical body) + bridge test.
- [TI04,TI07] Scenario "Negative: AdvisorInsightEvent with malformed status string" → classifier test asserting `null` return + no throw + a captured `_log.fine` (use the `Logger.root.onRecord` listener pattern already used in `dartclaw_server/test/`).
- [TI03,TI04,TI05] Scenario "Edge: Compile-time exhaustiveness still enforced" → no committed runtime test (S01 binding #79). Verified via `dart analyze --fatal-warnings --fatal-infos` clean after all S05 edits.

### Validation

- After all task verifies pass: `dart format --set-exit-if-changed packages/dartclaw_server packages/dartclaw_core` clean; `dart analyze --fatal-warnings --fatal-infos packages/dartclaw_server packages/dartclaw_core` clean; `dart test packages/dartclaw_server/test/alerts/ packages/dartclaw_server/test/api/` green.
- Manual end-to-end smoke (optional, post-CI): start dev server, subscribe to `GET /api/events` with `curl -N`, fire a workflow with a `map` step + a forced compaction, observe the new `event: <name>` lines flowing.

### Execution Contract

- Implement tasks in the listed order. Each **Verify** line must pass before proceeding to the next task.
- Prescriptive details (event-name strings, SSE `type` strings, payload keys, dartdoc text, `NOT_ALERTABLE` reasons) are exact — implement them verbatim.
- Proactively use sub-agents for non-coding needs: documentation lookup, build troubleshooting — spawn in background when possible and do not block progress unnecessarily.
- After all tasks: run `dart analyze --fatal-warnings --fatal-infos` and `dart test` across `dartclaw_server` + `dartclaw_core`, plus `rg "TODO|FIXME|placeholder|not.implemented" packages/dartclaw_server/lib/src/api/event_bus_sse_bridge.dart packages/dartclaw_server/lib/src/alerts/` clean.
- Mark task checkboxes immediately upon completion — do not batch.


## Final Validation Checklist

- [x] **All success criteria** met
- [x] **All tasks** fully completed, verified, and checkboxes checked
- [x] **No regressions** — all pre-existing tests in `packages/dartclaw_server/test/alerts/`, `packages/dartclaw_server/test/api/`, and the advisor suite pass with unchanged assertions
- [x] **Analyzer clean** — `dart analyze --fatal-warnings --fatal-infos` clean across `packages/dartclaw_server` and `packages/dartclaw_core`
- [x] **Format clean** — `dart format --set-exit-if-changed` clean across changed files
- [x] **S01 contract preserved** — `classifyAlert` and `AlertFormatter._body`/`_details` remain compile-time exhaustive over `sealed DartclawEvent`; no `default:` branches introduced
- [x] **SSE envelope byte-stable** — existing `type` / `event:` strings unchanged; new event-names are additive (`map_iteration_completed`, `map_step_completed`, `loop_detected`, `task_review_ready`, `advisor_insight`, `compaction_starting`)


## Implementation Observations

> _Managed by exec-spec post-implementation — append-only._

_No observations recorded yet._

---

## Plan-format migration addendum (2026-05-06)

> Migrated from the pre-template `plan.md` story body during the plan-template reformat. Verbatim copy of the plan's `**Acceptance Criteria**`, `**Key Scenarios**`, and any detailed `**Scope**` paragraphs not already represented above. Authoritative spec content lives in this FIS; the plan now carries only a 1-2 sentence Scope summary plus catalog metadata.

### From plan.md — Scope detail (migrated from old plan format)

**Scope**: Wire consumers for all 7 orphan sealed events. (a) `LoopDetectedEvent` — S01 handles classify; add SSE broadcast in the appropriate route. (b) `EmergencyStopEvent` — SSE broadcast + critical alert (via S01's classify path). (c) `TaskReviewReadyEvent` — SSE broadcast (the UI already renders; only the bridge is missing). (d) `AdvisorInsightEvent` — SSE broadcast + `classifyAlert` mapping: warning severity on `status: stuck`, critical on `concerning`, info on `on_track | diverging` (no delivery for info). (e) `CompactionStartingEvent` — SSE broadcast paired with existing `CompactionCompletedEvent`. (f) `MapIterationCompletedEvent` + (g) `MapStepCompletedEvent` — SSE broadcast via `workflow_routes.dart` mirroring existing `LoopIterationCompletedEvent` / `ParallelGroupCompletedEvent` handlers. Excludes: new UI components (SSE only; UI work deferred to Block H stretch if needed).

### From plan.md — Acceptance Criteria addendum (migrated from old plan format)

**Acceptance Criteria**:
- [x] Every one of the 7 listed events has at least one production listener (SSE, alert, or both) (must-be-TRUE)
- [x] Exhaustiveness test from S01 remains green (must-be-TRUE)
- [x] `AdvisorInsightEvent` with `status: stuck` triggers a warning alert; `concerning` triggers critical; `on_track` / `diverging` do not alert (must-be-TRUE)
- [x] `workflow_routes.dart` handles `MapIterationCompletedEvent` and `MapStepCompletedEvent` mirroring sibling events
- [x] Existing SSE envelope format is unchanged (no breaking protocol change)

### From plan.md — Key Scenarios addendum (migrated from old plan format)

**Key Scenarios**:
- Happy: admin runs `/stop` → `EmergencyStopEvent` fires → classified critical → alert delivered + SSE broadcast → dashboard reflects
- Edge: advisor fires with `status: on_track` → SSE broadcast → no alert (info-only path)
- Error: workflow in map-step iteration fires `MapIterationCompletedEvent` → SSE subscribers receive in real time
