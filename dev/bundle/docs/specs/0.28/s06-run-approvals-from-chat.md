# FIS: Run approvals from chat

**Plan**: dev/bundle/docs/specs/0.28/plan.json
**Story-ID**: S06

## Feature Overview and Goal

**Intent**: An admin should resolve a paused run from the chat where the run is being watched, with one button or by asking the agent, under one deterministic admin gate, one audit trail and one resolution owner, so a run started in chat never needs the web UI for its approval.

**Expected Outcomes**:

- [OC01] An admin sender resolves an awaiting approval with one click on a Slack or Google Chat post; a non-admin, a stale or forged click, or a second click is refused and audited, and the post shows what happened.
- [OC02] Admin senders resume, cancel and inspect runs through agent tools on every channel, WhatsApp and Signal included; the sender is the host's record of the turn, and a bound agent reaches the tools only through its `allowedTools`.
- [OC03] A pending approval resolves exactly once however it is resolved (button, tool, HTTP), through one workflow-owned state owner, and each resolution writes one audit entry through one runtime audit writer.


## Required Context

- `docs/specs/0.28/prd.md#fr5-run-approvals-from-chat` – criteria, nonce validation and error handling (the nonce rule is binding).
- `docs/specs/0.28/prd.md#fr7-existing-channel-parity` – Google Chat card and the WhatsApp and Signal rows; `#edge-cases` – approve after a web cancel, empty `admin_senders`; `#user-flows` flows 2 to 4.
- `docs/specs/0.28/prd.md#decisions-log` – owner D21 (tool grant, no default), D24 (the subscriber edits posts, amending architecture F3) and D25 (web-chat turns carry no sender); `#us08` for the Google Chat card.
- `docs/research/slack-threaded-runs-0.28/recommendation.md#f3-distinct-port-shared-run-authority` – ownership split and the proof list this story's scenarios cover.
- `docs/specs/0.28/s04-run-origin.md` – `McpCallerContext.turn`, the host-established turn identity a tool receives only by opting in.
- `docs/specs/0.28/s05-threaded-channels-and-run-lifecycle-posts.md` – `Channel.threadedNotifications`, `ChannelNotification`, `ThreadedPost`, the run subscriber and its awaiting-approval post, the delivery helper.
- `docs/specs/0.28/s01-slack-adapter-over-socket-mode.md` and `docs/specs/0.28/s02-slack-events-api-setup-and-diagnostics.md` – the transport-neutral envelope dispatch (handlers by kind), the response-URL client call, `FakeSlackWebApi`; story S02 already signature-verifies interaction payloads.


## Acceptance Scenarios

- **S01 [OC01] An admin's Approve click resolves a Slack approval once and the post shows it**
  - **Given** a run started from a Slack thread waits at an approval, its awaiting-approval post carries Approve and Reject, and sender A is an admin sender
  - **When** A clicks Approve, then clicks Approve again on the same post
  - **Then** the run resumes with the step's approval status approved; the post is edited to "Approved by A at HH:MM UTC" with no buttons; the second click is refused as already resolved in an ephemeral reply; the audit log holds one allow entry (source button, channel slack, sender A, run, step, action resume) and one deny entry for the second click

- **S02 [OC01] Reject cancels the run and records who rejected it**
  - **Given** the same post and an admin sender A
  - **When** A clicks Reject
  - **Then** the run is cancelled with the step's approval status rejected and no feedback recorded (a button carries none); the post reads "Rejected by A at HH:MM UTC" with no buttons; one allow audit entry with action cancel

- **S03 [OC01] A non-admin click is refused privately and audited**
  - **Given** `governance.admin_senders` is `[A]` and sender B clicks Approve on a live post; then `admin_senders` empty and B clicks again
  - **When** each click arrives
  - **Then** B gets an ephemeral "Only admin senders can resolve approvals", the run and the post are unchanged, and one deny audit entry names B, the run and the step; with the empty list B's click resolves the run, as for every other admin gate

- **S04 [OC01] A stale, forged or misplaced click is refused and the real button still works**
  - **Given** a live post for run R step X holding nonce N
  - **When** clicks arrive carrying a random nonce, N from another run, N with step Y, N from a different post, and N after R's approval was resolved elsewhere
  - **Then** each is refused (invalid for the first four, already resolved for the last), audited as a deny, and changes nothing; a genuine click on the live post then still resolves the run

- **S05 [OC01] A failed resolution keeps the button usable; a failed edit does not undo a resolution**
  - **Given** a live post and a workflow resolution that fails once
  - **When** an admin clicks Approve, then clicks again after the fault clears
  - **Then** the first click answers the failure text privately to the clicker (ephemeral on Slack), the post and its buttons stay unchanged, the audit entry records the failure, and the nonce is unconsumed; the second click resolves. Separately, when the resolution succeeds and the post edit fails, the run stays resolved, one warning names run and destination, and a later click is refused as already resolved

