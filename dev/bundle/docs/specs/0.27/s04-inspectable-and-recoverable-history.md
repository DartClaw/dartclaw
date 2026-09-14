# Inspectable and Recoverable History

**Plan**: dev/bundle/docs/specs/0.27/plan.json
**Story-ID**: S04

## Feature Overview and Goal

**Intent**: Let the owner inspect what happened and recover from an earlier exchange without losing evidence, repeating
an approval side effect, or implying that conversation actions undo external state.

**Expected Outcomes**:

- [OC01] Long and active conversations remain stable to read, navigate, select, copy, disclose, and page while new
  activity arrives.
- [OC02] Tool work and runtime approval requests remain truthful and actionable across streaming, failure, reload,
  reconnection, restart, and concurrent viewers.
- [OC03] Retry, edit-and-continue, and fork create linked new work from retained context while the original messages,
  partial output, and external effects remain intact.
- [OC04] History, tool, approval, and recovery controls remain understandable and operable at supported viewport,
  keyboard, zoom, theme, and motion settings.

## Required Context

Path resolution is deliberate: `dev/...` and `packages/...` are public-repository-root paths, resolved read-only during
this private authoring pass at `../dartclaw-public/<path>` against commit
`0e605a2038b79c4e8d3164297506eff9a76f8fb4` and consumed unchanged from the public root after the deferred export.
`prd.md`, `plan.json`, producer FIS basenames, and `../../wireframes/...` are private-canonical references relative to
this FIS; the future disposable implementation bundle preserves or supplies those relative targets without rewriting
this prose.

- `prd.md#fr5-stable-transcripts-and-actionable-approvals` – full E3/E4 contract plus Q2/Q3/Q6/Q7 history and
  approval clauses owned by this story.
- `prd.md#fr6-preserved-history-recovery` – complete retry, edit-and-continue, fork, eligibility, context-lineage,
  and negative-path contract.
- `prd.md#fr10-accessible-experience-and-operational-qualification` – retained C09 ownership for the common native
  disclosure contract; this story does not absorb other features' canon fixes or S09's integration/documentation work.
- `prd.md#e11-phone-keyboard-and-assistive-technology-quality` – feature-specific keyboard, disclosure, focus, touch,
  responsive, contrast, and announcement requirements.
- `prd.md#constraints` – prototype proportionality, existing-authority constraints, private-only authoring hold, and
  published-0.26.1 reconciliation gate.
- `plan.json#sharedDecisions` – stable attempt/request identities, one approval resolution authority, retained history,
  and separation of workspace principal from project context.
- `s03-reliable-conversation-loop.md#architecture-decision` – stable submission/attempt identity, authoritative
  conversation snapshot, attachment ownership, and live reconciliation that this story extends.
- `s01-agent-workspace-execution.md#technical-overview` – configured and legacy session ownership plus the resolved
  destination context consumed by eligible admin forks; an absent workspace key preserves no-workspace behavior and does not affect this scope.
- `dev/state/PRODUCT.md#proportionality` – one-owner, one-process scale and the prohibition on a second storage
  authority, distributed runtime, or unprofiled rendering machinery.
- `dev/guidelines/TESTING-STRATEGY.md#layer-2--component--integration-tests` – production-shaped filesystem/API tests,
  deterministic races, and fake-harness boundaries.

## Deeper Context

- `../../wireframes/chat-conversation-cards.html:95` – current Afterglow tool-call and approval-card composition to
  refine with stable history, partial-output, exact-request, and recovery states.
- `../../wireframes/guard-block-chat.html:183` – current hard-block conversation treatment; keep it visibly distinct
  from an approvable runtime request.
- `dev/design-system/DESIGN.md#tool-calls` – canonical native disclosure, status, bounded well, and tool-stack grammar.
- `dev/design-system/DESIGN.md#approval-gates` – canonical waiting and resolved approval-card grammar.
- `dev/guidelines/HTMX-GUIDELINES.md#recommended-patterns` – server-rendered fragment, explicit navigation, swap,
  history-restore, and Stimulus ownership rules.
