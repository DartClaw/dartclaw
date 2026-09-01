# ADR-057: Workflow Events Stay in the Sealed `DartclawEvent` Library

## Status

Accepted — 2026-08-19 (0.25 planning; owner ruling of that date, recorded as D3 in the milestone plan). This ADR records a **refusal**: a proposed package-boundary
correction is declined and the current placement is ratified. The decision is accepted; the *proposal* it evaluates is
rejected.

**Related:** [ADR-034](034-enforced-package-dependency-direction.md) (dependency direction — the principle the rejected
proposal invoked), [ADR-033](033-architectural-governance-via-fitness-functions.md) (the fitness mechanism that carries
part of the property preserved here), [ADR-011](011-event-driven-architecture.md) (the event bus this hierarchy feeds),
[ADR-053](053-subscription-default-provider-authentication.md) (credential-health alerting — the live producer whose
classification the preserved exhaustiveness protects), [ADR-010](010-package-split-models.md) /
[ADR-020](020-package-decomposition-phase-2.md) (packaging baseline).

## Context

`packages/dartclaw_core/lib/src/events/workflow_events.dart` holds 14 workflow event classes (884 lines) in
`dartclaw_core`, the package every non-workflow deployment depends on. Nothing inside `dartclaw_core` references them:
producers are in `dartclaw_workflow`, consumers in `dartclaw_server` and `apps/dartclaw_cli`. On a dependency-graph
reading this is a misplacement with an obvious fix, and three planning documents recorded it as one:

- 0.25's workflow package review (`package-review/workflow.md` § S5 and § 7 note 1) — *"Pure move; risk: low"*, on the
  stated grounds that *"Dependency direction already permits it (workflow → core, never the reverse)"*.
- The 0.25 PRD FR11 — *"`workflow_events.dart` moves from `dartclaw_core` to `dartclaw_workflow`"*, summarised as
  *"workflow events leave core"*.
- The same reasoning generalised in `package-review/core.md` § 4.2 to all 13 event payload files, *"~1,300 LOC to move"*.

**All three claims are false, and the reasoning error behind them is worth naming.** The audit checked the *package*
dependency graph and concluded the move was mechanical. The blocking constraint is not in the package graph; it is in
the **library** graph. `dartclaw_event.dart` declares `sealed class DartclawEvent`, and all 15 payload files —
`workflow_events.dart` among them — are `part of 'dartclaw_event.dart'`. Sixteen files, one library. Dart scopes
`sealed` to the library, so a subtype declared in another package is a different library and fails to compile with
`invalid_use_of_type_outside_library`. Verified empirically on Dart 3.13.0 with a scratch two-package probe; the
workspace pins `sdk: ^3.13.0`. Package boundaries and library boundaries are different things, and the audit's check
answered the wrong question.

That leaves exactly one way to perform the move: unseal `DartclawEvent`. Unsealing has a cost that is invisible at the
diff and visible only in a future incident.

`classifyAlert` in `packages/dartclaw_server/lib/src/alerts/alert_classifier.dart` is a **wildcard-free exhaustive
switch over the whole hierarchy** — every event type in the hierarchy is named, either mapped to an alert type and
severity or explicitly returned as `null`. `AlertFormatter._body` and `_details` carry the same shape today. Because the
switch has no `_ =>` arm, the compiler refuses to build when a new event type is added without an explicit decision
about it. Sealedness is what makes that refusal possible.

Unseal the base and every one of those switches silently becomes non-exhaustive-but-legal: it needs a default arm, and
the invariant degrades from *"a new event must be classified"* to *"a new event is not an alert"*. There is no compile
error, no test failure, and no log line — a future credential-health or container-crash event simply never reaches an
operator. That trades a real compile-time safety property for package-hygiene purity, which the 0.25 binding constraint
`Owner-2026-08-19` forbids: *"it's very important we don't introduce regressions here, unless it was a clear decision
made at the beginning of planning for this milestone."* This was not such a decision — it was an audit inference that
did not survive verification.

The property is being deliberately **concentrated**, not retired, in the same milestone. The alerts re-cut moves body
and detail content into the classification result and leaves `AlertFormatter` with no event switch at all, so
`alert_classifier.dart` becomes the single wildcard-free consumer of the sealed base and the sole `DartclawEvent` target
of `dev/fitness/test/enum_exhaustive_consumer_test.dart`. Unsealing would remove the compiler
guarantee from precisely the seam the milestone is investing in.

### Decision drivers

- **No silent regressions.** A change whose failure mode is an alert that never fires is worse than the layering flaw it
  fixes.
- **Package hygiene is a means, not an end.** `dartclaw_core` carrying 884 unreferenced lines is a real but bounded
  cost: no runtime overhead, no correctness risk, no consumer confusion — the barrel already exports them.
- **The constraint is a language property, not a code smell.** No amount of restructuring inside the current toolchain
  removes it; a workaround would be evasion, not a fix.
- **Refusals must be recorded.** An unrecorded refusal is re-proposed. This claim has already survived one PRD and two
  package reviews.

## Decision

**The `DartclawEvent` part-chain stays whole in `dartclaw_core`, and `DartclawEvent` stays `sealed`.**