- **S06 [OC01] A Google Chat run card resolves under the same gate and audit**
  - **Given** a run started from a Google Chat thread waits at an approval and its post is a card with Approve and Reject carrying run, step and nonce
  - **When** an admin clicks Approve, and a non-admin clicks Reject on another run's card
  - **Then** the admin's click resumes the run, the card is patched to a resolved card with no buttons, and one allow audit entry names source button and channel googlechat; the non-admin's click is refused with a text answer and one deny entry, and that run is unchanged

- **S07 [OC01,OC03] A resolution from any other surface edits the post and retires its buttons**
  - **Given** a live approval post
  - **When** the approval is resolved by HTTP resume, by HTTP cancel with feedback, by the `workflow_resume` tool, or the run ends at the approval's timeout
  - **Then** the post is edited once, by the run subscriber: "Approved from the web UI or API" for a resolution with source web (or no recorded resolver), "Approved by <sender> in chat" for the tool, "Rejected" with the same wording for cancel, and "No longer pending: run <status>" for a run that ended unresolved; each carries HH:MM UTC and no buttons, and a later click is refused

- **S08 [OC03] [runtime] Simultaneous resolutions produce exactly one**
  - **Given** one pending approval with a live post
  - **When** two admin clicks, an HTTP resume and a `workflow_resume` call arrive in one event-loop turn
  - **Then** one resolution is recorded, one `WorkflowApprovalResolvedEvent` fires, every loser is refused as already resolved (HTTP keeps its 409), and the run is resumed once

- **S09 [OC03] [runtime] The nonce exists only for a pending approval, is 128 bits and outlives a restart**
  - **Given** a manual approval just requested, an approval auto-resolved by the `--approvals` policy, and a run not at the asked step
  - **When** the subscriber asks for an interaction for each, and the server restarts over the same stores while the first waits
  - **Then** only the first yields a nonce (128 bits, hex) and a post with buttons, the others yield none and their posts carry no buttons; after the restart the same button resolves the run; the approval is already persisted when the request event fires

- **S10 [OC02] `workflow_cancel` by an admin passes feedback; a non-admin is refused**
  - **Given** a bound agent granted `workflow_cancel`, an admin sender A and a non-admin B in a Slack thread, and a run waiting at an approval
  - **When** the agent calls `workflow_cancel` with the run ID and "the branch is stale" in A's turn, and again in B's turn
  - **Then** A's call cancels the run, the step's approval feedback holds that text, and one allow audit entry names source tool, channel slack, sender A, action cancel; B's call answers a refusal naming admin senders, leaves the run unchanged and writes one deny entry

- **S11 [OC02] WhatsApp and Signal admins resume through the tool**
  - **Given** a run started from a WhatsApp DM (and one from a Signal group) waiting at an approval whose post was plain text
  - **When** the admin's turn calls `workflow_resume`, and a non-admin's turn in the group calls it
  - **Then** the admin's call resumes the run with an audit entry naming the channel and sender; the non-admin's is refused and audited

- **S12 [OC02] No channel sender, no write; a model cannot name the sender**
  - **Given** `workflow_resume` and `workflow_cancel` called with the shared gateway token by a host worker, from a scheduled turn and from a web-chat turn (whose trusted turn context carries surface `web` and no channel sender), and once from a chat turn with extra `sender` and `channel` arguments
  - **When** each call arrives
  - **Then** the first three answer that run control needs a chat turn, change nothing and write one deny entry each; the argument call is refused as an unknown argument; a named MCP client's tool list holds none of the three

- **S13 [OC02] `workflow_status` reports state and never a nonce**
  - **Given** runs awaiting approval, failed with an error, completed, and an unknown ID, and a non-admin sender's turn
  - **When** the agent calls `workflow_status` with each ID
  - **Then** the result carries status, current step, pending approval (step, message truncated to 1,000 characters, requested time) or null, and last error; the unknown ID answers an unknown-run error; no result holds the interaction record or a nonce; the non-admin gets the same answer

- **S14 [OC02] Bound agents reach the tools only through `allowedTools`**
  - **Given** a bound agent granted `workflow_resume` and `workflow_status`, a bound agent granted only `workflow_run`, the primary agent, and a workflow step granted only `mcp_call`
  - **When** each lane's bridged grant is derived
  - **Then** the first holds exactly those two of the three, the second and the `mcp_call` step hold none, and the primary holds all three, as for the other orchestration tools

- **S15 [OC01] Task review cards and handler behave as before**
  - **Given** a Google Chat task notification card
  - **When** Accept or Reject is clicked
  - **Then** `ChannelReviewHandler` answers as it did, with no admin check, nonce or audit entry added
  - **Proof**: `packages/dartclaw_google_chat/test/google_chat_webhook_card_clicked_test.dart` – green – parity/regression

- **S16 [OC01] Slack interactions that are not a run action are acknowledged and ignored**
  - **Given** a `block_actions` envelope with an unknown action ID, one clicked on a message that is not an approval post, and a `view_submission`
  - **When** each enters the dispatch, whether it arrived by socket or Events API
  - **Then** each is acknowledged, no run changes, and the dispatch logs at debug

