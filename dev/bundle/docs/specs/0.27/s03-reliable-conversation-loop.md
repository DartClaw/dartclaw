# Reliable Conversation Loop

**Plan**: dev/bundle/docs/specs/0.27/plan.json
**Story-ID**: S03

## Feature Overview and Goal

**Intent**: Let the owner write and direct active work from the browser without losing input, duplicating accepted work,
or mistaking a transient update for authoritative conversation state.

**Expected Outcomes**:

- [OC01] Text, references, and attachments remain recoverable through loading, navigation, reload, disconnection, save
  failure, and acknowledgement loss, while each intentionally submitted revision is accepted at most once.
- [OC02] Initiating and passive viewers converge on the same durable submission, attempt, queue, and work state after
  missed events, reconnection, and server restart.
- [OC03] Queue, steer, and stop state exactly what they will do; concurrent edit, remove, release, dispatch, cancellation,
  and completion resolve once without executing stale or unintended input.
- [OC04] The affected composer and running-turn states give timely, keyboard-operable, responsive, and bounded
  assistive-technology feedback.

## Required Context

Path resolution is deliberate: `dev/...` and `packages/...` are public-repository-root paths, checked during this private
authoring pass at `../dartclaw-public/<path>` and consumed unchanged after export. `prd.md` and
`../../wireframes/...` are private-canonical paths relative to this FIS; the deferred exporter places those sources at
the same relative locations inside the public implementation bundle.

- `prd.md#fr4-writing-continuity-and-running-turn-controls` – complete E1/E2 contract and Q1/Q4/Q5/live-delivery Q6
  clauses owned by this story.
- `prd.md#e11-phone-keyboard-and-assistive-technology-quality` – accessibility and responsive behavior required for
  the composer and running-turn states changed here.
- `prd.md#constraints` – prototype proportionality, existing authority constraints, private-only authoring hold, and
  the published-0.26.1 reconciliation gate before public execution.
- `dev/state/PRODUCT.md#proportionality` – one-owner, one-process scale and the prohibition on a second storage
  authority or distributed runtime machinery.
- `dev/guidelines/TESTING-STRATEGY.md#layer-2--component--integration-tests` – production-shaped storage, race, and
  restart tests use real collaborators, isolated temporary directories, deterministic clocks, and fake harnesses.

## Deeper Context

- `../../wireframes/chat-composer.html#composer-idle` – current idle, streaming, and new-session composer proposal;
  revise its affected states rather than creating a parallel composer asset.
- `../../wireframes/chat-conversation-cards.html:199` – integrated conversation-card and composer basis for
  queued, held, stopping, and live-state treatments.
- `dev/testing/UI-SMOKE-TEST.md#tc-07a-chat-page--rich-composer` – existing operator-facing composer regression
  journey to extend during implementation.
- `dev/testing/scenarios/README.md#running-scenarios` – existing real browser + HTTP scenario mechanism and evidence
  conventions for the deterministic conversation-loop profile.

## Acceptance Scenarios