- `dev/guidelines/TRELLIS-GUIDELINES.md#security--the-rules-that-matter-most` – escaped text/attribute boundary for
  retained arguments, results, context, and approval descriptions.

## Acceptance Scenarios

- **S01 [OC01,OC04] [runtime] Reading position and completed content stay stable while activity arrives**
  - **Given** the owner has scrolled above the bottom, selected completed text, focused an earlier message, or opened a
    tool disclosure while a later turn streams and duplicate or missed updates may be reconciled
  - **When** text, tool status, terminal output, older history, reconnection, or a conversation switch/back changes the
    rendered transcript
  - **Then** completed paragraphs and code keep stable layout and selection; the viewport stays on the stable message
    anchor plus relative offset; disclosure and draft state restore on return; and **New activity · Jump to latest**
    appears without stealing focus until a deliberate jump resumes bottom-following
  - **And** messages expose accessible full timestamps, whole-message copy, code-block copy with confirmation, and
    bounded internal scrolling for wide code, tables, tool details, and long output without discarding the retained
    redacted original
  - **Proof**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case q2-q3-q7-history --compare-wireframes` –
    planned, unexecuted at spec time; a real browser must preserve selection, message anchor/offset, disclosure, draft,
    focus, layout, and copy confirmation through streaming, paging, switching, and reconnect

- **S02 [OC01] [runtime] Bounded history windows reach old and missing targets honestly**
  - **Given** 200 conversations, ten active/attention states, 2,000 messages in the selected conversation, long
    code/table output, eight attachment chips, and a target before the initial last-200-message window
  - **When** the owner switches among warmed conversations, opens a deep link to the old message, loads 100 earlier
    messages, or follows a link whose target was removed or became inaccessible
  - **Then** warmed selection paints the target transcript within p95 200 ms over 30 switches; cold load shows a stable
    labelled shell within 100 ms and reports transcript readiness separately; the old target opens in a bounded window;
    loading older history shifts the visible anchor by no more than 4 CSS px; and an unavailable target explains the
    state and offers a route back to the conversation
  - **And** during deterministic concurrent streaming no UI long task exceeds 100 ms in the measured 30-second sample;
    the implementation profiles changed-content rendering before adding optimization and introduces neither transcript
    virtualization nor a rendering framework
  - **Proof**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case q2-q3-q7-history --compare-wireframes` –
    planned, unexecuted at spec time; retained browser timings, anchor measurements, screenshots, and interaction output
    must cover the representative-load, deep-link, no-match, and access-revocation cases

- **S03 [OC02] Durable tool history survives completion, failure, partial output, and replay**
  - **Given** one owning attempt emits running, routine-success, failed, blocked, duplicate, and long tool events, then
    stops, fails, reconnects, or crosses a server restart after partial assistant/tool output
  - **When** initiating and passive viewers reconcile the conversation from authoritative retained state
  - **Then** each stable tool identity renders once inside its owning turn; routine successes collapse to summaries;
    running, failed, and blocked states remain clear; and expansion shows retained redacted arguments, result or honest
    partial/truncation state, elapsed time, and related file/artifact links where identities exist
  - **And** existing audit/redaction and payload-limit authorities run before the display record is committed; live SSE
    content alone is never the durable card; later failure, cancellation, reload, or replay cannot erase or relabel the
    retained partial assistant/tool result
  - **Proof**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/history_contract_test.dart --name "tool records retain redacted partial and terminal history exactly once"` – planned, unexecuted at spec time; must vary event order, duplicate delivery, result size, redaction, failure, cancellation, and restart

- **S04 [OC02,OC04] Exact runtime approval requests resolve once or become honestly unavailable**
  - **Given** an enforceable runtime approval request with stable request/attempt/tool identity, action and target,
    consequence/scope, expiry, and current resolution, observed by two authorized browser viewers
  - **When** the owner focuses its compact current-request strip, jumps to and reads the full card, races approve/reject
    from both viewers, repeats a decision, disconnects, loses authorization, or acts after expiry
  - **Then** only the exact still-pending request reaches the existing provider approval authority once; both viewers
    converge to the same resolved or expired card without a second side effect; unavailable controls reconcile before
    re-enabling; focus enters the named request before action and returns predictably after resolution
  - **And** only runtime-enforceable modes are offered; there is no global blind-approval shortcut; a hard guard block is
    never actionable; unknown, stale, malformed, mismatched-attempt, expired, and unauthorized direct API requests are
    rejected before any resolution or provider response
  - **Proof**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/history_contract_test.dart --name "two viewers resolve the exact runtime approval once across expiry and revoked access"` – planned, unexecuted at spec time; barrier-controlled cases must assert one provider response and zero side effects on every rejection