- **S17 [OC03] HTTP resume and cancel are audited as web resolutions and never admin-gated**
  - **Given** two runs waiting at approvals, `governance.admin_senders` is `[A]`, and an authenticated web caller who is not in that list
  - **When** the caller resumes one run and cancels the other with feedback through the run page or API, then resumes a run that is not waiting
  - **Then** both resolutions succeed as before with the same statuses and bodies, each writes one allow audit entry (source web, the authenticated web resolver as principal, no channel, run, step, action resume or cancel), the third call keeps its 409 and writes one deny entry with the reason, and no entry or response holds a nonce


## Structural Criteria

- **SC01** One authority: `WorkflowRunControl` is the only reader of `GovernanceConfig.isAdmin` for run resolution, the only caller of `resume`/`cancel` for chat, tools and HTTP, and the only writer of run-resolution audit entries, so no adapter, tool, route or subscriber holds an admin check or calls them directly.
- **SC02** Core's run-approval and capability types name no workflow type, and the run subscriber still imports no channel package, tests no platform type and branches on no `ChannelType` member.
- **SC03** A nonce value never appears in a tool result, an audit entry or a log line.


## Scope & Boundaries

### Work Areas
- `packages/dartclaw_workflow`: approval request ordering, the interaction record, expectation-based `resume`/`cancel` with typed refusals and the serialized section – TI01, TI02, TI03
- `packages/dartclaw_core`: `ChannelRunApprovalHandler` port, action IDs, `ThreadedNotifications.edit`, `FakeChannel` capability fake in `dartclaw_testing` – TI04
- `packages/dartclaw_kernel`: `AuditEntry` run and step fields – TI05
- `packages/dartclaw_runtime`: `WorkflowRunControl` (chat, tool and web entries), the three tools and their canonical entries, the HTTP resume and cancel routes, run subscriber extension, `ChannelWiring` and `ServiceWiring` – TI06, TI07, TI08, TI09
- `packages/dartclaw_google_chat`, `packages/dartclaw_slack`: buttons, click parsing, post edit – TI10, TI11
- Docs and gates: architecture, guide, package `CLAUDE.md`, CHANGELOG, LOC ceilings – TI12, TI13

### What We're NOT Doing
- Request changes, the Slack modal and Google Chat dialog, `view_submission` handling, `workflow_request_changes` – story S07, which adds a third action through this story's entry and workflow resolution.
- Admin gate, nonce or audit for task Git review – `ChannelReviewHandler` and `task_accept`/`task_reject` stay as they are (F3).
- The admin gate on shared wiki and graph writes from channel turns – story S09, in the existing knowledge write guard, using the same `GovernanceConfig.isAdmin` rule and this story's audit entry shape.
- Access gating of a click beyond the admin gate (allowlist or DM access) – FR5 names only the admin gate, and the post lives in a conversation the owner allowlisted.
- Audit entries for failed signature verification – story S02 writes those; the entries here cover refusals after authentication.
- Editing the post when a resolution fails – the post and its buttons stay unchanged and the clicker is answered privately (PRD FR5 Error Handling).
- An admin check on HTTP resume and cancel – the caller is authenticated, so HTTP is audited (source `web`) but never gated.
- A default grant of any workflow tool to bound agents (owner D21), and a `workflow_pause` or other run tool.
- Time-based nonce expiry, a per-round interaction history, a table or DDL for interactions – the record lives in the run's context; story S07 revisits history if its rounds need it.
- Looking up a sender's display name for tool-path edits – the sender ID is shown.


## Architecture Decision

**Approach**: Workflow owns state: a durable interaction record (nonce bound to run, step and post) in the run's private context, issued only for a pending approval, with check of pending run and step, nonce and post verification, resolution and consumption in one per-run serialized section behind the existing `resume` and `cancel`, which take an optional expectation and resolver and refuse with typed reasons. Runtime owns policy: `WorkflowRunControl` is the one admin gate and audit writer, providing core's sibling `ChannelRunApprovalHandler` for buttons (F3), serving the new tools and the HTTP resume and cancel routes (audited with source `web`, never admin-gated). The run subscriber (story S05) issues the nonce, puts the actions on the post, binds the sent post, and edits it on the resolved event, so every surface retires the buttons. Adapters parse clicks and answer the clicker only.
**Why this over the floor**: The floor is adapters and tools calling today's `resume`/`cancel`: they carry no nonce, report refusals as `StateError` text, and let two resolvers pass the same check before either updates. FR5 requires a post-bound single-use nonce, one resolution under races, and refusal reasons the adapter can render.
**Flow**: approval persisted → requested event → subscriber issues nonce, renders actions, sends, binds post → click, tool or HTTP call → `WorkflowRunControl` (admin gate except for HTTP, audit) → workflow resolution (pending, nonce, post, resolve, consume) → resolved event → subscriber edits the post. A refusal edits nothing.