- **S01 [OC01,OC04] Drafting remains safe before, during, and after connectivity**
  - **Given** a provisional or established ordinary conversation whose history/capabilities may still be loading
  - **When** the owner types multiline text, adds/removes/previews references or named file bytes through button,
    drag, or paste, navigates away and back, reloads after a successful save, or continues editing while offline
  - **Then** the latest successfully persisted browser-local revision is restored for that instance and conversation,
    including bounded IndexedDB file bytes; provisional state transfers to the created conversation once; loading or
    reconnect never replaces or submits it; Ctrl/Cmd+Enter sends while Enter, IME composition, and palette selection do
    not; inherited project/model state remains visible or labelled loading; and send stays unavailable until destination,
    capabilities, and every attachment resolve, with server limits/progress/failure/retry shown from the host contract
  - **And** a quota/write failure leaves current input editable with a persistent unsaved warning plus retry and
    copy/download recovery, makes the lack of reload recovery explicit, and never reports “Saved on this device”
  - **And** a successful save reports “Saved on this device”; a conflicting revision is offered for recovery and never
    silently overwrites current text; disconnect permits explicit local save but never sends automatically on reconnect
  - **Proof**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case q4-draft-send` – planned, unexecuted at spec time; must drive the full save/reload/offline/quota/conflict matrix through an actual browser against the running local fixture

- **S02 [OC01,OC02] One recovered revision with an attachment is accepted once across two tabs**
  - **Given** two tabs restore the same persisted draft revision and attachment A, while one tab has newer unsent edits
  - **When** both submit the restored revision while the losing tab edits or removes A and cleanup runs, or the
    deterministic fixture kills the process immediately after each preparing/committed claim rewrite, attachment data,
    metadata, and accepted-manifest write, transcript append, attempt/queue write, dispatch marker, and pre/post-response
    acknowledgement boundary before restarting and retrying the same submission identity and payload digest
  - **Then** both reconcile to one stable submission, one user message, and one attempt; accepted work owns A before the
    acknowledged revision is cleared; newer edits remain recoverable; intentionally sending again creates a new
    revision/attempt; an explicit retry creates a new attempt identity linked to its source; and cleanup removes only
    unreferenced handles
  - **And** restart plus same-identity retry idempotently completes any partial durable sequence before dispatch: every
    pre-dispatch crash can reach one execution after retry, while an acknowledgement-lost crash after execution may
    have started preserves the stable attempt as uncertain/held for explicit recovery and never dispatches it
    automatically; incomplete state executes zero times, accepted attachments remain readable, and no partial/orphan
    attachment becomes visible
  - **Proof**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case q4-draft-send` – planned, unexecuted at spec time; must use two real browser contexts and hard-exit child-process failpoints at every named boundary while asserting stable IDs, exact execution count, attachment integrity, and hidden/cleaned partials

- **S03 [OC03] Queued and held input changes state through one serialized transition**
  - **Given** a running turn and two accepted queued items with text and attachments visible in stable order
  - **When** two viewers race edit/remove/release against dispatch, repeat the same operation, or release while prior
    dispatch is uncertain
  - **Then** each operation acknowledges the authoritative item state; a losing edit/remove reports “Already sent”;
    an uncertain dispatch has already reconciled to a non-executing state per SC07 and blocks neither release nor a new
    send, settling terminally when the session next dispatches; stop, failure, cancellation, and restart hold
    undelivered ordinary items; and **Send next queued message** releases only the oldest held item through normal
    admission while the other remains held
  - **Decision 2026-09-21**: the earlier “reconciles before any release” wording was read as a permanent block, which
    made one crash mid-turn park a session forever with no control able to clear it. SC07's non-executing reading wins.
  - **And** ordinary drafting stays enabled; **Queue** is the default running-turn send action, Steer remains an explicit
    alternative, both the text and attachments of each queued/held item stay visible, and acceptance order is fixed
    without a queue-reordering control
  - **Proof**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/conversation_loop_contract_test.dart --name "queue edit remove release and dispatch races converge without stale execution"` – planned, unexecuted at spec time; table-drive operation order, repeat request, and two-viewer cases

- **S04 [OC03,OC04] Stop and steer disclose and perform their actual semantics**
  - **Given** a displayed Claude, Codex, or ACP turn before first token or while streaming, with zero or more queued items
  - **When** the owner stops it, races stop with completion, or chooses Steer
  - **Then** stop targets that turn, shows Stopping until cancellation is confirmed, ignores repeats, retains partial
    output, and holds pending items; the default Steer control says it will stop then send a follow-up and starts the new
    attempt only after confirmed stop; providers without cancellable steering show an explicit unsupported result; and
    native injection is neither offered nor claimed without conformance evidence
  - **And** waiting is distinct from model work, running-before-first-token shows elapsed work state, and streaming does
    not disable selection/copy or ordinary drafting
  - **Proof**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/conversation_loop_contract_test.dart --name "provider control matrix keeps stop and steer truthful through completion races"` – planned, unexecuted at spec time; parameterize Claude, Codex, ACP, cancellation availability, and completion ordering