- `packages/dartclaw_core/lib/src/events/workflow_events.dart` does not move to `dartclaw_workflow`, in this milestone
  or by default in any later one. The same holds for the other 14 payload files in the part-chain
  (`package-review/core.md` § 4.2's "~1,300 LOC to move" is declined on identical grounds).
- `DartclawEvent` is not unsealed, and is not split into a public non-sealed interface plus a sealed internal base.
- No exhaustive switch over `DartclawEvent` acquires a `_ =>` wildcard arm as part of a placement change. Consumers may
  stop switching on the base type entirely (the alerts re-cut does exactly that); what is forbidden is keeping the
  switch and defaulting it.
- The 0.25 PRD's FR11 clause and the two package-review claims are **withdrawn as false**, not deferred. "Pure move,
  low risk" is not a characterisation to carry into a later milestone.

This is a placement decision only. It sanctions nothing about the *contents* of the file: deleting unreachable
`fromJson` factories, retiring event types with no producer, or removing a payload file wholesale (0.25 deletes
`advisor_events.dart`) are all compatible with the part-chain and are governed by their own stories.

### What would make the move viable later

Re-open this ADR only when one of these is true and demonstrated — not on the strength of the layering argument alone,
which was already known and is not sufficient:

1. **Dart gains cross-library sealed extension.** A language mechanism that lets a sealed hierarchy admit subtypes from
   a declared set of libraries would remove the constraint outright. Re-check against the SDK in use, not against this
   ADR's Dart 3.13.0 baseline.
2. **Exhaustiveness stops depending on sealedness.** `enum_exhaustive_consumer_test.dart` is a source-parsing fitness
   check over a hand-maintained value list. If it is reworked to derive the subtype set from the hierarchy itself and is
   *proven* to fail on an unhandled subtype without compiler help, the compile-time guarantee has a substitute and
   unsealing costs nothing. The proof is the gate: a fitness test that has to be updated by hand to notice a new event
   is not a substitute.
3. **The workflow subsystem leaves the runtime.** If workflow ships as a separate binary or package tier
   (`package-review/workflow.md` § 7 note 3), its events leave with the whole subsystem and no core-side consumer needs
   to name them — the placement question dissolves rather than being solved.

## Consequences

### Positive

- `classifyAlert`'s compile-time guarantee survives: a new `DartclawEvent` cannot reach production without a conscious
  alertable/not-alertable decision, backed by the compiler rather than by review attention.
- The SSE wire type strings (`workflow_status_changed`, `workflow_step_completed`, `parallel_group_completed`,
  `workflow_budget_warning`, `loop_iteration_completed`, `map_iteration_completed`, `map_step_completed`,
  `approval_requested`, `approval_resolved`, `workflow_serialization_enacted`, `step_skipped` — the two approval
  strings are also accepted on input under `workflow_`-prefixed aliases) and the
  `WorkflowLifecycleEvent.fromJson` dispatch are untouched, so the server↔web-UI contract carries no risk from this
  question at all.
- Every consumer of these types across `packages/` and `apps/` needs no rebinding, and 0.25 sheds a high-risk story
  from its critical path without losing a Must/P0 capability.
- The refusal is recorded with its evidence, so the next audit that reaches the same conclusion from the same
  dependency-graph reading meets a written answer.

### Negative

- `dartclaw_core` keeps 884 lines of workflow-shaped types it never uses, and the layering complaint stands unaddressed.
  Every deployment that does not run workflows still compiles them.
- The `dartclaw_event.dart` part-chain remains one single library spanning `dartclaw_event.dart` and its payload
  files; adding an event means editing a file in core regardless of which package owns the concept.
- 0.25's FR11 acceptance criterion is delivered incomplete by one clause. The clause is withdrawn rather than failed,
  and no success metric moves: the proposal was LOC-neutral (a move, not a deletion).

## Alternatives Considered

1. **Unseal `DartclawEvent` and move the file** — rejected. This is the only mechanism that makes the move compile, and
   it is the one that costs the safety property. Every wildcard-free switch over the base degrades to needing a default
   arm, converting "a new event must be classified" into "a new event is not an alert", with no compile error and no
   test failure at the moment of loss. Forbidden by binding constraint `Owner-2026-08-19`.
2. **Move the whole `DartclawEvent` library to `dartclaw_workflow`** — rejected. Inverts the dependency graph. Core,
   server, storage and the three channel packages all produce and consume non-workflow events; the base type must sit at
   or below core (ADR-034).
3. **Split the base into a non-sealed public interface plus a sealed core-internal class** — rejected. The exhaustive
   consumers would switch on the interface, which is exactly the un-exhaustive type; the property is surrendered under a
   different name while the type surface for 14 classes doubles.
4. **Wrap workflow events in one core-owned envelope carrying an opaque workflow-package payload** — rejected. Fourteen
   typed classes collapse into one envelope, `fromJson` dispatch and the wire strings move behind a `Map`, and
   `classifyAlert` loses the ability to name `WorkflowBudgetWarningEvent` as alertable. That is the untyped-map
   anti-pattern 0.25 is removing elsewhere, reintroduced to satisfy a layering preference.
5. **Keep the story and defer it to a later milestone** — rejected. Deferral preserves the false "pure move, low risk"
   framing and guarantees the question is re-litigated from the same wrong premise. The constraint is a language
   property, so the answer does not improve with time; only the three named triggers change it.

## References

- `packages/dartclaw_core/lib/src/events/dartclaw_event.dart` — `sealed class DartclawEvent` and the 15 `part`
  directives that make the hierarchy one library.
- `packages/dartclaw_core/lib/src/events/workflow_events.dart` — `part of 'dartclaw_event.dart'`; the 14 classes and
  their wire type strings.
- `packages/dartclaw_server/lib/src/alerts/alert_classifier.dart#classifyAlert` — the wildcard-free exhaustive switch
  this decision preserves.
- `dev/fitness/test/enum_exhaustive_consumer_test.dart` — the `DartclawEvent` exhaustive-consumer
  fitness target (ADR-033).
- Dart 3.13.0 (workspace `sdk: ^3.13.0`); `invalid_use_of_type_outside_library` reproduced with a two-package probe,
  2026-08-19.