Decisions, each also stated where it bites:
- The run subscriber edits the approval post on the resolved event for every resolution source (button, tool, run page, HTTP, timeout); adapters parse clicks and answer the clicker but never edit the post (owner D24, amending architecture F3, whose adapter edit would leave HTTP, tool and timeout resolutions with live buttons).
- HTTP resume and cancel (run page and API) go through `WorkflowRunControl`'s web entry: one audit entry with source `web` and the authenticated web resolver, no admin check, same statuses and bodies as today. A failed Slack signature check is audited by story S02, not here.
- A failed resolution after a click is answered privately to the clicker; the post and its buttons stay unchanged and the nonce stays live (PRD FR5 Error Handling).
- The control vocabulary is resume and cancel; Approve is resume, Reject is cancel with no feedback. Reject feedback from a button is story S07's modal.
- The write tools refuse every turn without a channel sender: the shared gateway token, scheduled turns, and web chat, whose trusted turn context carries surface `web` and no channel sender (story S04, owner D25). A web user resolves through the run page.
- One interaction record per run, overwritten by each issue, kept after resolution (state consumed, resolver, time) so the edit can find its post, and ended with the run.
- Button labels are Approve and Reject on both channels, since the subscriber is channel-agnostic and the PRD names those labels.
- `workflow_resume` resumes any paused or awaiting-approval run, as the existing resume path does, under the same admin gate.
- A click landing between the post being sent and being bound is refused as invalid and the next click works; the window is one local call.
- The nonce sits in the run's context, so authenticated run-detail API callers can read it; they can already resume through HTTP. Tools, audit and logs never carry it (SC03).
- ASSUMPTION: Google Chat answers a refusal or failure in the click response text; whether that text can be private to the clicker (`privateMessageViewer`) rather than visible to the space like the existing task-card errors is confirmed only in the live qualification.


## Constraints & Gotchas

- **Constraint**: `executeApprovalStep` fires `WorkflowApprovalRequestedEvent` before it persists the pending state, and the bus delivers synchronously, so a subscriber reading the run sees no approval – Workaround: TI01 persists first, as `_transitionStepAwaitingApproval` already does; the auto-resolved branch keeps firing without pending state and gets no buttons.
- **Constraint**: `ChannelWiring.wire` runs before the workflow service exists and handlers are captured by value (the comment in `ServiceWiring` on `setPushBackFeedbackDelivery`) – Workaround: both adapters capture a forwarding handler that `ServiceWiring` binds after `_wireWorkflowService`; unbound it answers that run approvals are unavailable.
- **Constraint**: the interaction record must survive every context rebuild: `_snapshotContextJson` keeps keys not listed in `removeFlatKeys`, and the stall-hold and approval runners rebuild with `privateContextEntries` – Workaround: a private (underscore) key, never in the removal set that clears `_approval.pending.*`.
- **Constraint**: story S03 adds `chat.update` to `SlackWebApiClient` in parallel for its stream fallback – Workaround: whichever lands first owns the method; this story extends it to accept blocks, never a second method.
- **Constraint**: `GoogleChatRestClient.editMessage` patches `text` only, which leaves a card's buttons – Workaround: a card edit patches the card content with its own update mask.
- **Constraint**: tool sets are enumerated in existing tests (`harness_wiring_bridged_grant_test.dart` `_orchestrationMcpTools`, `service_wiring_local_path_bootstrap_test.dart` `_orchestrationAndContentTools`, `canonical_tool_test.dart`) – Workaround: extend each; `git grep "'workflow_list'" -- '*_test.dart'` is the inventory.
- **Constraint**: the primary agent receives every mapped tool by default, so the sender gate is what stops an unbound channel turn's non-admin – Workaround: the gate reads `McpCallerContext.turn` (story S04), never an argument or the stored run origin.
- **Constraint**: a gate compares the exact sender ID the inbound path used (`senderJid`: Slack user ID, Google Chat `users/<id>`) – Workaround: click and tool senders carry that same value, so one `admin_senders` list serves buttons, tools and reserved commands.
- **Constraint**: workflow tests without task persistence use `WorkflowService.lifecycleOnly` (LEARNINGS); concurrent channel and HTTP reviews need atomic state checks (LEARNINGS) – Workaround: the serialized section plus the repository's expected-status update guard; the section is per run ID and in-process.


## Implementation Plan

### Implementation Tasks

- **TI01** A manual approval is persisted as pending before `WorkflowApprovalRequestedEvent` fires, with the event order against the status event unchanged.
  - Pattern: `packages/dartclaw_workflow/lib/src/workflow/approval_step_runner.dart#executeApprovalStep` against `parallel_group_and_step_outcome_runner.dart#_transitionStepAwaitingApproval`, which already persists first.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/approval_step_runner_test.dart` – a new case where a listener on the requested event reads the run from the repository and finds the pending step, for the manual branch; the auto-resolved branch and the existing cases are unchanged
  - **SATISFIES**: S09

- **TI02** `WorkflowService` issues an interaction for a pending (run, step) only and binds a sent post to it: a 128-bit secure-random nonce, the post's channel type and message identity, issue time, persisted in a private context key that survives restart and every context rebuild, replaced by a re-issue.
  - Pattern: `_approval.pending.stepId` handling in `workflow_service.dart`; `privateContextEntries` in `workflow_context.dart`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/workflow_approval_interaction_test.dart --name "issue"` – nonce width, refusal for a run not pending at that step and for an auto-resolved approval, survival across a fresh service over the same repository and across a stall-hold rebuild
  - **SATISFIES**: S09