- **S05 [OC02] [runtime] Every viewer reconciles live work from authoritative retained state**
  - **Given** an initiating viewer and a passive viewer observing web, channel, cron, or other-tab session activity
  - **When** updates are duplicated or missed, either viewer reconnects, or the server restarts with an accepted,
    queued, dispatch-uncertain, running, completed, failed, or cancelled ordinary attempt
  - **Then** both viewers converge by stable identities and monotonically advancing revisions to the same authoritative
    submission/attempt/queue snapshot; persisted messages are not duplicated; pre-restart running or uncertain work is
    reconciled to a non-executing recoverable state; and no event receipt alone becomes a second state authority
  - **And** a partial claim after any claim/attachment/transcript/attempt-or-queue durable write is shown as reconciling
    or held until same-identity recovery proves its manifest and commit; only the fully committed state may enter
    admission, while dispatching/running/uncertain restart state is never replayed
  - **And** a viewer whose authorization is revoked cannot fetch the snapshot or retain a live stream to stale content
  - **Proof**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case q6-live-delivery` – planned, unexecuted at spec time; must boot the assembled runtime and drive two real browser contexts through origin, missed/duplicate delivery, authorization revocation, and process restart

- **S06 [OC01,OC03] Omitted, unknown, stale, and rejected mutations preserve accepted state**
  - **Given** direct API requests with optional attachments/references omitted, an unknown session/attachment/queue/turn
    identity, a stale draft or queue revision, an unresolved attachment, or an unavailable mutation/capability
  - **When** send, queue, edit, remove, release, steer, or stop is requested
  - **Then** omitted optional rich input follows the valid plain-message path; no-match targets and stale revisions return
    explicit current/not-found results; invalid or unauthorized requests are rejected before persistence or execution;
    and no rejection clears a draft, changes attachment ownership, duplicates a message/attempt, or dispatches input
  - **Proof**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/conversation_loop_contract_test.dart --name "conversation mutations reject no-match and stale input without side effects"` – planned, unexecuted at spec time; table-drive omission, no-match, validation, authorization, and capability cases