- **S05 [OC03] Retry creates a linked attempt without erasing the failed evidence**
  - **Given** a failed or cancelled attempt retains its original input, references, attachments, project/provider context,
    partial assistant output, and zero or more tool results
  - **When** an authorized owner explicitly retries it, repeats the request, or targets an unknown, stale, ineligible,
    successful, or no-longer-accessible attempt
  - **Then** one accepted retry creates a new attempt identity linked to the source and uses the retained original input
    and revalidated context; the source and partial result remain unchanged; the UI warns that tool effects may repeat
    and never claims to resume at the failed tool
  - **And** repeated accepted identity returns the same result, while every invalid or unauthorized target is rejected
    without a message, attempt, attachment transfer, tool action, or source mutation
  - **Proof**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/history_recovery_contract_test.dart --name "retry links one new attempt while source input context and partial output stay unchanged"` – planned, unexecuted at spec time; include repeated, no-match, stale, success, authorization, context-revalidation, and side-effect-warning cases

- **S06 [OC03,OC04] Edit and fork branch only at an eligible completed boundary**
  - **Given** an authorized owner selects a completed user prompt for **Edit and continue from here**, or a completed
    message boundary for **Fork from here**, in an ordinary, archived/read-only, channel, task, configured-agent, or
    legacy admin-visible conversation
  - **When** eligibility is evaluated and an allowed action is confirmed after showing source conversation/message,
    attachments/references, provider/project/workspace context, and the explicit new destination
  - **Then** edit-and-continue restores the selected prompt and retained rich input into a new branch; fork copies only
    the visible prefix through the chosen completed boundary into one linked new conversation; the original history
    remains accessible and byte-for-byte unchanged; and project/file references are revalidated before the new send
  - **And** an active changing partial is ineligible; archived/read-only/channel/task types expose their explicit
    allowed or unavailable result; only an eligible administrator may fork a legacy conversation to the host-resolved
    destination; agent-facing tools never gain admin-history visibility or a caller-selected principal/destination
  - **And** neither action copies hidden provider state, reverts files, undoes messages or tool effects, implies
    filesystem rollback, nor creates a Git worktree; unverified native continuation is described as visible-history
    context rather than provider resume
  - **Proof**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/history_recovery_contract_test.dart --name "edit and fork preserve source lineage eligibility and explicit destination boundaries"` – planned, unexecuted at spec time; matrix all session types, active/stale/no-match boundaries, authorization, reference revalidation, configured/legacy ownership, and negative filesystem/provider-state assertions