- **TI03** `resume` and `cancel` accept an expectation (step, nonce, post) and a resolver (source, sender ID, display name); with one given they check pending run and step, verify nonce and post, record the resolution and mark the interaction consumed with resolver and time in the same persisted update, all inside one per-run serialized section, and refuse with a typed reason (not pending, already resolved, invalid nonce) that is not a `StateError`; with no expectation they skip the nonce and post checks, record a given resolver, and otherwise behave exactly as before.
  - Pattern: `workflow_service.dart#_recordApprovalResolution` and its expected-status update; `cancel`'s feedback path.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/workflow_approval_interaction_test.dart --name "resolve" && dart test --reporter=failures-only packages/dartclaw_workflow/test/workflow/workflow_service_test.dart packages/dartclaw_runtime/test/api/workflow_routes_test.dart` – each refusal reason, a failing update leaving the nonce live, `Future.wait` of five resolvers yielding one resolved event; existing approval and HTTP route cases unchanged
  - **SATISFIES**: S01, S04, S05, S08

- **TI04** Core carries the port: `ChannelRunApprovalHandler` with a request (approve or reject, run, step, nonce, sender ID and display name, channel type, post message identity) and a sealed result (resolved, refused with a reason, failed with a message); fixed action IDs for the two actions with their data keys; `ChannelNotification` (story S05) holds the two labelled actions over one data payload; `ThreadedNotifications` gains an edit of a posted notification by message identity returning success; `FakeChannel`'s recording capability records edits.
  - Pattern: `packages/dartclaw_core/lib/src/channel/channel_review.dart` as the sibling; story S05's capability types.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/channel/channel_run_approval_test.dart packages/dartclaw_core/test/channel/threaded_notifications_test.dart` – action ID round trip, result exhaustiveness, fake edit recording; `cmd: ! git grep --untracked -n -E "WorkflowRun|dartclaw_workflow" -- packages/dartclaw_core/lib/src/channel`
  - **SATISFIES**: S06, SC02

- **TI05** `AuditEntry` carries optional run and step IDs that round-trip through its JSON and omit when null, and the audit reader returns them.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_kernel/test/guard_audit_test.dart packages/dartclaw_runtime/test/audit/audit_log_reader_test.dart` – round trip with and without the fields, an older line without them still parses
  - **SATISFIES**: S01, S03

- **TI06** `WorkflowRunControl` (beside the run subscriber) takes the workflow service, an admin predicate from `GovernanceConfig.isAdmin` and the audit logger, exposes the `ChannelRunApprovalHandler` function, and serves the tools and the HTTP routes: for chat and tools it refuses a missing or non-admin sender and calls the workflow expectation APIs with the resolver; its web entry takes the authenticated web resolver, performs no admin check and returns the outcome the routes map to their existing statuses. It maps outcomes to resolved, refused or failed and writes exactly one audit entry per call (guard `RunApprovalGate`, hook button, tool or web, verdict pass or block, decision allow, deny or error, channel, sender or web resolver in `peerId` and `principal`, action in `tool`, refusal in `reason`, run and step), never reading the run origin or a model argument.
  - Pattern: `packages/dartclaw_runtime/lib/src/mcp/kg_tools.dart#_auditKgDecision` for the entry shape.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/task/workflow_run_control_test.dart` – scenarios S01 to S05, S08 and S17 at this level (admin, empty list, refusal reasons, failure keeps nonce, one entry per call, web entry audited without an admin check, no nonce in any entry or captured log) over a real `WorkflowService` and `FakeChannel`; `cmd: ! git grep --untracked -n -E "isAdmin|[wW]orkflows?(Service)?\.(resume|cancel)\(" -- packages/dartclaw_slack/lib packages/dartclaw_google_chat/lib packages/dartclaw_runtime/lib/src/mcp packages/dartclaw_runtime/lib/src/api/workflow_routes.dart packages/dartclaw_runtime/lib/src/task/workflow_run_notification_subscriber.dart` – no other admin check or resolver call site
  - **SATISFIES**: S01, S02, S03, S04, S05, S08, S17, SC01, SC03

- **TI07** `workflow_resume` and `workflow_cancel` (write, `run_id`, cancel also `feedback`) and `workflow_status` (read) are registered with closed schemas, canonical entries and the sender taken from `McpCallerContext.turn` by opting in; the write tools go through `WorkflowRunControl`, refuse a call with no channel sender (gateway token, scheduled and web-chat turns), and `workflow_status` returns status, current step (the pending approval step, else the step at the current index), pending approval, last error and no interaction data; the enumerated tool sets in existing tests are extended.
  - Pattern: `packages/dartclaw_runtime/lib/src/mcp/workflow_tools.dart#WorkflowRunTool`; story S04's opt-in on `workflow_run`; `CanonicalTool.workflowRun` and `_ownMcpToolCanonicals` in `harness_wiring.dart`; registration in `service_wiring_mcp_tools.dart`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/mcp/workflow_run_control_tools_test.dart packages/dartclaw_runtime/test/runtime/harness_wiring_bridged_grant_test.dart packages/dartclaw_runtime/test/runtime/service_wiring_local_path_bootstrap_test.dart packages/dartclaw_core/test/harness/canonical_tool_test.dart` – scenarios S10 to S14 (each lane's grant, closed-schema refusal of `sender`, no-turn refusal, status shape, no nonce in output, named-client list); existing grant and registration cases pass with the three tools added
  - **SATISFIES**: S10, S11, S12, S13, S14, SC01, SC03