- **S07 [OC04] [runtime] Composer feedback and controls remain usable across affected viewport and assistive states**
  - **Given** loading, saved, unsaved, submitting, waiting, running, streaming, queued, held, stopping, disconnected, and
    terminal composer states at 375, 390, 768, and 1440 CSS px in both themes, 200% zoom, and reduced motion
  - **When** the owner types, uses the documented composer-focus/send/stop shortcuts, navigates controls by keyboard,
    removes an attachment, or receives rapid deltas and state changes
  - **Then** local input and pending-send feedback meet p95 100 ms and accepted/waiting/running state appears within
    500 ms on the deterministic local fixture; essential actions remain at least 44 × 44 CSS px and reachable above the
    virtual-keyboard inset; multiline growth is bounded without breaking transcript scroll; focus is not stolen from
    composition or palettes; and one bounded live region announces state/final answer rather than every token
  - **Proof**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case q1-e11 --compare-wireframes` – planned, unexecuted at spec time; must measure a real browser against the running local fixture and retain viewport/theme/zoom/motion comparison evidence; real-device evidence remains the integrated S09 release gate

## Structural Criteria

- **SC01** Ordinary conversation state extends filesystem `SessionService`/`MessageService`; admission and control extend
  `SessionMutationCoordinator`/`TurnManager`; no SQL session migration, durable event-log subsystem, browser execution
  queue, or competing stop authority is introduced.
- **SC02** Live delivery is an invalidation/update projection reconciled through an authoritative session snapshot;
  existing SSE may carry notifications, but neither SSE nor `EventBus` is durable state.
- **SC03** Admission, persistence, and live contracts consume the trusted execution principal as opaque caller context.
  They do not parse the literal `agent:<agent-id>`, derive it from session/project/sender/tool input, or change `owner`.
- **SC04** Existing plain sends, rich-input metadata, channel/cron origins, message observers, and current session/turn
  cancellation remain supported through the widened contracts.
- **SC05** The actual `chat-composer.html` and `chat-conversation-cards.html` wireframes cover the changed draft, queue,
  steer, stop, reconnect, and error states using canonical Afterglow component and accessibility conventions.
- **SC06** One deterministic fixture supplies controllable race barriers, clocks, restart reconstruction, and
  duplicate/missed delivery plus an actual-runtime browser driver to this story and later chat-story tests without
  real-time sleeps or a second state model.
- **SC07** The session `meta.json` submission claim is the sole durable admission commit record. Only a `committed`
  claim whose stable message, attempt/queue, payload digest, and complete attachment manifest match their durable files
  may dispatch; `preparing`, mismatched, or dispatch-uncertain claims reconcile to non-executing state.

## Scope & Boundaries

### Work Areas

- Filesystem session/message persistence for stable submission, attempt, ordinary queue, attachment ownership, and
  restart reconciliation state.
- Session admission, queue mutation/release, stop/steer, and authoritative snapshot HTTP contracts.
- Existing SSE/browser reconciliation for initiating and passive viewers.
- Browser-local draft storage, provisional transfer, upload ownership, offline/quota recovery, and composer controls.
- Deterministic multi-viewer/race/timing fixtures plus affected API, controller, template, and accessibility tests.
- `docs/wireframes/chat-composer.html` and `docs/wireframes/chat-conversation-cards.html` integrated state designs.

### What We're NOT Doing

- Durable tool-call/result cards, approval storage/resolution, bounded transcript windows, retry/edit/fork UI, or branch
  history – S04 consumes the identities established here and owns those behaviors.
- Project/directory selection or effective provider/model/effort capability presentation – S05 owns those settings;
  this story exposes only truthful default steer behavior through a capability-neutral control contract.
- Read, attention, settle, archive, sidebar-count, or attention-center state – S06 consumes this story's live snapshot.
- Temporary-conversation retention or export – S08 defines the volatile exception; this story persists only ordinary
  accepted work and must leave its storage contract able to reject/route a later volatile policy.
- Global shortcut/command catalogs, full Q1–Q10 integration, real-phone qualification, or public/private inventory and
  deviation reconciliation – S07/S09 own those broader surfaces and release evidence.

## Architecture Decision

**Approach**: Extend filesystem `SessionService`/`MessageService` with a recoverable submission commit protocol. An
atomic `meta.json` claim records stable submission/message/attempt-or-queue identities, payload digest, and attachment
manifest before the existing authorities write their files; a final atomic claim rewrite is the only admission commit.
Serialize mutations and recovery through `SessionMutationCoordinator`, execute committed work only through
`TurnManager`, and project changes through existing SSE as invalidations whose consumers reconcile with an authoritative
snapshot. Keep unsent drafts in bounded browser IndexedDB and transfer only accepted attachment handles to host state.

**Why this over alternatives**: It preserves one authority per concern and makes restart and duplicate-delivery recovery
possible without a new SQL session store, durable event bus, or browser-owned execution queue.

## Technical Overview

The browser assigns a stable identity to each persisted draft revision before transport. Before the first durable write,
admission fixes its payload digest plus stable message and attempt-or-queue identities. Under the session mutation lock,
an atomic `meta.json` rewrite creates a `preparing` submission claim containing those values and an immutable attachment
manifest. That claim protects named ready handles from cleanup but does not authorize dispatch. Recovery then verifies
or completes each attachment `.data`/`.json` pair and accepted ownership, makes the `messages.ndjson` line idempotent by
stable message ID and digest, and verifies or creates the stable attempt/queue record. A complete matching sequence ends
with an atomic rewrite of that same claim to `committed`; this state alone authorizes admission to `TurnManager`.

Startup and same-identity retry run the same reconciliation before any dispatch. A matching durable file is reused, a
missing final write is completed, a torn final NDJSON line is removed before the intended line is appended, and a
same-ID digest/manifest mismatch is held as an integrity failure rather than overwritten or executed. Unclaimed partial
attachment pairs stay hidden and eligible for orphan cleanup; every attachment named by a claim is retained until the
claim resolves. Reusing a submission identity with changed input is rejected. Before calling `TurnManager`, admission
persists the attempt as dispatching. A restart may complete pre-dispatch work, but never replays dispatching, running, or
uncertain work; an acknowledgement-lost retry returns that stable attempt and its recoverable state without a second
call. This gives one durable accepted submission/message/attempt and at-most-once automatic dispatch across the
separately durable authorities while keeping incomplete work non-executing. It does not claim exactly-once external
tool effects after execution may have started.

Queue edits, removals, releases, dispatch, and stop/steer transitions use the same serialized state and revision checks.
Every persisted change advances the session conversation-state revision and publishes a lightweight update; browsers
fetch/reconcile the authoritative snapshot, so missed events and passive viewers converge.

## Code Patterns & External References

```text
# type | path#anchor                                                               | why needed (intent)
file   | packages/dartclaw_core/lib/src/storage/session_service.dart#SessionService | Filesystem session authority and atomic metadata-update pattern
file   | packages/dartclaw_core/lib/src/storage/atomic_write.dart#atomicWriteJson    | Atomic boundary for each recoverable session-claim rewrite
file   | packages/dartclaw_core/lib/src/storage/message_service.dart#MessageService | Ordered accepted-message persistence and observer contract
file   | packages/dartclaw_runtime/lib/src/concurrency/session_mutation_coordinator.dart#SessionMutationCoordinator | Per-session mutation serialization
file   | packages/dartclaw_core/lib/src/turn/turn_manager.dart#TurnManager           | Provider-neutral reservation/execution/release boundary
file   | packages/dartclaw_runtime/lib/src/turn_manager.dart#TurnManager             | Runtime cancellation and recent-outcome owner
file   | packages/dartclaw_runtime/lib/src/api/session_message_routes.dart#registerSessionMessageRoutes | Existing send/history/stream API seam
file   | packages/dartclaw_runtime/lib/src/api/session_turn_status_routes.dart#registerSessionTurnStatusRoutes | Existing status/cancel API seam
file   | packages/dartclaw_runtime/lib/src/api/session_attachment_routes.dart#registerSessionAttachmentRoutes | Current attachment owner and server limit source
file   | packages/dartclaw_runtime/lib/src/api/stream_handler.dart#sseStreamResponse | Existing per-turn SSE transport, not durable authority
file   | packages/dartclaw_runtime/lib/src/static/controllers/dc_chat_controller.js#DcChatController | Composer, rich-input, stop, and SSE reconciliation owner
test   | packages/dartclaw_runtime/test/integration/_fixtures/crash_turn_process.dart | Existing hard-process-crash fixture convention to extend
wire   | ../../wireframes/chat-composer.html#composer-idle                           | Existing composer state asset to revise
wire   | ../../wireframes/chat-conversation-cards.html:199                           | Existing integrated conversation state asset to revise
```

## Constraints & Gotchas

- **Critical**: Claim submission identity and transfer accepted attachment ownership before clearing only that submitted
  draft revision; later draft edits and accepted handles survive losing-tab removal and cleanup.
- **Critical**: The process-local mutation lock is not a transaction. The atomic `meta.json` claim is the sole admission
  commit record, and `TurnManager` cannot receive work until reconciliation proves its `committed` message,
  attempt/queue, payload digest, and attachment manifest. Never infer commit from an NDJSON line, attachment file, event,
  or HTTP acknowledgement alone.
- **Critical**: Dispatch uncertainty is a persisted state to reconcile, never a reason to retry automatically. Startup,
  reconnect, duplicate requests, and duplicate events cannot re-execute an item whose dispatch marker was persisted.
- **Constraint**: The workspace principal is supplied by trusted session/execution context and is opaque here. S03 must
  remain neutral to the `agent:<agent-id>` literal and must not derive or override it.
- **Constraint**: Default Steer is confirmed stop then follow-up. Native injection remains unavailable until a provider
  transport proves it; ordinary Queue can never be presented as steering.
- **Avoid**: Token-by-token assistive announcements and event-shaped browser truth. Announce bounded state/final changes
  and reconcile every notification against the authoritative snapshot revision.
- **Critical**: Q1 samples come from browser Performance API marks around input/pending/state DOM changes, excluding
  runner overhead; Q6 convergence comes from two browser contexts across real SSE/snapshot traffic and process restart.
  Fake clocks and Dart/HTML marker scans may support diagnosis but cannot close either runtime claim.

## Implementation Plan

### Implementation Tasks

- **TI01** Deterministic conversation fixtures expose crash boundaries, race barriers, viewer delivery, and timing probes
  - Provide a child-process fixture with durable failpoints immediately after preparing and committed claim rewrites,
    each attachment data/metadata/manifest write, transcript append, attempt/queue write, dispatch marker, and before and
    after response acknowledgement. Reopen the real filesystem services after hard exit; share its fake harness ledger,
    clock, race, and delivery controls with an actual-runtime browser profile under `dev/testing/profiles/`.
  - **Verify**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case fixture-self-test` – focused fixture tests hard-exit and reopen every named boundary, distinguish pre/post-dispatch execution counts, validate retained attachment bytes, then open two actual browser contexts and record a timing sample
  - **SATISFIES**: SC06, SC07

