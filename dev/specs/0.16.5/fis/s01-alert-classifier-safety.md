# FIS S01: AlertClassifier Safety Fix + Event Exhaustiveness Test

**Plan**: ../plan.md
**Story-ID**: S01

## Feature Overview and Goal

Close the alert-routing safety gap so `LoopDetectedEvent` and `EmergencyStopEvent` produce critical-severity alerts, and convert the `AlertClassifier` and `AlertFormatter` from if-is ladders to exhaustive `switch (event)` expressions over the `sealed DartclawEvent` hierarchy so the analyzer enforces coverage of every subtype at compile time.

> **Technical Research**: [.technical-research.md](./.technical-research.md) _(codebase patterns, event inventory, shared decisions, binding PRD constraints)_


## Required Context

> Cross-doc reference rules: see [`fis-authoring-guidelines.md`](${CLAUDE_PLUGIN_ROOT}/references/fis-authoring-guidelines.md#cross-document-references).

### From `plan.md` — "S01 Scope"
<!-- source: dev/specs/0.16.5/plan.md#p-s01-alertclassifier-safety-fix--event-exhaustiveness-test -->
<!-- extracted: e670c47 -->
> Extend `AlertClassifier.classifyAlert` in `packages/dartclaw_server/lib/src/alerts/alert_classifier.dart` to cover `LoopDetectedEvent` (critical severity) and `EmergencyStopEvent` (critical severity). **Convert the classifier body from the current if-is ladder to an exhaustive `switch (event)` expression** over the `sealed DartclawEvent` hierarchy — the compiler enforces exhaustiveness, eliminating the need for a custom runtime test. Apply the same switch-expression conversion to `AlertFormatter._body`/`_details` in `alert_formatter.dart`. Events that legitimately don't alert use a `// NOT_ALERTABLE: <reason>` annotation on the event class declaration, and the switch returns null for those variants. Excluded: alert body/severity tuning for other events (that's their individual stories).

### From `plan.md` — "S01 Acceptance Criteria"
<!-- source: dev/specs/0.16.5/plan.md#p-s01-alertclassifier-safety-fix--event-exhaustiveness-test -->
<!-- extracted: e670c47 -->
> - `classifyAlert` returns a critical-severity `AlertClassification` for both `LoopDetectedEvent` and `EmergencyStopEvent`
> - `classifyAlert` body is a `switch (event)` expression with one arm per `DartclawEvent` sealed subtype; compiler exhaustiveness applies
> - `AlertFormatter._body` + `_details` use the same exhaustive switch-expression pattern
> - Introducing a new `DartclawEvent` subtype without a switch arm fails compilation (not a runtime test — by design)
> - `NOT_ALERTABLE` annotation comment present on every sealed subtype whose switch arm returns `null`, explaining why no alert

### From `prd.md` — "FR1: Safety & Observability Completeness"
<!-- source: dev/specs/0.16.5/prd.md#fr1-safety--observability-completeness -->
<!-- extracted: e670c47 -->
> **Description**: Every sealed `DartclawEvent` subtype must either be classified by `AlertClassifier` or carry an explicit `NOT_ALERTABLE: reason` annotation, and every event emitted in production must have at least one consumer (alert routing, SSE, direct handler, or metrics subscriber).
>
> **Acceptance Criteria**:
> - `AlertClassifier.classifyAlert` handles `LoopDetectedEvent` (critical) and `EmergencyStopEvent` (critical)
> - `AlertClassifier` + `AlertFormatter` use exhaustive `switch (event)` expressions — compiler enforces coverage of every `sealed DartclawEvent` subtype (no runtime exhaustiveness test needed)
> - Any new `DartclawEvent` subtype without coverage fails `dart analyze` (compile-time, not runtime)
>
> **Error Handling**: Unclassified event causes a non-exhaustive switch diagnostic from the analyzer at the classifier site — build fails with the event class name + file location.