- **TI08** The run subscriber (story S05) issues an interaction for a pending approval before rendering and, on a capability channel, sends the post with the two actions and binds the returned post; it edits the bound post on `WorkflowApprovalResolvedEvent` to the resolved wording (resolver from the record, "web UI or API" for source web or none) and on a terminal run status for an interaction still unresolved, once each, with a failed edit logged as one warning per run and never undoing a resolution; plain channels and posts without an interaction carry no actions.
  - Pattern: story S05's delivery helper and per-run chaining in `packages/dartclaw_runtime/lib/src/task/workflow_run_notification_subscriber.dart`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/task/workflow_run_notification_subscriber_test.dart --name "approval interaction"` – scenarios S05's failed-edit half, S07 and S09's post side through a fake capability and a plain `FakeChannel`, edit order behind the run's chain; `cmd: ! git grep --untracked -n -E "dartclaw_google_chat|dartclaw_slack|GoogleChatChannel|SlackChannel|ChannelType\.(googlechat|slack|whatsapp|signal)" -- packages/dartclaw_runtime/lib/src/task/workflow_run_notification_subscriber.dart`
  - **SATISFIES**: S05, S07, S09, SC02

- **TI09** `ChannelWiring` gives both adapters a forwarding run-approval handler, `ServiceWiring` builds `WorkflowRunControl` after the workflow service and binds it, registers the tools and the HTTP resume and cancel routes with it (statuses and bodies unchanged), and disposes with the rest; a click before binding answers that run approvals are unavailable; headless builds create none.
  - Pattern: `service_wiring.dart#_wireWorkflowService` ordering and the review-handler capture comment; `channel_wiring.dart` `reviewHandler`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/service_wiring_run_approvals_test.dart packages/dartclaw_runtime/test/runtime/channel_wiring_test.dart packages/dartclaw_runtime/test/api/workflow_routes_test.dart` – a Google Chat click through the wired handler resolves a run after binding and answers unavailable before; a restart with the run waiting still resolves; HTTP resume and cancel through the wired control write their web audit entry (S17) with route statuses unchanged; existing wiring cases, bound-agent routing included, unchanged
  - **SATISFIES**: S01, S09, S17

- **TI10** Google Chat renders the run card with Approve and Reject buttons carrying run, step and nonce when the notification has actions, routes `run_approve` and `run_reject` clicks to the run-approval handler with the clicker's `users/<id>`, display name and clicked message name, answers refusals and failures as text and success with an empty response, and its capability edit patches the card; the task cards and `task_accept`/`task_reject` path are untouched.
  - Pattern: `chat_card_builder.dart` button section and `_actionButton`; `google_chat_webhook.dart#_handleCardClicked`; `google_chat_rest_client.dart#editMessage`.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_google_chat/test/google_chat_run_approval_test.dart packages/dartclaw_google_chat/test/google_chat_webhook_card_clicked_test.dart packages/dartclaw_google_chat/test/chat_card_builder_test.dart packages/dartclaw_google_chat/test/google_chat_rest_client_test.dart && dart test --reporter=failures-only packages/dartclaw_runtime/test/integration/google_chat_cards_review_integration_test.dart` – scenario S06 and the task parity of S15
  - **SATISFIES**: S06, S15

