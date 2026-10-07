# FIS: Request changes at approval gates

**Plan**: dev/bundle/docs/specs/0.28/plan.json
**Story-ID**: S07

## Feature Overview and Goal

**Intent**: A reviewer who finds a weak plan should say what is wrong and get it revised, from wherever the run is being watched, instead of rejecting the run and losing every step completed before the gate.

**Expected Outcomes**:

- [OC01] An admin asks for changes at a gate that names a revise step, from the run page, HTTP, an agent tool, a Slack modal or a Google Chat dialog; the run re-runs that step with the feedback, runs the steps after it, and pauses at the same gate again, bounded by `maxRevisions`.
- [OC02] The request is one more resolution through story S06's single owner and admin gate: refused when the sender is not an admin, the feedback is empty, the post is stale or the limit is reached; audited once per round; the old post edited and the new post live.
- [OC03] The owner starts `plan-and-implement` with one variable set and reviews the plan before any story is implemented; unset, the workflow is unchanged.


## Required Context

- `docs/specs/0.28/prd.md#fr11-request-changes-at-approval-gates` – acceptance criteria, validation and error handling; `#user-stories` US13 and US14, `#user-flows` flow 7, `#edge-cases` the three request-changes rows, `#decisions-log` owner D20 and D25.
- `docs/research/humanlayer-2026-10/research.md` – H2 (the outcome) and H3 item 1 (the plan gate).
- `docs/specs/0.28/s06-run-approvals-from-chat.md` – the interaction record and nonce, expectation-and-resolver `resume`/`cancel` under one per-run serialized section, `WorkflowRunControl`, `ChannelRunApprovalHandler`, the subscriber's post and edit, Slack and Google Chat click parsing. Request changes is a third action through each, never a second path.
- `docs/specs/0.28/s05-threaded-channels-and-run-lifecycle-posts.md` – the run subscriber, awaiting-approval post, `ChannelNotification` action data.
- `docs/specs/0.28/s02-slack-events-api-setup-and-diagnostics.md` – its "What We're NOT Doing" hands `view_submission` acknowledgement bodies to this story; `docs/specs/0.28/s01-slack-adapter-over-socket-mode.md` SC03 for the envelope dispatch.
- `docs/research/slack-threaded-runs-0.28/recommendation.md#f3-distinct-port-shared-run-authority` – ownership split.
- `docs/guide/workflows-reference.md` (public) § `approval` Steps – today's semantics: reject cancels, feedback recorded and never consumed.


## Acceptance Scenarios

- **S01 [OC01] Request changes re-runs the revise step with the feedback and returns to the same gate**
  - **Given** a run whose steps are `prep`, `draft` (with an `entryGate` that is false now), `review-gate` (`revise: draft`, default bound) and `ship`, completed through `draft` and paused at the gate, and an admin's feedback "split story 3"
  - **When** the feedback is submitted as request changes
  - **Then** the gate's approval status is `changes_requested` with the feedback and revision 1 recorded, one `WorkflowApprovalResolvedEvent` carries the changes-requested outcome with revision 1 of 3, and the run runs again from `draft`: `prep` does not re-run, `draft` runs although its `entryGate` is false, and its prompt carries the feedback verbatim; the run then pauses at `review-gate` again with approval status `pending`, a new `WorkflowApprovalRequestedEvent`, and an Approve that continues to `ship`

- **S02 [OC01] A failing or interrupted revision keeps its feedback**
  - **Given** a revision round in flight whose revise step fails under `onFailure: fail`, and another interrupted by a server restart over the same stores
  - **When** the first run is retried and the second is recovered
  - **Then** the failed run posts as any failure and never reaches the gate; each run re-runs the revise step with the same feedback despite its `entryGate`, then returns to the gate with revision count unchanged

- **S03 [OC01] The validator refuses a revise step that cannot be re-entered**
  - **Given** gates whose `revise` names a later step, the gate itself, an unknown step, an approval step, a step inside a `foreach`, a loop or a parallel group, or a gate itself inside one of those; and `maxRevisions` of 0, 11, or set with no `revise`
  - **When** each definition validates, and a valid one omits `maxRevisions`
  - **Then** each invalid case errors naming step and fix, `revise` and `maxRevisions` are refused on non-approval steps at parse time, the valid gate loads with the effective bound 3, and the built-in definitions' report golden stays clean

- **S04 [OC01,OC02] Empty feedback and a gate with no revise step are refused on every surface**
  - **Given** an admin and a live gate that names a revise step, and a live gate that names none (and a `needsInput` hold)
  - **When** request changes arrives with whitespace-only feedback through the workflow owner, HTTP, the tool, the Slack submission and the Google Chat submission, and with feedback at the gate that names no revise step
  - **Then** each is refused with its surface's refusal (HTTP 400 for empty and 409 for the gate; tool refusal text; Slack inline error on the feedback field; Google Chat dialog status message), the run, the nonce and the revision count are unchanged, the gate's post and page carry no Request changes action, and no refusal consumes the nonce

- **S05 [OC01,OC02] At the bound the gate offers only Approve and Reject and says why**
  - **Given** a gate with `maxRevisions: 2` returned to after two rounds
  - **When** its awaiting-approval post, run page and `workflow_status` are produced, and an admin requests changes anyway by HTTP, by tool and by a modal opened on the previous round's post
  - **Then** the post shows revision 2 of 2 and names the limit as the reason, with no Request changes action; the page shows the same note and no control; `workflow_status` reports revision and bound; each request is refused as limit reached; Approve and Reject still resolve the run