### From `prd.md` — "Decisions Log: switch-over-fitness-test"
<!-- source: dev/specs/0.16.5/prd.md#decisions-log -->
<!-- extracted: e670c47 -->
> Compiler-exhaustive switch over `sealed DartclawEvent` in S01 replaces the originally-planned custom `alertable_events_test.dart` runtime test. Sealed hierarchy + exhaustive `switch` expression gives compiler-enforced coverage with zero runtime cost, better error messages (file:line from the analyzer), and idiomatic Dart 3.x. The custom fitness test was solving a problem the language now solves directly.

### From `prd.md` — "NFR Observability"
<!-- source: dev/specs/0.16.5/prd.md#non-functional-requirements -->
<!-- extracted: e670c47 -->
> Sealed events with production consumers: 100% (every emitted event has at least one listener or documented `NOT_ALERTABLE` justification).


## Deeper Context

- `dev/specs/0.16.5/.technical-research.md#shared-architectural-decisions` — Decision #1 (S01 → S05 sealed-event switch contract), Decision #16 (sealed events / `DartclawEvent`).
- `dev/specs/0.16.5/.technical-research.md#binding-prd-constraints` — rows #6, #7, #9, #74, #79 anchor S01.
- `dev/specs/0.16.5/plan.md#p-s05-wire-7-orphan-sealed-events-sse--alert-mapping` — downstream consumer; S05 adds new arms for the 7 orphan events using the switch-expression baseline produced by S01.


## Success Criteria (Must Be TRUE)

> Each criterion has a proof path (Scenario or Verify line); criterion → upstream source noted in trailing parens.