- **S07 [OC02,OC03,OC04] [runtime] Disclosures, approvals, and recovery actions remain operable and visually truthful**
  - **Given** tool cards, the existing workflow-step disclosure, approval cards, message actions, long content, and
    retry/edit/fork states at 375, 390, 768, and 1440 CSS px in both themes, at 200% zoom and reduced motion
  - **When** the owner navigates by keyboard, opens and closes disclosures, copies content, focuses an exact approval,
    attempts unavailable recovery actions, and receives rapid live-to-terminal state changes
  - **Then** tool cards and the shared workflow-step widget use a native button or `details`/`summary` with truthful
    expanded state and visible focus; message/tool actions and approval/recovery controls are labelled, keyboard-usable,
    never hover-only, at least 44 × 44 CSS px when essential, and preserve focus without token-by-token announcements
  - **And** state is not color-only; normal text and control boundaries meet their required contrast; wide/long regions
    scroll internally; reduced motion suppresses decoration; screenshots match the two refined wireframes and computed
    styles/DOM/accessibility output confirm the behavior that pixels alone cannot prove
  - **Proof**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case q2-q3-q6-q7-q9-history --compare-wireframes` – planned, unexecuted at spec time; must boot the assembled runtime, drive real browser interactions, and retain screenshots plus computed-style, focus, ARIA, keyboard, live-region, and network evidence

## Structural Criteria

- **SC01** Stable message, tool, request, result, branch, and source identities extend the filesystem conversation
  authority and S03's submission/attempt snapshot; no SQL session migration, durable event-log subsystem, browser-owned
  history authority, or second artifact system is introduced.
- **SC02** Displayable tool and approval payloads pass through the existing audit/redaction and limit owners before
  persistence and rendering; templates escape untrusted values; retained data never grants broader filesystem,
  artifact, project, tool, or approval access.
- **SC03** Approval eligibility and resolution have one deterministic host authority which forwards at most one accepted
  response to the provider; workflow approval steps, hard guard blocks, and chat runtime approvals remain distinct.
- **SC04** Retry, edit-and-continue, and fork consume S03 identities and S01's host-resolved ownership/context. They
  preserve the source, never recalculate a workspace principal from path/project/sender/tool input, and never expose
  admin-visible legacy history through agent-facing tools.
- **SC05** C09 is one shared disclosure correction: tool cards and the existing workflow-step widget use the same native
  button/details keyboard and truthful expanded-state contract without a new workflow screen.
- **SC06** Existing Markdown, syntax-highlighting, image, attachment/reference, citation, artifact-link, Afterglow,
  Trellis, HTMX, SSE, and Stimulus owners remain in place; optimization follows measurement and adds no virtualization
  or rendering framework.
- **SC07** The two existing history/guard wireframes are refined before dependent UI tasks; structural marker tests are
  only contract checks, while served browser screenshots and interaction evidence prove visual behavior.

## Scope & Boundaries

### Work Areas

- Deterministic conversation-history fixtures for large transcripts, event races, approval resolution, restart, and
  source/branch lineage.
- `docs/wireframes/chat-conversation-cards.html` and `docs/wireframes/guard-block-chat.html` integrated state designs.
- Filesystem message/turn display projection, bounded windows, branch metadata, and retained rich-input lineage.
- Session history, exact approval, retry, edit-and-continue, and fork HTTP contracts.
- Chat templates/controller for stable scrolling, disclosures, copy actions, request cards, and recovery actions.
- Existing workflow-step disclosure widget plus focused component/API/template/controller tests and actual-browser profile.

### What We're NOT Doing

- Conversation search or command palettes – S07 consumes the bounded message-window and branch anchors produced here.
- Read, attention, settle, archive, sidebar counts, or an attention-center state machine – S06 projects this story's
  request/result identities.
- Temporary retention or conversation export – S08 consumes this story's transcript and lineage contracts.
- A separate successful-response **new answer** action – edit-and-continue and fork are the retained recovery surface.
- Full run replay, a guard dashboard, arbitrary executable embeds, a new artifact system, or a new workflow screen –
  existing destinations and renderers cover the accepted scope.

## Architecture Decision

**Approach**: Extend the filesystem conversation authority with a bounded display projection keyed by S03 message/
attempt/tool/request identities; route exact approval decisions through the existing provider authority under the
session mutation seam; create retry and branch records through existing session/message services using S01's resolved
destination context. HTMX supplies server fragments and navigation while the chat Stimulus controller owns viewport,
focus, disclosure restoration, and live reconciliation behavior.

**Why this over alternatives**: The existing owners already provide cursor paging, execution identity, provider
approval, redaction, session creation, and rendering seams, so extending them keeps reload/restart truth inspectable
without an event store, client state machine, hidden provider-history copy, or rendering framework.

## Technical Overview

Each accepted tool/request/result transition advances the S03 conversation snapshot and writes the displayable,
redacted record beside its owning attempt before emitting a lightweight invalidation. Bounded APIs return a tail,
messages before a cursor, or a window around a stable message ID, with source/branch links and explicit unavailable
states. Approval resolution validates caller, attempt, request, expiry, and current state under the session mutation
authority before forwarding one provider response. Retry and branch creation claim a stable mutation identity, retain
source lineage and rich input, revalidate references, and create only conversation state. The browser renders server-
prepared view models and stores only viewport/disclosure/draft navigation state.

## Code Patterns & External References

```text
# type | path#anchor                                                               | why needed (intent)
file   | packages/dartclaw_core/lib/src/storage/message_service.dart#MessageService | Existing tail/before cursor reads and ordered filesystem message authority
file   | packages/dartclaw_core/lib/src/storage/session_service.dart#SessionService | Existing filesystem session creation and metadata owner for linked destinations
file   | packages/dartclaw_core/lib/src/bridge/bridge_events.dart#ToolUseEvent       | Stable provider tool identity and raw input event boundary
file   | packages/dartclaw_core/lib/src/bridge/bridge_events.dart#ToolApprovalWaitEvent | Existing runtime approval request identity boundary
file   | packages/dartclaw_core/lib/src/turn/turn_outcome.dart#TurnOutcome           | Current terminal/partial/tool summary seam to widen into retained display truth
file   | packages/dartclaw_kernel/lib/src/message_redactor.dart#MessageRedactor      | Existing sensitive-content redaction authority
file   | packages/dartclaw_runtime/lib/src/concurrency/session_mutation_coordinator.dart#SessionMutationCoordinator | Exact-once session mutation serialization
file   | packages/dartclaw_runtime/lib/src/api/session_message_routes.dart#registerSessionMessageRoutes | Existing history/send/stream route owner
file   | packages/dartclaw_runtime/lib/src/api/stream_handler.dart#sseStreamResponse  | Live tool/result transport that must remain a projection, not durable truth
file   | packages/dartclaw_runtime/lib/src/templates/chat.dart#messagesHtmlFragment  | Existing classified message and rich-input server rendering owner
file   | packages/dartclaw_runtime/lib/src/static/controllers/dc_chat_controller.js#DcChatController | Existing bottom-stickiness, paging, copy, SSE, and focus behavior owner
file   | packages/dartclaw_runtime/lib/src/templates/workflow_detail.html#workflowStepCard | Existing shared workflow-step disclosure corrected by C09
wire   | ../../wireframes/chat-conversation-cards.html:95                           | Existing canonical tool/approval conversation composition
wire   | ../../wireframes/guard-block-chat.html:183                                 | Existing non-approvable hard-block composition
```

## Constraints & Gotchas

- **Critical**: Persist the displayable redacted tool/request/result transition before advertising its snapshot
  revision. Duplicate/missed events and restart must converge by identity rather than append a second card.
- **Critical**: Approval validation and forwarding are one serialized transition. Request recency, UI focus, or event
  receipt cannot select authority; hard guard blocks never enter this transition.
- **Constraint**: Branch actions use a completed visible-message boundary and an explicit host-resolved destination.
  They copy conversation records only and cannot imply filesystem, tool-effect, provider-state, or Git rollback.
- **Constraint**: The workspace principal is opaque trusted context. The configured/legacy fork consumes S01's producer
  contract; an absent workspace key preserves no-workspace behavior and neither selects nor blocks these explicit cases.
- **Constraint**: Execute only after 0.26.1 is published. Reconcile
  `0e605a2038b79c4e8d3164297506eff9a76f8fb4..HEAD` across every Code Patterns surface before editing and preserve the
  accepted behavior if symbols moved.
- **Avoid**: Treating marker/source assertions or screenshots as visual/interaction proof. Actual served browser runs
  must retain screenshots plus DOM, computed-style, accessibility, focus, keyboard, timing, and network evidence.

## Implementation Plan

### Implementation Tasks

- **TI01** Deterministic history fixtures expose large windows, event races, restart, approvals, and linked recovery
  - Extend S03's conversation fixture/profile with 200 conversations, 2,000-message histories, controllable tool/result
    delivery, approval barriers, auth expiry, restart, stable boundaries, rich-input lineage, and browser measurements.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/history_fixture_test.dart` – planned, unexecuted at spec time; fixtures deterministically expose every Q2/Q3/Q6/Q7/Q9 history condition without real-time sleeps or a second state model
  - **SATISFIES**: SC01, SC07