- **S06 [OC02] One resolution per round; stale and racing requests are refused**
  - **Given** a live gate with a post, and after a completed round the same gate with a new post and nonce
  - **When** two request-changes calls, an approve and an HTTP cancel arrive in one event-loop turn; then a button click and a modal submission built from the first post arrive at the returned gate
  - **Then** exactly one resolution is recorded and one resolved event fires, every loser is refused as already resolved (HTTP keeps 409), and both stale interactions are refused as invalid with the new post's nonce untouched and still resolving

- **S07 [OC02] Each round is audited once and retires its post**
  - **Given** an admin sender A resolving round 1 and 2 at a gate with bound 3, once from a button-opened form and once by the tool, and an authenticated web operator resolving a round over HTTP
  - **When** each round resolves
  - **Then** each writes one allow audit entry (source button, tool or `web`; channel and sender A for chat and tool, the authenticated web resolver for `web`; run, step, action `requestChanges`, reason `revision n/3`) and never the feedback or nonce; the round's post is edited once to "Changes requested by <resolver> (n/3) at HH:MM UTC" with no actions; the next awaiting-approval post is a new message; a refused request writes one deny entry

- **S08 [OC01,OC02] HTTP request changes**
  - **Given** `POST /api/workflows/runs/<id>/request-changes` with JSON `{"feedback": "..."}` beside resume and cancel
  - **When** it is called for a live revise gate, with blank feedback, for an unknown run, for a run that is not pending, for a gate without `revise` and at the bound
  - **Then** the answers are 200 with the run JSON, 400 `INVALID_INPUT`, 404, and 409 `INVALID_TRANSITION` for the last three; each call writes one audit entry with source `web` (allow for the 200, deny for the refusals); resume and cancel answer as before

- **S09 [OC02] The `workflow_request_changes` tool follows the S06 tool rules**
  - **Given** a bound agent granted it, an admin sender A and a non-admin B in a thread, and WhatsApp and Signal admin turns
  - **When** the tool is called with `run_id` and `feedback` in each turn, from a gateway-token, scheduled and web-chat turn (web-chat turns carry surface `web` and no sender, owner D25), and with extra `sender` or `channel` arguments
  - **Then** A's call and the WhatsApp and Signal admins' calls request changes with the audit entry of scenario S07; B's is refused naming admin senders and audited; the calls without a channel sender answer that run control needs a chat turn and audit a deny; the argument call is refused as unknown; a bound agent holds the tool only through `allowedTools`, the primary agent by default, and a named MCP client's list holds none; `workflow_status` for a pending gate that names a revise step adds revision and bound, and never a nonce

- **S10 [OC01] The run page approval panel offers the action**
  - **Given** the run page for a run awaiting a gate that names a revise step with revisions left, one at the bound, one whose gate names none, and one in a revision round
  - **When** each renders
  - **Then** the first shows a feedback field and Request changes beside Approve and Reject, and a submit posts the field to the HTTP endpoint and shows a refusal as a toast; the second shows the limit note and no control; the third shows none; the gate's step card reads "Changes requested", never "Unknown status", while the round is in flight

- **S11 [OC01,OC02] [runtime] Slack: a button opens a modal and its submission resolves**
  - **Given** a live awaiting-approval post with Request changes, delivered over Socket Mode and over the Events API
  - **When** admin A clicks it, A submits feedback, then non-admin B clicks it, a click arrives with an expired `trigger_id`, A submits blank feedback, and A submits from a post since superseded
  - **Then** A's click opens one modal through `views.open` within the click's handling, carrying run, step, nonce and post in `private_metadata` and a multiline feedback input capped at 3,000 characters; the submission resolves and its acknowledgement body clears the modal; B gets an ephemeral refusal, no modal opens and one deny entry is written; the expired trigger answers an ephemeral message pointing to the run page; blank and superseded submissions are acknowledged with an inline error on the feedback field and change nothing; the same fixtures give the same results on both transports

- **S12 [OC01,OC02] [runtime] Google Chat: a button opens a dialog and its submission resolves**
  - **Given** a live run card with Request changes
  - **When** admin A clicks it and submits feedback, a non-admin clicks it, and A submits blank feedback
  - **Then** A's click answers a dialog with a feedback text input and a submit button carrying run, step and nonce, and the submission resolves and closes the dialog; the non-admin's click answers a dialog holding only the refusal and writes one deny entry; blank feedback answers an error status with a user-facing message and changes nothing

- **S13 [OC03] A gate key that names no context value reads the workflow variable of that name**
  - **Given** a variable `PLAN_REVIEW` with default `false`
  - **When** `PLAN_REVIEW == true` is evaluated unset, set to `true`, and with a context key of the same name present; and for a name that is neither
  - **Then** the results are false, true, the context value's, and false

- **S14 [OC03] `plan-and-implement` without the variable behaves as before**
  - **Given** the built-in definition and `PLAN_REVIEW` unset
  - **When** a run executes with the fake turn adapter
  - **Then** the plan gate step is skipped by its `entryGate` and never pauses, and every other step runs in the order, with the prompts and the outputs it had

- **S15 [OC03] `plan-and-implement` with plan review re-plans from feedback and then proceeds**
  - **Given** `PLAN_REVIEW=true`, a plan step that wrote a plan, and (in a second case) a plan discovered on disk so the `plan` step skipped itself
  - **When** the run reaches the gate, an admin requests changes "split story 3", the gate returns, and an admin approves; and in another run rejects
  - **Then** the gate pauses after `plan` with the plan path in its message and no story step run; the `plan` step re-runs even in the second case, its prompt carrying the feedback, `discover-plan-state` does not re-run; approve starts `story-pipeline`; reject cancels the run