- **TI02** Existing composer wireframes define the accepted E1/E2 integrated states before UI implementation
  - Refine `docs/wireframes/chat-composer.html` and `docs/wireframes/chat-conversation-cards.html` themselves for saved/
    unsaved, upload failure, submitting, queued/held, steer disclosure, stopping, reconnect, and responsive states.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/static/chat_conversation_loop_wireframe_contract_test.dart` – both HTML assets parse with accessible label relationships and referenceable fixtures for every changed state; this structural check is not visual evidence
  - **SATISFIES**: SC05

- **TI03** Ordinary submissions, attempts, and queue items have stable durable identities and recoverable state
  - Extend `SessionService` with the atomic preparing/committed claim and `MessageService` with stable-ID/digest lookup,
    torn-final-line repair, and idempotent append. Reconcile attachment, transcript, and attempt/queue files against the
    claim before dispatch; persist explicit dispatch uncertainty without SQL or a second event store.
  - **Verify**: `cmd: dart test --reporter=failures-only --run-skipped -t integration packages/dartclaw_runtime/test/integration/conversation_submission_crash_recovery_test.dart --name "submission commit failpoints converge without automatic replay"` – planned, unexecuted at spec time; hard-crash every TI01 durable boundary, then assert one matching message/attempt, one dispatch after recoverable pre-dispatch retry, no automatic replay after a recorded dispatch, and zero dispatch for unresolved claims
  - **SATISFIES**: S02, S03, S05, SC01, SC03, SC04, SC07

- **TI04** Accepted work owns attachment handles before the submitted draft can be cleared
  - Widen `registerSessionAttachmentRoutes` and accepted-message metadata around the existing session attachment owner;
    the claim manifest fixes handle ID, metadata, size, and content digest; cleanup protects claimed handles, hides partial
    pairs, removes only unclaimed orphans, and exposes server limits from one source.
  - **Verify**: `cmd: dart test --reporter=failures-only --run-skipped -t integration packages/dartclaw_runtime/test/integration/conversation_submission_crash_recovery_test.dart --name "attachment manifest protects accepted handles across every write crash"` – planned, unexecuted at spec time; each data/metadata/manifest failpoint retains matching accepted bytes through retry, hides incomplete pairs, and rejects unresolved, unknown, or mismatched handles without mutation
  - **SATISFIES**: S01, S02, S06, SC01, SC04, SC07

- **TI05** Send admission acknowledges one existing or new result and records busy-session input as a durable queue item
  - Widen `registerSessionMessageRoutes` under `SessionMutationCoordinator`; validate identity, revision, rich input, and
    caller context before the preparing claim, run TI03 reconciliation, and reserve/execute via `TurnManager` only from a
    complete `committed` claim; a dispatching/running/uncertain claim returns its stable result without replay.
  - **Verify**: `cmd: dart test --reporter=failures-only --run-skipped -t integration packages/dartclaw_runtime/test/integration/conversation_submission_crash_recovery_test.dart --name "only committed submissions dispatch and acknowledgement retry reuses the attempt"` – planned, unexecuted at spec time; duplicate and pre/post-ack retries return one stable result, dispatch once after recoverable pre-dispatch failpoints, never automatically replay a dispatch marker, and leave rejection side-effect free
  - **SATISFIES**: S02, S03, S06, SC01, SC03, SC04, SC07

- **TI06** Queue edit, remove, hold, release, and dispatch share one revision-checked transition
  - Use the state from TI03 through `SessionMutationCoordinator`; release only the oldest requested held item through
    normal admission, and return current state for repeated, stale, lost, or already-dispatched mutations.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/conversation_loop_contract_test.dart --name "queue edit remove release and dispatch races converge without stale execution"` – every interleaving executes at most the intended item and retains remaining held items
  - **SATISFIES**: S03, S06, SC01, SC03