- **TI02** Existing history wireframes define the accepted tool, approval, branch, and unavailable states
  - Refine `docs/wireframes/chat-conversation-cards.html` and `docs/wireframes/guard-block-chat.html` themselves before
    UI implementation, using canonical Afterglow cards/disclosures and explicit phone/desktop focus/overflow states.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/static/chat_history_wireframe_contract_test.dart` – planned, unexecuted at spec time; both assets parse with accessible relationships and referenceable state fixtures, as structural evidence only
  - **SATISFIES**: SC07

- **TI03** Tool, result, approval, and partial-output records survive authoritative reload and restart
  - Extend the S03 filesystem conversation snapshot at `MessageService`/`TurnOutcome`; key records by owning attempt and
    stable event/request ID, applying `MessageRedactor` and existing payload limits before durable display persistence.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/history_contract_test.dart --name "tool records retain redacted partial and terminal history exactly once"` – planned, unexecuted at spec time; every status/order/duplicate/restart case yields one escaped, bounded, correctly owned record
  - **SATISFIES**: S03, SC01, SC02, SC06

- **TI04** Message history exposes bounded tail, before-cursor, and around-message windows with stable lineage
  - Widen `MessageService` and `registerSessionMessageRoutes` from TI03's snapshot; preserve existing tail/before behavior,
    add authorized around-message lookup and explicit removed/inaccessible results, and return source/branch anchors.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/api/session_history_routes_test.dart --name "bounded windows preserve cursor anchor lineage and explicit unavailable targets"` – planned, unexecuted at spec time; tail, before, around, no-match, removal, revocation, and malformed cursor cases are bounded and side-effect free
  - **SATISFIES**: S02, SC01, SC02, SC06

- **TI05** Runtime approval requests validate and forward one exact resolution through the existing authority
  - Use TI03's retained request and `SessionMutationCoordinator`; validate caller, attempt/request relation, enforceable
    mode, expiry, revision, and pending state before the existing provider adapter receives one accepted response.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/history_contract_test.dart --name "two viewers resolve the exact runtime approval once across expiry and revoked access"` – planned, unexecuted at spec time; every race/repeat/reconnect/no-match/rejection forwards at most one response and hard blocks are never eligible
  - **SATISFIES**: S04, SC01, SC02, SC03