- [x] `classifyAlert(LoopDetectedEvent)` returns `(alertType: 'loop_detected', severity: AlertSeverity.critical)` (plan AC #1, PRD FR1, binding #6)
- [x] `classifyAlert(EmergencyStopEvent)` returns `(alertType: 'emergency_stop', severity: AlertSeverity.critical)` (plan AC #1, PRD FR1, binding #6)
- [x] `classifyAlert` body is a single `switch (event)` expression with one arm per concrete `DartclawEvent` subtype reachable from the sealed root (plan AC #2, PRD FR1, binding #7)
- [x] `AlertFormatter._body` and `AlertFormatter._details` are `switch (event)` expressions over `DartclawEvent` with one arm per concrete subtype (plan AC #3, PRD FR1, binding #7)
- [x] Adding a new `DartclawEvent` subtype without a switch arm at any of the three sites causes `dart analyze --fatal-warnings --fatal-infos` to fail with `non_exhaustive_switch_expression` naming the missing subtype (plan AC #4, PRD FR1, binding #9, #79)
- [x] Every concrete `DartclawEvent` subtype whose `classifyAlert` arm returns `null` carries a `// NOT_ALERTABLE: <reason>` comment immediately above the class declaration in `packages/dartclaw_core/lib/src/events/*_events.dart` (plan AC #5, binding #74)

### Health Metrics (Must NOT Regress)

- [x] All existing `alert_classifier_test.dart` and `alert_formatter_test.dart` cases still pass with unchanged assertions (the seven currently-mapped events return identical `(alertType, severity)` tuples and identical formatted bodies/details).
- [x] SSE envelope format unchanged — no `alert_*` envelope schema changes; this story does NOT wire the new events into SSE (that's S05).
- [x] Workspace-wide `strict-casts` + `strict-raw-types` remain on; `dart analyze --fatal-warnings --fatal-infos` is clean (binding #3, #73).
- [x] No new package dependencies added to any pubspec (binding #2).


## Scenarios

### Happy: Emergency stop classified as critical
- **Given** an `EmergencyStopEvent(stoppedBy: 'admin', turnsCancelled: 2, tasksCancelled: 1, timestamp: ...)` fires on the `EventBus`
- **When** `AlertRouter` calls `classifyAlert(event)`
- **Then** the call returns `(alertType: 'emergency_stop', severity: AlertSeverity.critical)` and the event is delivered to the configured alert target

### Happy: Loop detected classified as critical
- **Given** the loop detector fires `LoopDetectedEvent(sessionId: 'sess-1', mechanism: 'turnChainDepth', message: '…', action: 'abort', timestamp: ...)`
- **When** `classifyAlert(event)` runs
- **Then** the return value is `(alertType: 'loop_detected', severity: AlertSeverity.critical)`

### Edge: Compiler enforces coverage on new subtype
- **Given** a hypothetical new `final class FooSafetyEvent extends DartclawEvent { … }` is added to `packages/dartclaw_core/lib/src/events/governance_events.dart` without updating `classifyAlert`, `AlertFormatter._body`, or `AlertFormatter._details`
- **When** the developer runs `dart analyze --fatal-warnings --fatal-infos packages/dartclaw_server`
- **Then** the analyzer reports a `non_exhaustive_switch_expression` diagnostic at each of the three switch sites naming `FooSafetyEvent` and the build exits non-zero

### Edge: Non-alertable subtype returns null with documented rationale
- **Given** a sealed subtype carries a `// NOT_ALERTABLE: <reason>` annotation on its class declaration (e.g. `WorkflowCliTurnProgressEvent` — purely UI progress, no operator-actionable signal)
- **When** `classifyAlert(event)` is called with that subtype
- **Then** the corresponding switch arm returns `null` and no alert is dispatched, matching the comment

### Error: Severity verification for the two new safety events
- **Given** representative instances of `LoopDetectedEvent` and `EmergencyStopEvent`
- **When** `AlertFormatter.format(...)` runs with each event
- **Then** the formatted plain text begins with `[CRITICAL]` and the body string contains the event's identifying fields (session id / mechanism for loop, stoppedBy / turnsCancelled / tasksCancelled for emergency stop)


## Scope & Boundaries

### In Scope

- Add `LoopDetectedEvent` and `EmergencyStopEvent` arms to `classifyAlert` returning critical severity with stable `alertType` strings (`loop_detected`, `emergency_stop`).
- Convert `classifyAlert` from if-is ladder to a `switch (event)` expression with one arm per concrete `DartclawEvent` subtype.
- Convert `AlertFormatter._body` and `AlertFormatter._details` to `switch (event)` expressions with one arm per concrete `DartclawEvent` subtype.
- Add `// NOT_ALERTABLE: <reason>` comments to every `DartclawEvent` subtype whose classifier arm returns `null`, on the class declaration in `packages/dartclaw_core/lib/src/events/*_events.dart`.
- Extend `alert_classifier_test.dart` (and `alert_formatter_test.dart` where it asserts body/details for the new events) with positive coverage for the two new safety events.

### What We're NOT Doing

- Alert body/severity tuning for non-safety events (e.g. `AdvisorInsightEvent` severity-by-status logic) — those land with their owning stories (S05 wires the seven orphan events).
- SSE wiring for orphan events — that is S05's responsibility; S01 only fixes classification + formatter completeness.
- Creating a runtime `alertable_events_test.dart` fitness test — explicitly superseded by the compiler-enforced switch (Decisions Log row, binding #79). S10 ships the L1 fitness suite without this file.
- Renaming or restructuring the existing seven mapped events (`guard_block`, `container_crash`, `task_failure`, `job_failure`, `budget_warning`, `compaction`) — their `alertType` strings stay byte-stable for SSE/log compatibility.
- Changing `shouldAlertTaskFailure(...)` channel-suppression logic — out of scope; behaviour preserved verbatim.


## Architecture Decision

**We will**: replace the if-is ladder in `AlertClassifier.classifyAlert` and `AlertFormatter._body`/`_details` with exhaustive `switch (event)` expressions over `sealed DartclawEvent` — compiler enforces coverage of every subtype with zero runtime cost (over a custom runtime fitness test which adds maintenance burden for no extra correctness vs. the compiler).

See plan Decisions Log row "Compiler-exhaustive switch over `sealed DartclawEvent` in S01 replaces the originally-planned custom `alertable_events_test.dart` runtime test" (`prd.md#decisions-log`) and shared decision #1 in `.technical-research.md`.


## Technical Overview

### Data Models

`DartclawEvent` is `sealed` (`packages/dartclaw_core/lib/src/events/dartclaw_event.dart:23`) with `part` files declaring intermediate `sealed` lifecycle classes (`AgentLifecycleEvent`, `AgentExecutionEvent`, `CompactionLifecycleEvent`, `ContainerLifecycleEvent`, `ProjectLifecycleEvent`, `SessionLifecycleEvent`, `TaskLifecycleEvent`, `WorkflowLifecycleEvent`) and concrete `final class` leaves directly under `DartclawEvent` (`LoopDetectedEvent`, `EmergencyStopEvent`, `GuardBlockEvent`, `ToolPermissionDeniedEvent`, `ConfigChangedEvent`, `FailedAuthEvent`, `ScheduledJobFailedEvent`, `AdvisorMentionEvent`, `AdvisorInsightEvent`, `WorkflowCliTurnProgressEvent`). Pattern-matching switches over `DartclawEvent` must enumerate one arm per concrete leaf (Dart 3 exhaustiveness flattens through intermediate sealed classes). Authoritative inventory: see grep results in `.technical-research.md` and the `lib/src/events/*_events.dart` files.

### Integration Points

- **Producer**: `EventBus.fire` in `packages/dartclaw_core/lib/src/events/event_bus.dart`.
- **Consumer (this story)**: `AlertRouter` (`packages/dartclaw_server/lib/src/alerts/alert_router.dart`) calls `classifyAlert(event)`; on non-null verdict, hands off to `AlertFormatter.format(...)` then to delivery adapter.
- **Downstream coupling (S05)**: S05 adds new arms for the orphan events (severity-by-status for `AdvisorInsightEvent`, `null` + `NOT_ALERTABLE` for the rest) on top of S01's switch baseline.


## Code Patterns & External References

```
# type | path/url                                                                              | why needed
file   | packages/dartclaw_server/lib/src/alerts/alert_classifier.dart:20-43                   | Current if-is ladder; convert to switch expression
file   | packages/dartclaw_server/lib/src/alerts/alert_formatter.dart:82-131                   | Current _body + _details if-is ladders; convert to switch expressions
file   | packages/dartclaw_server/lib/src/alerts/alert_formatter.dart:72-80                    | Existing switch expression on String alertType; reference style
file   | packages/dartclaw_core/lib/src/events/dartclaw_event.dart:23                          | sealed DartclawEvent root; part-file declarations follow
file   | packages/dartclaw_core/lib/src/events/governance_events.dart:4,39                     | LoopDetectedEvent + EmergencyStopEvent definitions
file   | packages/dartclaw_core/lib/src/events/auth_events.dart:39-99                          | GuardBlockEvent reference for AlertClassification shape
file   | packages/dartclaw_server/test/alerts/alert_classifier_test.dart:13-72                 | Existing test pattern to extend
file   | packages/dartclaw_server/test/alerts/alert_formatter_test.dart                        | Formatter test patterns for body/details assertions
url    | https://dart.dev/language/patterns#exhaustiveness-checking                            | Dart 3 sealed-class switch exhaustiveness rules
```


## Constraints & Gotchas

- **Constraint**: Workspace-wide `strict-casts` + `strict-raw-types` must remain on; `dart analyze --fatal-warnings --fatal-infos` clean (binding #3, #73). Each switch arm must use proper pattern syntax (`LoopDetectedEvent()` or `LoopDetectedEvent(:final sessionId, …)`) — not `case final LoopDetectedEvent e:` if it requires a downcast.
- **Constraint**: SSE envelope format unchanged (binding #1) — `alertType` strings for the seven existing events stay byte-stable (`guard_block`, `container_crash`, `task_failure`, `job_failure`, `budget_warning`, `compaction`); the new strings (`loop_detected`, `emergency_stop`) are additive.
- **Avoid**: Adding a runtime `alertable_events_test.dart` fitness test — explicitly out of scope (binding #79; S10 explicitly drops it). The compiler is the proof.
- **Avoid**: Adding `default:` branches to the new switch expressions — would defeat exhaustiveness enforcement. If a future subtype legitimately doesn't alert, add a named arm returning `null` and a `// NOT_ALERTABLE: …` annotation on its class declaration instead.
- **Avoid**: Pattern-matching on intermediate `sealed` lifecycle classes (e.g. `WorkflowLifecycleEvent`) instead of concrete leaves — the analyzer accepts it, but it suppresses the future-proofing signal we want when a new leaf is added.
- **Critical**: `_details` currently returns `null` for several events that *do* classify (e.g. `ContainerCrashedEvent`, `CompactionCompletedEvent`). Preserve that by giving those arms a `null` return and an `// alert: <reason no details>` inline comment (NOT `NOT_ALERTABLE` — those events DO alert, they just have no extra details). Reserve `NOT_ALERTABLE: <reason>` strictly for class declarations of subtypes whose `classifyAlert` arm returns `null`.
- **Critical**: `TaskStatusChangedEvent` only alerts on `newStatus == TaskStatus.failed`. Encode this in the switch arm via a `when` guard or destructuring pattern, e.g. `TaskStatusChangedEvent(newStatus: TaskStatus.failed) => (...)`, with a separate fall-through arm for non-failed statuses returning `null`.
- **Critical**: `AlertFormatter` currently calls `event.toString()` as fallback at `_body` line 108. Removing the fallback and exhausting the switch is mandatory; reuse the existing per-event format strings verbatim for the seven mapped events to keep tests green.
- **Critical**: When adding a `// NOT_ALERTABLE: <reason>` annotation, the comment lives on the **class declaration** in `dartclaw_core` (so it travels with the type), not at the classifier arm site (the arm itself just returns `null`). The `// NOT_ALERTABLE` text becomes the canonical "documented `NOT_ALERTABLE` justification" required by NFR Observability (binding #74).
- **Gotcha (autonomous decision)**: For `AdvisorInsightEvent`, `AdvisorMentionEvent`, `WorkflowCliTurnProgressEvent`, and the other orphan events that S05 will eventually wire — S01 lands their arms returning `null` with `NOT_ALERTABLE: pending S05 — wired to SSE only / status-driven alert added in S05`. S05 then flips those arms to non-null verdicts and removes / updates the `NOT_ALERTABLE` annotation as appropriate.


## Implementation Plan

> **Vertical slice ordering**: Land the compiler-fix on `classifyAlert` first (the smallest end-to-end demonstration of the new pattern), then widen to `AlertFormatter`, then the `NOT_ALERTABLE` annotations and tests.

### Implementation Tasks

- [x] **TI01** `classifyAlert` is a `switch (event)` expression with one arm per concrete `DartclawEvent` subtype; the seven existing mappings preserve byte-identical `(alertType, severity)` tuples; new arms for `LoopDetectedEvent` → `(loop_detected, critical)` and `EmergencyStopEvent` → `(emergency_stop, critical)`. Subtypes not yet alertable return `null`. No `default:` branch.
  - Reference current ladder at `alert_classifier.dart:20-43`. Use destructuring pattern to encode the `TaskStatusChangedEvent(newStatus: TaskStatus.failed)` guard. Keep dartdoc updated to list all alerting arms.
  - **Verify**: `dart analyze --fatal-warnings --fatal-infos packages/dartclaw_server` is clean; `dart test packages/dartclaw_server/test/alerts/alert_classifier_test.dart` passes; manual inspection of `classifyAlert` shows `switch (event)` with one arm per concrete leaf and no `default:`.

- [x] **TI02** `AlertFormatter._body` is a `switch (event)` expression with one arm per concrete `DartclawEvent` subtype; the existing seven body strings are byte-identical for the currently-mapped events; new arms for `LoopDetectedEvent` and `EmergencyStopEvent` produce human-readable bodies including their identifying fields (e.g. `'Loop detected in session ${sessionId} (mechanism: ${mechanism}, action: ${action})'`, `'Emergency stop by ${stoppedBy} — ${turnsCancelled} turn(s), ${tasksCancelled} task(s) cancelled'`). No `default:` branch and no `event.toString()` fallback.
  - Reference current ladder at `alert_formatter.dart:82-109`. The function returns `String` so each arm yields a string; non-alerting subtypes still need an arm — return a placeholder (e.g. `event.runtimeType.toString()`) since `_body` is only invoked when `classifyAlert` returned non-null, but the analyzer needs the arm to exist.
  - **Verify**: `dart test packages/dartclaw_server/test/alerts/alert_formatter_test.dart` passes; `dart analyze --fatal-warnings --fatal-infos packages/dartclaw_server` clean; the seven existing format strings unchanged (assert via existing tests).

- [x] **TI03** `AlertFormatter._details` is a `switch (event)` expression with one arm per concrete `DartclawEvent` subtype, returning `Map<String, String>?`. The existing six non-null detail maps are byte-identical; new arms for `LoopDetectedEvent` (`{'Session': sessionId, 'Mechanism': mechanism, 'Action': action}`) and `EmergencyStopEvent` (`{'Stopped by': stoppedBy, 'Turns cancelled': '$turnsCancelled', 'Tasks cancelled': '$tasksCancelled'}`) added; subtypes without details return `null`. No `default:` branch.
  - Reference current ladder at `alert_formatter.dart:111-131`.
  - **Verify**: `dart test packages/dartclaw_server/test/alerts/alert_formatter_test.dart` passes (existing detail-map assertions unchanged); new tests for the two safety events assert the prescribed key names.

- [x] **TI04** Every concrete `DartclawEvent` subtype whose `classifyAlert` arm returns `null` carries a `// NOT_ALERTABLE: <reason>` comment immediately above the class declaration in its `packages/dartclaw_core/lib/src/events/<group>_events.dart` file. Reasons are concise (≤80 chars) and reflect the actual rationale (e.g. `// NOT_ALERTABLE: lifecycle telemetry — surfaced via SSE only`, `// NOT_ALERTABLE: pending S05 — status-driven alert added by S05`).
  - Subtypes that DO alert (the seven in the dartdoc table at `alert_classifier.dart:12-19`, plus `LoopDetectedEvent` + `EmergencyStopEvent` from TI01) get NO annotation. Reference the comment-policy "Anti-rot rules" — the annotation is durable rationale, not narration.
  - **Verify**: `rg "NOT_ALERTABLE:" packages/dartclaw_core/lib/src/events/` lists one annotation per non-alerting concrete subtype; cross-check by running `rg -B1 "^final class .* extends (Dartclaw|.*Lifecycle|AgentExecution)Event" packages/dartclaw_core/lib/src/events/ | rg -A1 "class "` against the subtypes that return `null` from `classifyAlert`. Counts match.

- [x] **TI05** `alert_classifier_test.dart` covers the two new safety events with positive assertions: `LoopDetectedEvent` → `(alertType: 'loop_detected', severity: AlertSeverity.critical)`; `EmergencyStopEvent` → `(alertType: 'emergency_stop', severity: AlertSeverity.critical)`. Existing test cases remain untouched.
  - Reference test pattern at `alert_classifier_test.dart:13-72`. Include the constructors used in the test data — `LoopDetectedEvent(sessionId, mechanism, message, action, detail?, timestamp)` and `EmergencyStopEvent(stoppedBy, turnsCancelled, tasksCancelled, timestamp)` — verbatim from `governance_events.dart:25-32,54-58`.
  - **Verify**: `dart test packages/dartclaw_server/test/alerts/alert_classifier_test.dart` passes; the two new test names appear in the test report.

- [x] **TI06** `alert_formatter_test.dart` asserts body and detail content for the two new safety events: body strings include the event's identifying fields verbatim, severity prefix `[CRITICAL]` is present in the plain-text format, and details map keys match TI03 verbatim.
  - **Verify**: `dart test packages/dartclaw_server/test/alerts/alert_formatter_test.dart` passes; the new tests assert literal body substrings and detail-map keys (`'Session'`, `'Mechanism'`, `'Action'`, `'Stopped by'`, `'Turns cancelled'`, `'Tasks cancelled'`) verbatim.

- [x] **TI07** Compile-time exhaustiveness is demonstrated. Manual proof: temporarily add a stub `final class _ProofEvent extends DartclawEvent { @override DateTime get timestamp => throw 0; }` to `governance_events.dart`, run `dart analyze --fatal-warnings --fatal-infos packages/dartclaw_server`, confirm `non_exhaustive_switch_expression` diagnostics fire at the three switch sites naming `_ProofEvent`, then revert. (No committed runtime test — by design per binding #79.)
  - This task is a one-off verification, not a commit. The `Verify` line is the reproducible analyzer output.
  - **Verify**: With stub event added, `dart analyze packages/dartclaw_server 2>&1 | rg non_exhaustive_switch_expression` lists three hits referencing `alert_classifier.dart` and `alert_formatter.dart` (twice for `_body` and `_details`). Stub then removed; analyzer clean.

### Testing Strategy

> Derive test cases from the **Scenarios** section. Tag with task ID(s) the test proves.

- [TI01,TI05] Scenario "Happy: Emergency stop classified as critical" → unit test `EmergencyStopEvent → emergency_stop / critical`.
- [TI01,TI05] Scenario "Happy: Loop detected classified as critical" → unit test `LoopDetectedEvent → loop_detected / critical`.
- [TI01,TI02,TI03,TI07] Scenario "Edge: Compiler enforces coverage on new subtype" → manual analyzer-output check in TI07; not a committed runtime test (per binding #79).
- [TI04] Scenario "Edge: Non-alertable subtype returns null with documented rationale" → grep verification in TI04 that every `classifyAlert == null` arm has a `// NOT_ALERTABLE:` comment on its class declaration.
- [TI02,TI03,TI06] Scenario "Error: Severity verification for the two new safety events" → formatter tests assert `[CRITICAL]` prefix and body/detail content.

### Validation

- After all task verifies pass, run `dart format --set-exit-if-changed packages/dartclaw_server packages/dartclaw_core` to confirm format gate clean (S10 dependency).

### Execution Contract

- Implement tasks in listed order. Each **Verify** line must pass before proceeding to the next task.
- Prescriptive details (column names, format strings, file paths, error messages) are exact — implement them verbatim.
- Proactively use sub-agents for non-coding needs: documentation lookup, architectural advice, build troubleshooting — spawn in background when possible and do not block progress unnecessarily.
- After all tasks: run `dart analyze --fatal-warnings --fatal-infos packages/dartclaw_server packages/dartclaw_core` and `dart test packages/dartclaw_server/test/alerts/`, plus `rg "TODO|FIXME|placeholder|not.implemented" packages/dartclaw_server/lib/src/alerts/ packages/dartclaw_core/lib/src/events/` clean.
- Mark task checkboxes immediately upon completion — do not batch.


## Final Validation Checklist

- [x] **All success criteria** met
- [x] **All tasks** fully completed, verified, and checkboxes checked
- [x] **No regressions** — all pre-existing tests in `packages/dartclaw_server/test/alerts/` pass with unchanged assertions
- [x] **Analyzer clean** — `dart analyze --fatal-warnings --fatal-infos` clean across `packages/dartclaw_server` and `packages/dartclaw_core`
- [x] **Format clean** — `dart format --set-exit-if-changed` clean across changed files


## Implementation Observations

> _Managed by exec-spec post-implementation — append-only._

_No observations recorded yet._