- **S16 [OC03] The `--approvals auto` policy approves the gate and never requests changes**
  - **Given** a run under policy `auto` reaching a gate that names a revise step
  - **When** the gate executes
  - **Then** it auto-approves as today, the run continues, no interaction is issued and no revision is recorded

- **S17 [OC01,OC02] Gates without `revise` and their surfaces behave as before**
  - **Given** an approval step with no `revise`, its post, run page and HTTP resume and cancel
  - **When** approved, rejected and timed out
  - **Then** statuses, events, feedback handling and posts are what they were, with no third action
  - **Proof**: `packages/dartclaw_workflow/test/workflow/approval_step_runner_test.dart` – green – parity/regression


## Structural Criteria

- **SC01** One authority: request changes reaches the workflow owner only through `WorkflowRunControl` (chat buttons, forms, tools) and the HTTP route (the run page included; audited with source `web`, no admin check), no adapter or tool holds an admin check or calls the owner, and one derivation answers whether request changes is open (gate names revise, count below bound) for the owner, the interaction issue, `workflow_status`, the run page and the HTTP route.
- **SC02** Core's run-approval and capability types name no workflow type, and the run subscriber still imports no channel package, tests no platform type and branches on no `ChannelType` member.
- **SC03** Neither the nonce nor the feedback text appears in an audit entry or a log line, and no host code reads feedback beyond its emptiness (ADR-054).
- **SC04** The published workflow schema, the built-in definitions' report golden and the tool-set enumerations match the code.


## Scope & Boundaries

### Work Areas
- `packages/dartclaw_workflow`: step fields, parser, DSL rules, validator, gate variable fallback, owner `requestChanges`, revision derivation, executor re-entry, `plan-and-implement.yaml` – TI01 to TI05, TI14
- `packages/dartclaw_core`: resolved-event outcome, run-approval port, action IDs, notification third action – TI06
- `packages/dartclaw_runtime`: `WorkflowRunControl`, HTTP route, tool and status, run subscriber, run page – TI07 to TI11
- `packages/dartclaw_google_chat`, `packages/dartclaw_slack`: button, dialog and modal, submissions, acknowledgement bodies – TI12, TI13
- Docs and gates: guide, architecture, package `CLAUDE.md`, CHANGELOG, generated schema, LOC ceilings – TI15, TI16

### What We're NOT Doing
- A `dartclaw workflow` CLI command for request changes – FR11 enumerates its surfaces and the CLI is not among them; standalone resume and cancel stay.
- Routing to different revise steps by feedback, `approval:` conditional routing, or free-form steering of a running workflow – owner D11 and the DSL v2 follow-on.
- A global `maxRevisions` config key – it is a step key.
- Per-round feedback history – the gate keeps the latest feedback and the count; audit entries carry the round number only.
- Echoing the feedback in the edited post – the thread sees who and which round; the text is on the run page and in the revise step's prompt.
- Request changes on a `needsInput` hold, a gate inside a loop, `foreach` or parallel group, or a gate with no `revise` – the validator and the owner refuse these.
- Adding the gate to the maintainer's inline copy `.dartclaw/workflows/custom/plan-and-implement-inline.yaml` – a separate variant the contracts test mirrors for its `plan` step only.
- An admin check on the HTTP route – authenticated operators, as for resume and cancel (story S06).
- Buttons on WhatsApp and Signal – they use the tool.
- Parsing, summarising or truncating feedback in the host (ADR-054); a Slack modal cannot send more than 3,000 characters, and no other surface is capped here.


## Architecture Decision

**Approach**: Request changes is a third resolution of the pending approval, owned by workflow beside `resume` and `cancel` (story S06): inside the same per-run serialized section, with the same expectation and resolver, it checks the gate names `revise`, the bound and non-empty feedback, records `changes_requested`, the feedback and the revision count, retires the nonce like any resolution, then re-enters the revise step by moving the cursor back to it through the transition and executor spawn `resume` uses. A private marker makes the executor skip that step's `entryGate` once and put the feedback in its prompt until the gate pauses again. `WorkflowRunControl` gains the action and the surfaces collect feedback differently and nothing else. The HTTP route, which the run page posts to, calls the owner with the authenticated web resolver and writes one audit entry per call with source `web` through story S06's audit writer, with no admin check.
**Why this over the floor**: The floor is Reject, which cancels the run. FR11 requires keeping every step before the revise step and a bounded loop back to the gate; story S06's resolution owner is extended, not a second path (F3).
**Flow**: gate pauses, interaction issued, post sent (Request changes shown when open) → admin acts → surface collects feedback → `WorkflowRunControl` (admin, audit) → owner (pending, nonce, bound, feedback, record, consume, cursor to revise step) → resolved event → subscriber edits the post → executor runs revise step, steps after it → gate pauses again → new interaction and post.