- **TI06** Retry claims one linked attempt from retained original input and context
  - Consume S03 submission/attempt identity through normal admission; revalidate attachments/references/context, preserve
    source and partial results, expose repeat-side-effect warning, and reject successful, stale, unknown, or unauthorized sources.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/history_recovery_contract_test.dart --name "retry links one new attempt while source input context and partial output stay unchanged"` – planned, unexecuted at spec time; accepted/repeated and all negative paths prove identity, lineage, immutability, context validation, and zero rejected side effects
  - **SATISFIES**: S05, SC01, SC02, SC04

- **TI07** Edit-and-continue and fork create one explicit eligible destination from a completed boundary
  - Use TI04 windows plus S01's resolved ownership/context and `SessionService`; restore/copy visible messages and rich
    input only, record source links, preserve source bytes, and keep admin legacy visibility outside all agent tool surfaces.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/history_recovery_contract_test.dart --name "edit and fork preserve source lineage eligibility and explicit destination boundaries"` – planned, unexecuted at spec time; ordinary/archived/read-only/channel/task/configured/legacy, active/stale/no-match, authorization, context, and no-filesystem/provider-copy cases pass
  - **SATISFIES**: S06, SC01, SC02, SC04

- **TI08** Server-rendered transcript fragments expose stable readable history and exact actions
  - Shape escaped view models in `chat.dart` and keep Trellis templates declarative; render timestamps, copy actions,
    retained tool groups, approval strip/cards, lineage/context, explicit unavailable actions, and bounded overflow from TI03–TI07.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/templates/chat_history_template_test.dart` – planned, unexecuted at spec time; rendered states carry stable IDs, accessible names/status/relationships, escaped retained data, source/destination context, and no approvable hard-block control
  - **SATISFIES**: S03, S04, S05, S06, SC02, SC03, SC04, SC06

- **TI09** Browser history behavior preserves anchor, selection, disclosure, focus, and explicit action state
  - Implement TI02/TI08 through `DcChatController`, consuming TI04's windows and S03 snapshot revisions; keep HTMX
    navigation/SSE as projections and persist only message-anchor offset, disclosure, draft, and navigation state locally.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/static/chat_history_controller_test.dart` – planned, unexecuted at spec time; deterministic DOM cases preserve anchor/selection/focus/disclosures and expose jump/copy/approval/recovery states through paging, swap, reconnect, failure, and no-match paths
  - **SATISFIES**: S01, S02, S03, S04, S05, S06, SC05, SC06