- **TI07** Stop and default steer transitions target the displayed attempt and wait for confirmed cancellation
  - Extend the existing status/cancel seam and `TurnManager`; retain partial output, hold pending queue items, expose
    stopping/terminal state, and represent provider control support without claiming native injection.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/conversation_loop_contract_test.dart --name "provider control matrix keeps stop and steer truthful through completion races"` – Claude/Codex/ACP capability cases, repeat stop, stop/completion race, partial output, and confirmed follow-up are covered
  - **SATISFIES**: S04, S06, SC01, SC03, SC04

- **TI08** Session activity updates reconcile every viewer through one authoritative conversation-state snapshot
  - Extend existing SSE/broadcast wiring with revisioned invalidations for all turn origins; snapshot accepted, queued,
    held, stopping, terminal, preparing/reconciling, integrity-failed, and dispatch-uncertain state without exposing partial
    attachments or persisting an event log, using TI01 process/viewer controls.
  - **Verify**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case q6-live-delivery` – the assembled runtime plus two real browser contexts converge after every crash failpoint, duplicate/missed delivery, authorization revocation, and restart; only committed work appears accepted, partial files stay hidden, and neither viewer causes duplicate message or dispatch
  - **SATISFIES**: S05, SC01, SC02, SC03, SC04, SC07