Decisions the sources leave open, each also stated where it bites:
- The gate and its revise target are both top-level steps and the target is not an approval step – FR11 says "earlier in the same top-level sequence"; a gate inside a loop would re-enter a loop body, which the PRD excludes.
- A click on Request changes first asks run control whether the sender is an admin and the gate live (a fourth port action, `checkRequestChanges`, audited only when refused) and opens the form only on yes, so a refused sender never loses typed text.
- On re-entry only, the revise step's prompt ends with one fixed lead-in naming the round and a framed block holding the feedback verbatim, unless the prompt already references `{{context.<gateId>.approval.feedback}}` – FR11's "documented template variable" is that key, and the appended form keeps the built-in plan step's prompt unchanged on its first pass.
- Gate keys fall back to workflow variables when no context key has the name – the validator already accepts variable names as bare loop-gate keys but the evaluator never read them.
- With the variable unset, the plan gate is one skipped step (a skip marker and event, counted as progressed) – a static YAML cannot omit a step.
- The allow audit entry's `reason` carries `revision n/max`; `AuditEntry` gains no field.
- Outputs of steps between the revise step and the gate are overwritten by the re-run, never cleared; a step skipped on the second pass keeps its first-pass outputs, so `retry` semantics are unchanged.
- A re-entered step's git and worktree handling is what a `retry` of that step does today; the live qualification (owner D22) judges a real `andthen:plan` revision.
- Slack's modal submission is acknowledged after the handler within 2.5 s, else with an empty acknowledgement while the handler finishes (Slack's deadline is 3 s); Google Chat's refusal at the click is a dialog holding the text, since only the clicker sees a dialog.
- Feedback is stored trimmed of outer whitespace, as the cancel route trims.
- ASSUMPTION: Socket Mode carries the `view_submission` acknowledgement body in the acknowledge frame's `payload`; only a live workspace confirms it.
- ASSUMPTION: a Google Chat dialog stays open and shows `userFacingMessage` when its submission answers an `INVALID_ARGUMENT` status; the documentation is silent and only a live space confirms it.


## Constraints & Gotchas