- **TI10** Tool cards and the existing workflow-step widget share the canonical native disclosure contract
  - Apply C09 to TI08 tool cards and `workflowStepCard`: native button or `details`/`summary`, truthful expanded state,
    visible focus, keyboard activation, stable detail relationship, and no new workflow page or disclosure controller.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/templates/chat_history_template_test.dart packages/dartclaw_runtime/test/templates/workflow_detail_template_test.dart --name "native disclosures expose truthful keyboard and ARIA state"` – planned, unexecuted at spec time; both shared surfaces satisfy the same contract and retain existing lazy step-detail behavior
  - **SATISFIES**: S07, SC05, SC06

- **TI11** The served history experience meets Q2/Q3/Q6/Q7/Q9 and affected E11 behavior in a real browser
  - Run after TI01–TI10; compare the served UI with TI02 at all specified viewport/theme/zoom/motion settings and retain
    timings, screenshots, computed styles, accessibility output, focus/keyboard journeys, network calls, and console results.
  - **Verify**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case q2-q3-q6-q7-q9-history --compare-wireframes` – planned, unexecuted at spec time; all S01/S02/S07 clauses pass with retained evidence and every failed observation remains alongside its rerun
  - **SATISFIES**: S01, S02, S07, SC05, SC06, SC07

### Testing Strategy

- TI01 extends S03's deterministic conversation fixture rather than building another harness. TI03–TI07 use real
  temporary-directory filesystem authorities, direct Shelf handlers, fake provider adapters, controlled clocks/race
  barriers, and negative side-effect assertions. TI08–TI10 use Trellis/template and DOM-controller tests for logic.
- TI02's parser test proves structural referenceability only. TI11 boots the assembled runtime and drives actual browser
  contexts; source markers and screenshots alone cannot prove visual, keyboard, focus, timing, paging, persistence, or
  approval semantics.