- **TI09** Browser-local draft revisions recover text, references, bounded file bytes, and provisional ownership safely
  - Implement TI02's draft states in `dc_chat_controller.js` with an IndexedDB-backed owner keyed by
    instance/conversation; preserve input on quota/write failure, recover conflicts, and never auto-send on load/reconnect.
  - **Verify**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case q4-draft-send` – actual-browser successful save/reload, provisional transfer, two-context newer edits, conflict, quota, recovery, attachment ownership, and no-auto-send cases pass
  - **SATISFIES**: S01, S02, S06, SC04

- **TI10** Composer controls render the authoritative loading, save, admission, queue, steer, stop, reconnect, and terminal states
  - Implement TI02's integrated controls against TI03–TI08 host contracts. Keep drafting/selection/copy enabled; show
    loading geometry, host-sourced attachment
    limits/preview/progress/errors, waiting vs elapsed model work, explicit Queue/Steer/Stop/Send-next behavior, current
    item text/files, stale results, and persistent connection/save status.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/static/chat_conversation_loop_controller_test.dart --name "composer controls render authoritative draft queue steer stop and reconnect states"` – state matrix exposes only valid actions and never clears/relabels input on failure
  - **SATISFIES**: S01, S03, S04, S05, S06, SC02, SC04

- **TI11** The implemented composer matches TI02 and meets affected E11 behavior in a real browser
  - Complete bounded growth, 44 px targets, labelled secondary menu, composition-safe shortcuts, predictable focus,
    reduced motion, and bounded state/final announcements, then compare the running UI with both revised wireframes.
  - **Verify**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case q1-e11 --compare-wireframes` – real-browser input/send/state timings and keyboard/a11y checks pass at all specified viewport/theme/zoom/motion states, with retained visual-comparison evidence
  - **SATISFIES**: S01, S04, S07, SC04

### Testing Strategy

- TI01 is the common test owner. Its focused child process exits without cleanup at every preparing/committed claim,
  attachment `.data`/`.json`/manifest, NDJSON append, attempt/queue, dispatch-marker, and pre/post-acknowledgement
  failpoint. Each table row reopens the real temporary-directory `SessionService`/`MessageService`, retries the same ID
  and digest, and compares the fake harness's durable invocation ledger, stable IDs, transcript lines, attempt/queue
  records, attachment bytes, and snapshot exposure. It also controls clocks, races, and event loss/duplication.
- The failpoint oracle is boundary-specific: crashes before dispatch reconcile to one committed submission and exactly
  one harness invocation after retry; crashes after the durable dispatch marker preserve the original zero-or-one
  invocation and never add another automatically; the injected post-dispatch/pre-ack crash proves that a recorded
  invocation is retained as uncertain/held and retry keeps the count at one. A claim deliberately left incomplete
  executes zero times. All rows require one matching
  message/attempt, no attachment loss, and no incomplete/orphan exposure.
- TI03–TI08 use component/API tests with those production-shaped filesystem collaborators. The `conversation-loop`
  command profile boots the assembled runtime on isolated data and drives two actual browser contexts through the
  repository's Agent Browser scenario mechanism. It records timing samples and browser evidence rather than scanning
  Dart/HTML strings; TI08 runs the actual-runtime two-browser Q6 case.
- TI02's Dart check proves only parseable, referenceable, accessible HTML structure. TI09–TI10 extend the existing Node
  controller-harness and rendered-template tests for logic. TI11 performs the later actual-browser comparison against
  TI02 at 375/390/768/1440 px, both themes, 200% zoom, and reduced motion; real iOS/Android keyboard proof and owner
  journeys remain S09 external release gates.

### Validation

- Extend TC-07A and the visual-profile chat scenario with the changed composer states. The TI11 browser run retains
  screenshots, computed styles, timing samples, accessibility output, and interaction results; no marker/string
  assertion or screenshot alone can satisfy keyboard, timing, persistence, race, or visual-comparison clauses.

### Execution Contract

- Do not export or execute this FIS in the public repository until `feat/0.26.1` is completed and published. At launch,
  compare `0e605a2038b79c4e8d3164297506eff9a76f8fb4..HEAD` across every Code Patterns surface and reconcile the FIS against
  the published contracts before editing. Preserve all accepted E1/E2 behavior if symbols moved.
- TI01 lands before every task that uses its fixture/profile. TI02 refines the two existing integrated assets before
  TI09–TI11 implement or compare UI. TI03–TI08 establish host contracts before TI09–TI10 consume them; TI11 runs last
  and compares the served implementation to TI02 while retaining S09's real-device gate.
- TI03 must land the recoverable claim and idempotent file reconciliation before TI04/TI05 admit attachments or work.
  Neither startup nor request handling may call `TurnManager` from `preparing`, integrity-failed, dispatching, running,
  or uncertain state. Only the claim's final atomic `committed` rewrite authorizes a first dispatch, and the durable
  dispatch marker forbids restart replay even when the client never received an acknowledgement.

## Implementation Observations

### Run: 2026-09-14 12:21 UTC – observations

#### DRIFT

S03 source anchors reconciled from published 0.26.1 ef24b3302e936c4ff6183158da8462b866dbd7d2 to integration preparation 5a60802a8e1b15b025aa4c818edf27eaab5fad7e. No named source anchor moved or disappeared. Preserve stream_handler.dart immediate `: connected\n\n` SSE flush; DcChatController uses HTMX 4 `htmx:before:request`, `htmx:finally:request`, `htmx:sse:before:message`, and `event.detail.ctx.sourceElement`. Retain turn_id-based disconnect/status reconciliation, pagination anchor restoration, duplicate-send prevention and deferred input enablement until authoritative refresh. These are baseline constraints, not a second live-state authority. Earlier plan overview/sequencing publication-hold wording is stale; publication was independently confirmed and upstream wording should be reconciled.

### Run: 2026-09-14 16:00 CEST – verification scheduling

- ASSUMPTION: The user's question indicates a preference to defer full binary builds, broad fast/full suites, Docker, browser/visual, and hard-crash integration execution to the final plan gate. Pending an explicit override, S03 implementation still supplies every required fixture and proof target, while this story run executes focused unit, static, and analysis checks only, records every deferred proof with its exact command and evidence contract, and does not treat a deferred command as passed.

### Run: 2026-09-14 17:10 CEST – all-origin projection scope

- CLARIFICATION: SC01 and TI03 scope the recoverable submission claim to ordinary conversations. S05's restart clause likewise names an ordinary attempt. Existing channel and cron admission therefore remains on its established `TurnManager`/`MessageService` path. S05, SC04, and TI08 still require those origins to invalidate and project into the same retained conversation snapshot with their stable message and turn identities, work state, and existing cancellation semantics. The implementation reuses those authorities and does not fabricate browser submission claims for channel or cron work.