- **Constraint**: a new step key must be wired in three places or it fails silently or at parse – Workaround: `WorkflowStep` (constructor, `toJson`, `fromJson`, `copyWith`'s unset sentinel), `_typedStepFieldNames` in `workflow_definition_parser.dart` (an untyped key is routed to `ruleValues` and dropped by the executor), and `WorkflowDslRules.step`; the run keeps a snapshot of its definition, so a run started before the change has no `revise` and offers nothing.
- **Constraint**: the gate stores `currentStepIndex` as its own index plus one so a resume continues after it – Workaround: request changes persists the revise step's index with status `running`, so `recoverIncompleteRuns` and `retry` restart there; the private marker `_revision.gateId` rides context rebuilds as story S06's interaction key does (`privateContextEntries`), and is dropped when `executeApprovalStep` pauses again.
- **Constraint**: `executeApprovalStep` writes pending state with `{...privateContextEntries(run.contextJson), ...}` – Workaround: it filters the marker out there, the one place that ends a revision round.
- **Constraint**: story S06's interaction record is overwritten by each issue and the edit of a round's post happens on its resolved event, ahead of the next round by a whole revise-and-continue pass, on the run subscriber's per-run chain – Workaround: no per-round history; a click on an earlier post fails the nonce check and is refused as invalid.
- **Constraint**: `WorkflowApprovalResolvedEvent` is in the sealed event library (ADR-057) and crosses SSE and `fromJson` – Workaround: additive fields only (`changesRequested`, `revision`, `maxRevisions`), `approved` stays false for this outcome, older JSON reads `changesRequested` false.
- **Constraint**: Slack `views.open` needs a `trigger_id` valid 3 s and no scope; a view's `private_metadata` is at most 3,000 characters, `plain_text_input` `max_length` at most 3,000; a `view_submission` is answered by empty body (closes), `{"response_action":"clear"}` or `{"response_action":"errors","errors":{"<block_id>":"<text>"}}`; the submitter is `user.id`, the text `view.state.values.<block_id>.<action_id>.value` ([docs.slack.dev views.open](https://docs.slack.dev/reference/methods/views.open), [modals](https://docs.slack.dev/surfaces/modals), [view payload](https://docs.slack.dev/reference/interaction-payloads/view-interactions-payload)) – Workaround: the click handler calls `views.open` first; story S01's envelope dispatch acknowledges before processing and story S02's HTTP interaction path answers 200 empty, so the `view_submission` kind alone returns an acknowledgement body from its handler on both transports; `expired_trigger_id`, `exchanged_trigger_id` and `invalid_trigger_id` are the failures to script in `FakeSlackWebApi`.
- **Constraint**: Google Chat opens a dialog only from a button whose `onClick.action.interaction` is `OPEN_DIALOG`; that click arrives as `CARD_CLICKED` with `isDialogEvent` and `dialogEventType` `REQUEST_DIALOG`, the submit with `SUBMIT_DIALOG` and the text at `common.formInputs.<name>.stringInputs.value[0]`; the responses are `{"actionResponse":{"type":"DIALOG","dialogAction":{"dialog":{"body":<card>}}}}` to open and `{"actionResponse":{"type":"DIALOG","dialogAction":{"actionStatus":{"statusCode":"OK"}}}}` to close, `INVALID_ARGUMENT` with `userFacingMessage` for an error ([Chat dialogs](https://developers.google.com/workspace/chat/dialogs), [Event](https://developers.google.com/workspace/chat/api/reference/rest/v1/Event)) – Workaround: `_handleCardClicked` in `google_chat_webhook.dart` reads `common.invokedFunction` today, the new branch reads the dialog fields beside it.
- **Constraint**: `ChannelWiring` captures the run-approval handler by value and story S06's forwarding handler binds later – Workaround: the extended port rides the same forwarding handler, no wiring change.
- **Constraint**: tool sets are enumerated in existing tests (story S06's list: `harness_wiring_bridged_grant_test.dart`, `service_wiring_local_path_bootstrap_test.dart`, `canonical_tool_test.dart`) – Workaround: `git grep "'workflow_cancel'" -- '*_test.dart'` is the inventory.
- **Constraint**: validator file splits and rule insertion change `workflow validate` output order (LEARNINGS) – Workaround: the new rules sit beside the approval-in-loop warning and the report golden in `workflow_dsl_rules_test.dart` covers the order.
- **Constraint**: package-scoped `dart analyze` and `dart test` stay green while the workspace fails (LEARNINGS) – Workaround: the Final Validation Checklist runs workspace-wide.


## Implementation Plan

### Implementation Tasks

- **TI01** Approval steps may declare `revise` (a step ID) and `maxRevisions`: YAML parses, the run's definition snapshot round-trips, the DSL rules accept them for `approval` steps only with `maxRevisions` an integer 1 to 10 and effective default 3 when `revise` is set, and `schemas/workflow.schema.json` is regenerated.
  - Pattern: the typed `entryGate` handling in `workflow_definition_parser.dart` and `workflow_definition.dart#WorkflowStep`; `workflow_dsl_rules.dart#WorkflowDslRules.step` for applicability; `dart run packages/dartclaw_workflow/tool/generate_workflow_schema.dart`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/workflow_definition_parser_test.dart packages/dartclaw_workflow/test/workflow/workflow_dsl_rules_test.dart` – JSON round trip with and without the keys, default 3, refusal on a non-approval step and for 0 and 11 at parse time
  - **SATISFIES**: S03

- **TI02** The validator refuses a `revise` that does not name an earlier top-level non-approval step, a gate or target inside a `foreach`, loop or parallel group, and `maxRevisions` without `revise`, each error naming step and fix, ordered beside the approval-in-loop warning.
  - Pattern: `validation/workflow_step_type_rules.dart#_validateHybridStepRules`; top-level membership from `WorkflowDefinition.nodes` (an `ActionNode` per top-level step).
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/workflow_validator_step_type_rules_test.dart packages/dartclaw_workflow/test/workflow/workflow_dsl_rules_test.dart` – every refusal case of scenario S03 and the valid gate, the report golden unchanged
  - **SATISFIES**: S03

- **TI03** Gate evaluation reads a workflow variable when no context key has the name, for `entryGate`, loop gates and every other gate caller, with a context key taking precedence.
  - Pattern: `gate_evaluator.dart#GateEvaluator._evaluateCondition` and `workflow_context_resolver.dart#resolveContextKey`; the loop-gate validator already accepts variable names (`_loopGateBareKeys`).
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/gate_evaluator_test.dart packages/dartclaw_workflow/test/workflow/workflow_validator_gate_rules_test.dart` – scenario S13's four cases; existing gate cases unchanged
  - **SATISFIES**: S13

- **TI04** `WorkflowService` resolves a pending gate as request changes: one derivation reports revision state for a pending step (null when it names no `revise`, else count, bound and whether open); under story S06's per-run serialized section, expectation and resolver it refuses with typed reasons (not pending and already resolved and invalid nonce as story S06's, plus no revise step, bound reached, feedback required) that change nothing and leave the nonce live, otherwise records `changes_requested`, the trimmed feedback and the incremented count in one persisted update that also consumes the interaction, fires the resolved event with the outcome, revision and bound, clears the timeout timer, and transitions to `running` with the cursor at the revise step through the transition and spawn `resume` uses; resume and cancel are untouched.
  - Pattern: `workflow_service.dart#resume`, `#_recordApprovalResolution`, story S06 TI03's expectation path and refusal type; `WorkflowApprovalResolvedEvent` in `packages/dartclaw_core/lib/src/events/workflow_events.dart`; the derivation sits beside `workflowCanApprove` in `workflow_view_helpers.dart` and is exported from `dartclaw_workflow.dart`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/workflow_request_changes_test.dart --name "owner"` – scenarios S01's state and event half, S04 and S05 at owner level, S06's `Future.wait` race with the nonce still live after each refusal, restart persistence of count and feedback, a `needsInput` hold refused; `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/workflow_service_test.dart packages/dartclaw_workflow/test/workflow/workflow_approval_interaction_test.dart` – the existing approval group and story S06's cases unchanged
  - **SATISFIES**: S01, S04, S05, S06, S17, SC01, SC03

- **TI05** The executor honours the re-entry: the revise step runs although its `entryGate` is false while the private marker is set; its prompt, on re-entry only, ends with a fixed round lead-in and the feedback framed verbatim unless the prompt already references the documented feedback key; steps before it do not re-run and the steps after it run normally; the marker survives restart, `retry` and context rebuilds and is dropped when the gate pauses again, with count and feedback kept.
  - Pattern: `workflow_executor_helpers.dart#_skipDueToEntryGate`; `SkillPromptBuilder#appendAutoFramedContext` (inline-reference suppression, closing-tag escaping) called from `step_dispatcher.dart` where `firstTaskPrompt` is built; `approval_step_runner.dart#executeApprovalStep`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/workflow_request_changes_test.dart --name "re-entry"` – scenario S01's re-run half and S02 (failure then `retry`, recovery over a fresh service), first-pass prompt byte-identical, inline reference suppressing the block, closing-tag text escaped; `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/approval_step_runner_test.dart packages/dartclaw_workflow/test/workflow/step_dispatcher_test.dart` – existing cases unchanged
  - **SATISFIES**: S01, S02, S17

- **TI06** Core carries the outcome: `WorkflowApprovalResolvedEvent` gains `changesRequested`, `revision` and `maxRevisions` (additive JSON); `ChannelRunApprovalAction` gains `requestChanges` and `checkRequestChanges`, the request an optional feedback, the sealed result a permitted variant; fixed action IDs for the button and the form submission; `ChannelNotification` holds an optional third labelled action and the revision line.
  - Pattern: story S06 TI04's port and `channel_review.dart`; `WorkflowRunStatusChangedEvent` JSON handling in the same event file.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/channel/channel_run_approval_test.dart packages/dartclaw_core/test/events/workflow_events_test.dart` – action ID round trip, result exhaustiveness, event JSON with and without the new fields; `cmd: ! git grep --untracked -n -E "WorkflowRun|dartclaw_workflow" -- packages/dartclaw_core/lib/src/channel`
  - **SATISFIES**: S07, SC02

- **TI07** `WorkflowRunControl` serves `requestChanges` and `checkRequestChanges` through the one admin gate: a missing or non-admin sender is refused and audited, a check that passes writes no entry, a resolution writes exactly one allow entry with `reason` `revision n/max` and never the feedback or nonce, every refusal writes one deny entry; no adapter or tool gains an admin check or an owner call.
  - Pattern: story S06 TI06 (`WorkflowRunControl`, `kg_tools.dart#_auditKgDecision` entry shape).
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/task/workflow_run_control_test.dart packages/dartclaw_runtime/test/runtime/service_wiring_run_approvals_test.dart` – scenarios S04, S05, S06 and S07's audit half over a real `WorkflowService`, a request through the wired forwarding handler, no nonce or feedback in any entry or captured log; `cmd: ! git grep --untracked -n -E "isAdmin|[wW]orkflows?(Service)?\.(requestChanges|resume|cancel)\(" -- packages/dartclaw_slack/lib packages/dartclaw_google_chat/lib packages/dartclaw_runtime/lib/src/mcp packages/dartclaw_runtime/lib/src/task/workflow_run_notification_subscriber.dart`
  - **SATISFIES**: S04, S05, S06, S07, SC01, SC03

- **TI08** `POST /api/workflows/runs/<id>/request-changes` takes JSON `feedback` and calls the owner without an expectation, with the authenticated web resolver, and writes one audit entry per call with source `web` through story S06's audit writer (allow, or deny for a refusal; never the feedback): 200 with the run JSON, 400 `INVALID_INPUT` for blank feedback, 404, 409 `INVALID_TRANSITION` for the other refusals.
  - Pattern: the `/cancel` handler in `packages/dartclaw_runtime/lib/src/api/workflow_routes.dart` (JSON body read, trimming).
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/api/workflow_routes_test.dart` – scenario S08's six cases with their audit entries; resume and cancel cases unchanged
  - **SATISFIES**: S07, S08

- **TI09** `workflow_request_changes` (write; `run_id`, `feedback`) is registered under story S06's tool rules (closed schema, canonical entry, sender from `McpCallerContext.turn` by opting in, a turn without a channel sender (web chat included) refused, through `WorkflowRunControl`, `allowedTools` for bound agents), and `workflow_status`'s pending approval adds revision and bound for a gate that names a revise step; the enumerated tool sets in existing tests are extended.
  - Pattern: story S06 TI07's `workflow_cancel`; `CanonicalTool` in `packages/dartclaw_core/lib/src/harness/canonical_tool.dart`, `_ownMcpToolCanonicals` in `harness_wiring.dart`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/mcp/workflow_run_control_tools_test.dart packages/dartclaw_runtime/test/runtime/harness_wiring_bridged_grant_test.dart packages/dartclaw_runtime/test/runtime/service_wiring_local_path_bootstrap_test.dart packages/dartclaw_core/test/harness/canonical_tool_test.dart` – scenario S09 (each turn kind, closed schema, each lane's grant, status shape without nonce); existing grant and registration cases pass
  - **SATISFIES**: S09, SC04

- **TI10** The run subscriber puts a third labelled action on the awaiting-approval post only when the issued interaction reports request changes open, adds the revision line for a gate that names a revise step and names the limit as the reason when it is reached, and edits the round's post on the changes-requested resolution to "Changes requested by <resolver> (n/max) at HH:MM UTC" (resolver as story S06's wording helper renders it for every source) with no actions, once, behind the run's chain; a gate without `revise` posts as before.
  - Pattern: story S06 TI08 and its resolved-wording helper; story S05's delivery helper.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/task/workflow_run_notification_subscriber_test.dart --name "request changes"` – scenarios S04's no-action half, S05's post half and S07's edit half through a fake capability and a plain `FakeChannel`, a new message for the next round; `cmd: ! git grep --untracked -n -E "dartclaw_google_chat|dartclaw_slack|GoogleChatChannel|SlackChannel|ChannelType\.(googlechat|slack|whatsapp|signal)" -- packages/dartclaw_runtime/lib/src/task/workflow_run_notification_subscriber.dart`
  - **SATISFIES**: S04, S05, S07, SC02

- **TI11** The run page's approval controls gain a feedback field and Request changes when the derivation says open, post the field to the endpoint and show a refusal as a toast, show the limit note at the bound and nothing for a gate without `revise`; `changes_requested` presents as a round in flight in the step card and approval card, never as unknown.
  - Pattern: the approval buttons in `templates/workflow_detail.html`, `workflowApprovalPresentation`/`workflowStepPresentation` in `templates/workflow_detail.dart`, `workflow_approval_metadata.dart`, the toast in `static/controllers/dc_workflows_controller.js`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/templates/workflow_detail_template_test.dart packages/dartclaw_runtime/test/api/workflow_routes_test.dart` – scenario S10's four renders and the presentation mapping; existing Approve and Reject cases unchanged
  - **SATISFIES**: S10

- **TI12** Google Chat renders the Request changes button with `OPEN_DIALOG` on the run card when the notification carries the third action, answers its dialog-request click through the check with a dialog (feedback input and submit button carrying run, step, nonce; or only the refusal text), and routes `SUBMIT_DIALOG` through `requestChanges`, closing on success and answering an error status with a message otherwise; task cards, `task_accept`/`task_reject` and story S06's two actions are untouched.
  - Pattern: story S06 TI10; `chat_card_builder.dart#_actionButton`; `google_chat_webhook.dart#_handleCardClicked`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_google_chat/test/google_chat_run_approval_test.dart packages/dartclaw_google_chat/test/google_chat_webhook_card_clicked_test.dart packages/dartclaw_google_chat/test/chat_card_builder_test.dart` – scenario S12 and S04's dialog half; the task-card parity case unchanged
  - **SATISFIES**: S04, S12

- **TI13** Slack renders the third button, answers its `block_actions` click through the check with `views.open` (modal with a multiline feedback input capped at 3,000 characters, run, step, nonce and post in `private_metadata`) or an ephemeral refusal or run-page pointer when the open fails, and routes `view_submission` through `requestChanges`; the dispatch's handler for that kind returns an acknowledgement body (clear, or an inline error on the feedback field) that both transports send after the handler within 2.5 s, other kinds still acknowledged first and empty; `FakeSlackWebApi` records and scripts `views.open` including its failures.
  - Pattern: story S06 TI11 (`block_actions` handler, ephemeral reply); story S01's envelope dispatch and fake Socket Mode server; story S02's events handler and signed interaction path.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_slack/test/slack_run_approval_test.dart packages/dartclaw_slack/test/slack_request_changes_test.dart packages/dartclaw_slack/test/slack_envelope_dispatch_test.dart packages/dartclaw_slack/test/slack_events_handler_test.dart` – scenario S11 and S04's modal half over both transports with no network; story S01, S02 and S06 cases unchanged
  - **SATISFIES**: S04, S11

- **TI14** The built-in `plan-and-implement` declares optional variable `PLAN_REVIEW` (default `false`) and a `plan-approval` gate after `plan` with `revise: plan`, `entryGate: "PLAN_REVIEW == true"` and a message naming `{{context.plan}}`, and the contracts test pins its place and default-off behaviour; the report golden stays clean.
  - Pattern: the `plan` step and `variables` block in `packages/dartclaw_workflow/lib/src/workflow/definitions/plan-and-implement.yaml`; harness in `workflow_builtin_plan_and_implement_test.dart`. No other tracked copy is read by tests or profiles (`git ls-files | grep plan-and-implement` lists the inline variant only).
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/workflow_builtin_plan_and_implement_test.dart packages/dartclaw_workflow/test/workflow/built_in_workflow_contracts_test.dart packages/dartclaw_workflow/test/workflow/workflow_dsl_rules_test.dart` – scenarios S14, S15 (both plan cases, approve, reject) and S16 with the fake turn adapter; every existing case in those files unchanged
  - **SATISFIES**: S14, S15, S16, SC04

- **TI15** The records match the code: public `docs/guide/workflows-reference.md` (`revise` and `maxRevisions` rows, the `approval` Steps section's third outcome, the feedback template variable and context keys, gate keys reading variables, the `plan-and-implement` variable), `docs/guide/workflows.md` approval flow, `dev/architecture/workflow-architecture.md` § 4.2 (context keys, the third resolution, the statement that no built-in workflow uses an approval step) with a bumped "Current through", `dev/architecture/channel-messaging-architecture.md` (third action, form, ack body), `docs/guide/web-ui-and-api.md` (endpoint and tool rows), `docs/guide/google-chat.md`, `docs/guide/slack.md`, `docs/guide/recipes/08-crowd-coding.md`, `packages/dartclaw_workflow/CLAUDE.md` and `packages/dartclaw_runtime/CLAUDE.md` where they list the approval resolutions, and the `[0.28.0]` CHANGELOG Added line without story IDs.
  - Inventory: case-insensitive search for `approval`, `workflow_cancel`, `entryGate` and `No current built-in workflow` across `dev/`, `docs/` and package `CLAUDE.md` files; the private `docs/wireframes/deviations.md` entry for the run page is the owner's record (private repo, not committed from here).
  - **Verify**: `cmd: git grep -q workflow_request_changes -- docs/guide/web-ui-and-api.md packages/dartclaw_runtime/CLAUDE.md && git grep -q changes_requested -- docs/guide/workflows-reference.md dev/architecture/workflow-architecture.md && git grep -q PLAN_REVIEW -- docs/guide/workflows-reference.md` – each doc names what it owns; `cmd: ! git grep -n "No current built-in workflow requires" -- dev docs`; `inspect: dev/architecture/workflow-architecture.md:5` – "Current through" names this change
  - **SATISFIES**: SC04

- **TI16** The gates hold: `_libLocCeilings` carries re-measured targets with a reviewed-necessity line for packages this diff moved past their band, the schema artifact and fitness checks are current, and the structural criteria hold on the whole diff.
  - **Verify**: `cmd: dart run dev/tools/arch_check.dart` – every L2 line passes; `cmd: bash dev/tools/fitness/run_all.sh` – the workflow schema and tool-set gates green; `cmd: ! git grep --untracked -n "WorkflowRun" -- packages/dartclaw_core/lib/src/channel`; `cmd: ! git grep --untracked -n -E "isAdmin" -- packages/dartclaw_slack/lib packages/dartclaw_google_chat/lib packages/dartclaw_runtime/lib/src/mcp`
  - **SATISFIES**: SC01, SC02, SC04


## Final Validation Checklist

- Workspace-wide, not package-scoped: `dart format --line-length=120 --output=none --set-exit-if-changed .`, `dart analyze --fatal-infos`, `bash dev/tools/test_workspace.sh`, `dart run dev/tools/arch_check.dart`, `bash dev/tools/fitness/run_all.sh`, `git diff --check`.
- `bash dev/tools/postgres_contract.sh` runs without skips: the revision marker, count and feedback ride the run's context JSON.
- Visual validation of the run page (`/workflows/<runId>`) with the `workflows` testing profile: a run awaiting a revise gate with revisions left, at the bound, and a gate without `revise`, against `docs/wireframes/workflow-detail.html` and the design system; deviations go to the owner's `docs/wireframes/deviations.md`.
- Live proof runs once in the owner-led qualification after the last story (PRD owner D22), not here: the Slack modal over both transports including the Socket Mode acknowledgement body, the Google Chat dialog including whether it stays open on an error status, and a real `andthen:plan` revision from `plan-and-implement` with `PLAN_REVIEW=true`.

## Implementation Observations

- The three owner surfaces share one derivation, `workflowRevisionState` (`workflow_view_helpers.dart`): the owner's checks, `workflow_status`, the run subscriber's third action, the run page and the HTTP route read it, and `checkRequestChanges` runs the owner's own checks so the check and the request cannot disagree. `issueApprovalInteraction` is unchanged: the subscriber calls the derivation on the run it already loaded instead of the interaction carrying an "open" flag.
- ASSUMPTION: `ChannelNotification` gains no field; the third action rides the existing `actions` list and the revision line rides `facts['Revision']` plus, at the bound, a sentence in the body – a core type that holds nothing platform-specific stays unchanged | a renderer that needs the revision as data, not text, would add a field.
- ASSUMPTION: the lead-in and feedback block are part of the revise step's resolved prompt, so they sit before the auto-framed inputs and the output-contract sections rather than after them – the literal "ends with" would put feedback after the step-outcome protocol | an author who wants it last can reference `{{context.<gate>.approval.feedback}}` where they want it.
- ASSUMPTION: a skill-only revise step (no `prompt`) receives the feedback block as its prompt, which replaces its markdown context summary with the XML-framed inputs | a step that sets `autoFrameContext: false` and has no prompt would need the summary kept.
- ASSUMPTION: blank tool feedback is refused by the shared closed-schema pass (`invalid_request`) before `WorkflowRunControl`, so it writes no audit entry; every other tool refusal is audited | a requirement that blank feedback is audited moves the non-empty check into the tool call path.
- ASSUMPTION: an HTTP cancel that arrives after a request-changes won the same turn cancels the now-running run, as cancel of a running run always did; the scenario's "HTTP cancel refused 409" holds for a cancel serialized ahead of the executor's move only when the gate is still pending | a product rule that a revision round cannot be cancelled would add a state check to `_cancel`.
- ASSUMPTION: Slack acknowledges a resolved submission with `{"response_action":"clear"}` (S11's wording); an empty body would close the same single modal.
- The Google Chat dialog's submit button also echoes `postMessageId`, read only when the submit event carries no `message`, because Google documents `message` for `CARD_CLICKED` events without saying a dialog submission has it.
- `requestChanges` records the feedback on the context data and flat run context under `<gate>.approval.feedback`; the resolved event never carries it, so SSE and logs do not hold the text. The run page shows it in the gate's resolution line while the round runs.
- Test support gained `WorkflowServiceTestHarness.newService()` and `BuiltInWorkflowDriver.attachStubs`/`loadBuiltIn`/`ensureProject`/`defaultTurnAdapter` (extracted from `executeBuiltInWorkflow`, which now runs on `attachStubs`) so service-level and built-in round trips share the stub responder.
- Arch targets re-measured for core, runtime, google_chat, slack and workflow with one reviewed-necessity line (TI16).

#### DRIFT

- spec-stale: the TI07, TI16 and TI15 greps are not clean on the merged tree: `isAdmin` also matches S09's `knowledge_write_gate.dart` under `packages/dartclaw_runtime/lib/src/mcp`, and `"No current built-in workflow requires"` matches this FIS itself under `dev/` | Stale targets: this FIS's `Verify` lines | –
- ambiguous-intent: TI06 names a "revision line" on `ChannelNotification`; it is carried as a fact and body text (see the first ASSUMPTION) | Stale targets: none | –
- ambiguous-intent: S06 expects an HTTP cancel in the race to be refused as already resolved; see the cancel ASSUMPTION | Stale targets: none | –

#### NOTICED BUT NOT TOUCHING

- The marker `_revision.gateId` is dropped only when the gate pauses again. If a gate's own `entryGate` turned false on the return pass, the gate would be skipped and the marker would stay for the rest of the run, so a later recovery would restart from the saved step index instead of the task-derived one. The built-in gate's `entryGate` reads a fixed variable, so it cannot happen there; a custom workflow with a context-dependent gate `entryGate` could reach it.
- Live qualification (owner D22) still has to confirm: the Socket Mode `payload` acknowledgement for `view_submission`, Google Chat keeping the dialog open on `INVALID_ARGUMENT`, a Google Chat submit event with or without `message`, and a real `andthen:plan` revision under `PLAN_REVIEW=true`.
- The visual validation of the run page (`/workflows/<runId>`, `workflows` testing profile) is not in this run's evidence; see the report.