### Validation

- Extend the existing conversation-loop profile and TC-07A with history, tools, approvals, deep links, and recovery.
  The run retains browser screenshots plus DOM/computed-style/accessibility/timing/network evidence. Real iOS Safari,
  Android Chrome virtual-keyboard behavior, and Q10 owner tasks remain S09 external release evidence; unavailable or
  failed runs stay open, and no emulation, screenshot, generated walkthrough, or synthetic result may pass them.

### Execution Contract

- Do not export or execute this FIS in the public repository until 0.26.1 is published. At launch, compare
  `0e605a2038b79c4e8d3164297506eff9a76f8fb4..HEAD` across every Code Patterns surface and reconcile moved/changed
  contracts before editing.
- The declared S01 dependency supplies configured/legacy ownership and explicit destination context; S03 supplies
  attempt/submission identity and live reconciliation. S01's absent-workspace no-workspace behavior is outside S04, but its
  configured/legacy producer tasks must land before TI07.
- TI01 and TI02 land before dependent backend/UI work. TI03 precedes TI04/TI05; TI04 and S01's producer contract precede
  TI06/TI07; TI03–TI07 precede TI08/TI09; TI08/TI09 precede TI10; TI11 runs last against the served implementation.

## Implementation Observations

- The inherited provider adapters had automatic approval responses but no production path for an operator decision to
  reach the live native request. The active harness now retains the one pending wire response; `TurnManager` validates
  exact live turn/request ownership, while `ConversationState` remains the durable redacted display and decision
  projection. The serialized service writes `resolving` before forwarding, so a provider-write uncertainty cannot replay.
- Operator actionability is narrower than provider support. It applies only to genuine native requests from ordinary
  human web turns after guards pass: Codex with `approval: on-request`, or Claude `can_use_tool` under an explicit native
  `permissionMode` of `default`, `acceptEdits`, or `plan`. Claude `PreToolUse`, background work, ACP, `dontAsk`,
  `bypassPermissions`, and other Codex modes keep their existing automatic or unavailable behavior.
- The publication hold was resolved by the published 0.26.1 baseline. Implementation reconciled the moved S01/S03
  conversation state, visibility, snapshot, and admission seams at `fc96fce74bed82ce6bd5de8210cd45cb289df2aa`.
- Independent review found that initial branch creation copied pinned authority before reserving identity, future workers
  missed history observers, runner settlement did not drain retained events, and an uncertain approval could remain
  `resolving`. The repair routes destinations through the current S01 definition/policy owner, persists a resumable
  branch reservation before side effects, configures every coordinator-created runner, awaits its retention chain, and
  terminalizes uncertain approval delivery as unavailable without replay.
- The deferred browser fixture now creates its approval and tool transitions through a live ordinary runtime turn, races
  two decisions against the exact card, verifies one adapter response, drives edit/fork with retained attachment and
  reference input, and reloads those terminal records after restart. Its screenshots and visual comparisons remain
  unexecuted for the integrated release gate.
- A later focused owner check reproduced a display-input regression on the integrated tree: tool history encoded and
  redacted 4,267,542 code units before truncation, violating the existing 262,144 bound. The display consumer now reuses
  the existing streaming daily-log serializer moved to its shared record library. Exact provenance remains unchanged;
  the older test's whole-record no-excerpt assertion was updated for S04's explicit redacted display-result contract.
  Daily-log, hook, and history checks passed 30 tests on both isolated and integrated trees; analysis and formatting passed.
- The live display persistence path had the same defect independently of turn outcomes: a direct 4 MiB map regression
  put 4,200,387 code units through redaction. Tool maps and native approval targets now use the same bounded serializer
  before persistence. The new regression preserves secret redaction and the truncation state. The isolated focused
  suite passed 31 tests, integrated history passed 6, and analysis and formatting passed.