- **TI11** Slack renders the two actions as buttons in the post's blocks, registers a `block_actions` handler in story S01's dispatch that reads actor, action, value, container message and `response_url` and calls the run-approval handler, answers a refusal or failure as an ephemeral reply, ignores other actions and types, and its capability edit calls `chat.update` with replacement blocks; `FakeSlackWebApi` records and scripts both.
  - Pattern: `packages/dartclaw_slack/lib/src/slack_channel.dart`; story S01's `response_url` call and handlers-by-kind dispatch; story S05's blocks rendering.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_slack/test/slack_run_approval_test.dart packages/dartclaw_slack/test/slack_envelope_dispatch_test.dart packages/dartclaw_slack/test/slack_threaded_notifications_test.dart` – scenarios S01 and S03 to S05 at adapter level over the dispatch with no socket, S16, the edit call's blocks; story S01 and S05 cases unchanged
  - **SATISFIES**: S01, S02, S03, S04, S05, S16

- **TI12** The records match the code: `channel-messaging-architecture.md` (the port, interaction, post editing) with a bumped "Current through"; `workflow-architecture.md` § 4.2 (interaction record, expectation, typed refusals); `security-architecture.md` and `observability-operations-architecture.md` (admin gate, nonce, audit entry fields, the `web` source for HTTP resolutions), with the "empty `admin_senders` suits single-user deployments" statements in `system-architecture.md`, `session-state-architecture.md` and `security-architecture.md` restated for group channels; guide `governance.md` (run approvals use `admin_senders`, an empty list makes every group member an admin, stated for group channels), `google-chat.md`, `workflows.md`, `web-ui-and-api.md` tool table, `recipes/08-crowd-coding.md`; `packages/dartclaw_runtime/CLAUDE.md` orchestration paragraph; the `governance.admin_senders` comment in `dev/fitness/test/allowlist/config_key_consumers.txt`; the `[0.28.0]` CHANGELOG Added line without story IDs.
  - Inventory: case-insensitive search for `workflow_run`, `admin_senders`, `AuditEntry fields` and `approval` across `dev/`, `docs/` and package `CLAUDE.md` files.
  - **Verify**: `cmd: git grep -q workflow_resume -- docs/guide/web-ui-and-api.md docs/guide/workflows.md packages/dartclaw_runtime/CLAUDE.md && git grep -q -i "every sender" -- docs/guide/governance.md && git grep -q runId -- dev/architecture/observability-operations-architecture.md dev/architecture/security-architecture.md` – each doc names what it owns; `inspect: dev/architecture/channel-messaging-architecture.md:5` – "Current through" names this change
  - **SATISFIES**: SC01

- **TI13** The gates hold: `_libLocCeilings` carries re-measured targets with a reviewed-necessity line for packages this diff moved past their band, and the structural criteria hold on the whole diff.
  - **Verify**: `cmd: dart run dev/tools/arch_check.dart` – every L2 line passes; `cmd: ! git grep --untracked -n "WorkflowRun" -- packages/dartclaw_core/lib/src/channel` and `cmd: ! git grep --untracked -n "isAdmin" -- packages/dartclaw_slack/lib packages/dartclaw_google_chat/lib packages/dartclaw_runtime/lib/src/mcp`
  - **SATISFIES**: SC01, SC02


## Final Validation Checklist

- Workspace-wide, not package-scoped: `dart format --line-length=120 --output=none --set-exit-if-changed .`, `dart analyze --fatal-infos`, `bash dev/tools/test_workspace.sh`, `dart run dev/tools/arch_check.dart`, `bash dev/tools/fitness/run_all.sh`, `git diff --check`.
- `bash dev/tools/postgres_contract.sh` runs without skips: the interaction record rides the run's context JSON and must round-trip through the PostgreSQL repository.
- Live Slack and Google Chat button proof, including whether Google Chat's refusal text is private, runs once in the owner-led qualification after the last story (PRD owner D22), not here.

## Discovered Requirements

- **Title**: Push-back feedback turns carry no turn provenance. **Description**: `_pushBackFeedbackDelivery` in `service_wiring.dart` starts a human-input turn (`source: 'push-back'`) on a channel-type session without a `TurnProvenance`, so `workflow_resume`/`workflow_cancel` called during it reach the sender gate with no channel and no sender, and a run started from it records origin `api`. Decide how the run-control gate classifies this turn, never as an unaudited bypass of the admin gate, align with the classification S09 chose for the same seam if S09 has landed, and prove it with a test. **Rationale**: S04 surfaced the provenance-less turn source after this FIS was written. **Interpretation**: scope-preserving; keeps S04's contract that a sender gate decides a no-sender turn by its own rule. **Traced from**: S04 completion report (open note). **Date**: 2026-10-06

## Implementation Observations

- Push-back feedback turns (Discovered Requirements): `_pushBackFeedbackDelivery` already hands the turn its task channel, recipient and session key with no sender, so the gate sees a channel turn with no sender and decides it by `isAdmin(sender ?? '')`, the rule `KnowledgeWriteGate` applies: refused and audited wherever `governance.admin_senders` is set, allowed and audited where it is empty. Proved in `workflow_run_control_tools_test.dart` ("a task push-back turn").
- ASSUMPTION: the web resolver's audit principal is the constant `owner` (the page's own precedent for human commands) – the HTTP auth carries no per-request identity; a per-user web identity would replace the constant.
- ASSUMPTION: an attributed call (resolver or expectation given) throws `WorkflowApprovalRefused` for every refusal, including a run that is not resumable, with the message the unattributed call would have raised as a `StateError`; this keeps the HTTP 409 bodies identical while letting the adapters and tools render reasons. Calls naming neither keep the `StateError` contract.
- ASSUMPTION: the interaction's post records the recipient beside channel type and message identity, because a Slack `chat.update` needs the channel and the message `ts` is only unique within it; a click is verified on channel type and message identity alone.
- ASSUMPTION: the audit entry is written after the resolution attempt, so a call writes one entry carrying its outcome (allow, deny or error); a failed audit write is logged at severe and does not undo a resolution.
- ASSUMPTION: the buttons' wording for display names is `displayName ?? senderId` on a button resolution and the sender ID on a tool resolution; Google Chat's refusal text visibility and the `cards_v2,text` patch mask are confirmed only in the live qualification.
- A resolution through the approval timeout is not a `WorkflowApprovalResolvedEvent`; the subscriber retires the buttons on the run's terminal status event ("No longer pending: run cancelled").
- The workflow routes keep their paths but now take a required `WorkflowRunControl`; `ServerWebDeps.workflowRunControl` is the matching dependency and the routes are not mounted without it. The `governance.admin_senders` config description now names run approvals and the empty-list rule, so the schema and the generated reference were regenerated.
- Slack's `postEphemeral` now also sends `replace_original: false`, which applies to slash-command answers too; and `updateMessage` accepts blocks (an empty list clears them), as the FIS requires for the resolved edit.
- Arch targets re-measured for core, runtime, slack and workflow with one reviewed-necessity line (TI13); core, runtime and workflow were already past their recorded targets before this story.
- `constantTimeEquals` moved from `dartclaw_runtime`'s auth utilities to `dartclaw_kernel` (its test moved with it) so the workflow package's nonce check and runtime's secret comparisons use the one implementation; the runtime callers import it from the kernel.
- Review applied (round 3): `WorkflowRunControl._fromTool` refuses a delegated task or workflow-step turn (`TurnProvenance.delegated`) with its existing `needsChatTurn` refusal and audit entry, whoever requested the work, so only a live admin chat turn resolves a gate from a tool. Google Chat's Accept and Reject task-review clicks now pass through `adminGatedReviewHandler` (`task/channel_review_gate.dart`): the same `governance.admin_senders` rule, one `TaskReviewGate` audit entry per click, no nonce. Slack posts no review buttons.
- Review applied (round 4): `task_review`, `task_bind` and `task_unbind` are `TurnAwareMcpTool`s gated like the chat actions they mirror. `task_review` admits a chat turn through `admitTaskReview` (`task/channel_review_gate.dart`, the card's rule and `TaskReviewGate` entry, hook `tool`, all three actions); the binding tools check `GovernanceConfig.isAdmin` and audit a refusal through `auditRefusal`, which `ReservedCommandHandler` also calls. A delegated turn is refused (`needs_chat_turn`), a non-admin chat sender is refused (`not_admin`), web and turn-less callers are unchanged. `/stop`, `/pause` and `/resume` have no tool twin. Proved in `task_tools_test.dart`.
- Review applied (round 5): the delegated-turn refusals of `task_review`, `task_bind` and `task_unbind` are audited, so the log no longer holds only the dispatch entry (written before the tool runs, `allow`, no channel or sender). `auditRefusal` (`governance/refusal_audit.dart`, which replaces `reserved_command_audit.dart`) writes the refusals no guard-owned writer covers: the reserved commands, the binding tools' non-admin refusals, the delegated refusals of the three tools (under `TaskReviewGate` or `ReservedCommand`, hook `tool`; `task_review`'s reason names the task, as `admitTaskReview`'s does) and `WorkflowRunControl._fromTool` (`RunApprovalGate`; its entry now also carries the turn's channel and requester). Chosen over `admitTaskReview` and the run-control writer because it is the only candidate that names no service and takes the guard as a parameter, so all its callers reach it without a dependency on each other. `admitTaskReview` and `WorkflowRunControl._audit` stay the writers for their guards' admin decisions. Proved in `task_tools_test.dart` and `workflow_run_control_test.dart`.

#### DRIFT

- ambiguous-intent: FIS S09 and TI02 say the interaction records the post's "channel type and message identity"; the record also holds the recipient | Stale targets: none | –
- ambiguous-intent: FIS S16 groups "unknown action ID" and "a message that is not an approval post"; a run action ID with an undecodable or incomplete value is answered with an ephemeral refusal, while an unknown action ID and a `view_submission` are acknowledged and ignored at debug | Stale targets: none | –
- spec-stale: the TI06 and TI13 greps for `isAdmin` over `packages/dartclaw_runtime/lib/src/mcp` also match `knowledge_write_gate.dart` (shared-knowledge writes, which another story landed and which applies the same `GovernanceConfig.isAdmin` rule to a different decision, not run resolution); the proof was run with that one file excluded and is clean for every other path | Stale targets: dev/bundle/docs/specs/0.28/s06-run-approvals-from-chat.md TI06, TI13 | –

#### NOTICED BUT NOT TOUCHING

- The cancel route now reads its optional JSON body before the run is looked up, so a missing or already-settled run sent with a malformed or oversize body answers 400 or 413 instead of 404 or 409. Restoring the order needs a second run read in the route. Accepted (owner, review round 4): the 400/413 for a malformed body is kept.
- A run-action click whose payload lacks a run, step, nonce, sender or message, and a click that arrives before run control is bound (a startup window), are answered by the adapter and written to no audit entry, because they never reach `WorkflowRunControl`, the one audit writer. Accepted (owner, review round 4): the interaction payload is platform-signed (Slack) or JWT-verified (Google Chat), so a member cannot craft an incomplete one; such a click resolves nothing.
- A failed Slack edit logs one warning in the adapter (with the API error) and one from the subscriber (naming run and destination); the second is the once-per-run one.
