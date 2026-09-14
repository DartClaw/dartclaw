# Conversation Inbox and Attention

**Plan**: dev/bundle/docs/specs/0.27/plan.json
**Story-ID**: S06

## Feature Overview and Goal

**Intent**: Give the owner one stable, bounded conversation inbox and persistent attention center that make unread work,
local drafts, execution state, settling, archive, and exact pending requests discoverable without changing approval
authority or reordering conversations whenever activity arrives.

**Expected Outcomes**:

- [OC01] The flat inbox keeps deterministic order, complete counts, bounded navigation, and visibly distinct read,
  draft, attention, execution, settled, and archived state across activity, filtering, paging, and concurrent viewers.
- [OC02] Manual and automatic settling are reversible, race-safe lifecycle changes with explicit eligibility; the three
  specified work signals restore settled conversations and device-local drafts remain discoverable.
- [OC03] A persistent, paginated attention center projects the same durable requests and results as the transcript and
  sidebar while keeping feed read/dismiss markers independent from approval resolution and conversation read state.
- [OC04] Inbox and attention journeys remain usable with keyboard, touch, resize, drawer, zoom, theme, reduced-motion,
  outage, reconnect, and representative-load conditions.

## Required Context

Path resolution is deliberate: `dev/...` and `packages/...` are public-repository-root paths, resolved read-only during
this private authoring pass at `../dartclaw-public/<path>` against commit
`0e605a2038b79c4e8d3164297506eff9a76f8fb4` and consumed unchanged from the public root after the deferred export.
`prd.md`, `plan.json`, producer FIS basenames, and `../../wireframes/...` are private-canonical references relative to
this FIS; the future disposable implementation bundle preserves or supplies those relative targets without rewriting
this prose.

- `prd.md#fr7-inbox-lifecycle-and-attention` – full E6/Q8 contract plus the inbox, settling, read, local-draft,
  attention, filtering, ordering, paging, elapsed-running, and lineage behavior owned by this story.
- `prd.md#e11-phone-keyboard-and-assistive-technology-quality` – feature-specific phone, keyboard, focus, touch,
  zoom, theme, reduced-motion, contrast, live-region, and drawer requirements.
- `prd.md#fr10-accessible-experience-and-operational-qualification` – retained D14 muted-dot and C06 per-source
  polling-notice work, wireframe-first sequencing, and the boundary between feature proof and S09 release evidence.
- `prd.md#constraints` – prototype proportionality, one-authority constraints, private-only authoring hold, and the
  published-0.26.1 reconciliation gate.
- `plan.json#sharedDecisions` – opaque workspace principal, stable attempt/request identity, one approval-resolution
  authority, and the rule that inbox/read/feed state remains a projection.
- `s04-inspectable-and-recoverable-history.md#technical-overview` – durable message/tool/request/result identity,
  bounded history windows, exact approval resolution, read anchors, and source/branch lineage consumed here.
- `s03-reliable-conversation-loop.md#technical-overview` – authoritative conversation revisions, invalidation-only
  live updates, browser-local drafts, and the actual-runtime two-browser fixture extended here.
- `s01-agent-workspace-execution.md#technical-overview` – server-derived opaque ownership context used for visibility;
  S01 implements PRD D1's explicit configuration and supplies configured or absent workspace context without inbox choosing a principal.
- `dev/state/PRODUCT.md#proportionality` – one-owner, one-process scale and the prohibition on a second storage
  authority, distributed runtime, or speculative client state machine.
- `dev/guidelines/TESTING-STRATEGY.md#layer-2--component--integration-tests` – production-shaped filesystem/API tests,
  controlled clocks, deterministic races, and actual-runtime browser proof.

## Deeper Context

- `../../wireframes/session-sidebar-control-plane.html:120` – existing integrated flat-inbox, settle-tail, lineage,
  elapsed-running, local-draft, resize, and mobile drawer composition to refine before UI implementation.
- `../../wireframes/notification-center.html:70` – existing integrated notification panel to refine into the persistent,
  paginated request/result projection and its read, dismiss, unavailable-action, and outage states.
- `dev/design-system/DESIGN.md#status-indicators` – current dot ladder; the accepted D14 requirement adds a muted/
  disabled variant rather than continuing the current disabled-to-idle mapping.
- `dev/design-system/DESIGN.md#notifications` – canonical attention-row grammar, touch floor, unread edge, status text,
  and focus treatment.
- `dev/design-system/DESIGN.md#mobile-sidebar-contract` – canonical focus trap, inert main content, scrim, Escape, and
  focus-restoration behavior.
- `dev/guidelines/HTMX-GUIDELINES.md#recommended-patterns` – server-rendered fragments, OOB count updates, explicit
  navigation, and Stimulus ownership of DOM-local resize/focus behavior.
- `dev/guidelines/TRELLIS-GUIDELINES.md#security--the-rules-that-matter-most` – escaped text and attribute boundaries
  for titles, reasons, result summaries, source labels, filters, and lineage.

## Acceptance Scenarios

- **S01 [OC01,OC04] [runtime] Mixed-state inbox remains stable, complete, bounded, and actionable**
  - **Given** 200 visible conversations containing unread, needs-input, failed, running, done, browser-local draft,
    settled, and archived examples, including parent/fork lineage, long titles, identical creation timestamps, a current
    selection beyond the first page, and actionable rows outside the viewport
  - **When** messages, results, elapsed-running labels, and read markers change; the owner pages, searches, or applies
    compact state filters; or a live invalidation is duplicated, missed, replayed, or reconciled
  - **Then** active membership stays in descending `createdAt` order with session ID as the deterministic tie-breaker;
    activity never reorders it; creation inserts once; settle removes once; and unsettle restores the same position
  - **And** orthogonal text/glyph states distinguish unread, needs input, failed, running, done, draft, settled, and
    archived without using color alone; parent/fork lineage and running elapsed time remain visible; stored order never
    changes under search/filter; and the current conversation stays reachable across bounded cursor pages
  - **And** total and **Waiting on you** counts are computed over all authorized matching conversations before page,
    viewport, or active-filter clipping; next-attention navigation reaches an offscreen/filtered request without
    reordering; active filters remain clear; and an empty filtered result offers a filter-clear action
  - **Proof**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case q8-q10-inbox-attention --compare-wireframes` –
    planned, unexecuted at spec time; retained actual-browser state, order, count, pagination, filter, lineage, elapsed,
    screenshot, and timing evidence must cover all eight states and offscreen attention

- **S02 [OC01,OC02] Manual settle and restore use one stale-safe rule for row and bulk actions**
  - **Given** an authorized active inbox containing eligible and ineligible rows plus a paginated slim settled tail
  - **When** the owner settles one row, submits a bulk selection whose members change concurrently, reads a settled
    conversation, follows live content into it, restores it, pages the settled tail, or explicitly archives it
  - **Then** row and bulk members pass the same server-side eligibility and expected-revision check under the session
    mutation authority; each accepted member changes once; stale or ineligible members remain unchanged; and a partial
    bulk result names each failure while retaining successful members
  - **And** reading or receiving non-triggering activity in a settled conversation does not restore it; manual restore
    returns it to its deterministic active position; settle remains reversible and visually distinct from archive; and
    archived conversations remain outside both active and settled membership while their permitted history stays readable
  - **Proof**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/inbox_lifecycle_contract_test.dart --name "row and bulk settle share stale-safe eligibility and reversible membership"` – planned, unexecuted at spec time; mixed eligibility, stale revisions, partial failure, paging, live reading, restore, and archive cases must preserve exact membership and ordering

- **S03 [OC02] Automatic settling is off by default and reevaluates only eligible completed conversations**
  - **Given** `sessions.auto_settle_idle_days` is absent or zero, then configured to a positive whole-day value, and
    completed conversations vary by idle age, unread state, failure, running work, waiting/needs-input request, and known
    draft state in the evaluating browser
  - **When** the existing maintenance pass reaches the configured idle boundary, an associated task reports completion,
    or a completed conversation later becomes read and thereby eligible
  - **Then** absent/zero configuration performs no automatic settle; a positive value settles only completed, read,
    non-failed, non-running, non-waiting, non-attention conversations at or beyond the boundary; the task-completion
    signal invokes the same eligibility function; and the later read transition causes one reevaluation
  - **And** merely viewing a conversation never settles it; an evaluating viewer skips any conversation with a known
    local draft; negative or non-integral configuration is rejected; and no client claims that another device lacks a
    draft it cannot observe
  - **Proof**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/auto_settle_contract_test.dart` – planned, unexecuted at spec time; a controlled clock and associated task transitions must prove disabled/default, positive threshold, exact boundary, exclusions, read reevaluation, and idempotence without real-time sleeps

- **S04 [OC01,OC02,OC03] Read boundaries and three work signals converge without conflating state**
  - **Given** two authorized browser contexts observe one settled conversation and another active conversation, with
    distinct stable message/read anchors, feed markers, local drafts, and pending request identity
  - **When** a new message is durably persisted into the settled conversation, a turn starts there, or a new pending
    input request is durably recorded there
  - **Then** each of those three signals auto-unsettles it once and restores its deterministic active position, while
    ordinary history viewing, typing a local draft, feed read/dismiss, and unrelated result activity do not
  - **And** a visible message is marked read only when its boundary is visible in a foreground tab; hidden-tab receipt
    or SSE invalidation does not advance the read anchor; synchronized server read/attention markers converge across
    tabs/devices; reading neither approves nor unsets by itself; and a draft remains local and distinct from queued work
  - **Proof**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/inbox_lifecycle_contract_test.dart --name "read anchors and exactly three work signals preserve independent state"` – planned, unexecuted at spec time; two-viewer controlled delivery must prove foreground boundaries, hidden/replayed events, all positive triggers, every exclusion, and restored order

- **S05 [OC03,OC04] Attention actions project exact durable requests and results without another approval state**
  - **Given** the S04 authority retains completion, failure, needs-input, pending approval, resolved, expired, and archived
    request/result events with stable event, conversation, attempt, request, and result identities
  - **When** the owner opens or pages the attention center, follows an item to its transcript anchor, marks feed items
    read, dismisses a terminal item, or invokes approve/reject on a still-pending request
  - **Then** the feed renders each authorized event identity once with readable title, reason/result, source, time, and
    status; its pending action targets that exact request through S04's existing provider authority; and transcript,
    sidebar, feed, action state, and counts reconcile from the same retained record
  - **And** feed read/dismiss markers neither advance transcript read nor settle/restore a conversation nor resolve a
    request; pending actions cannot be dismissed; resolved/expired/archived actions disappear everywhere; archive uses
    the normal request-cancellation lifecycle; historical items remain readable; and a later request with a new identity
    becomes a new item
  - **And** unknown, stale, malformed, mismatched-attempt, expired, resolved, archived, or unauthorized direct action
    requests fail before any provider response or marker change; there is no feed-owned approval status or second
    confirmation/approval state
  - **Proof**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/attention_contract_test.dart --name "feed markers stay separate while exact pending requests resolve once"` – planned, unexecuted at spec time; pagination, identity deduplication, marker combinations, archive cancellation, races, and every negative action path must show zero duplicate side effects

- **S06 [OC01,OC03,OC04] [runtime] Concurrent viewers recover missed state and receive one persistent outage notice per source**
  - **Given** initiating and passive viewers observe chat, channel, cron, and other-tab changes while attention and inbox
    polling sources have stable `sourceRef` values and the network can fail, recover, duplicate delivery, reconnect, or
    restart the server
  - **When** messages, results, needs-input requests, approval resolution, read/dismiss markers, settle/archive, access
    revocation, and repeated poll failures occur in controlled interleavings
  - **Then** both viewers reconcile authoritative revisions so transcript, sidebar, attention feed, actions, and counts
    agree without duplicate messages/items or approval responses; missed events and restart recover from durable state;
    and revoked viewers cannot fetch or act on stale content
  - **And** the first failure from each `sourceRef` creates one persistent labelled notice, repeated failures from that
    source update neither count nor DOM entry, a different source gets its own notice, the first successful response
    clears its source notice, and all existing polling intervals and retry cadence remain unchanged
  - **Proof**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case q6-q8-inbox-attention --compare-wireframes` –
    planned, unexecuted at spec time; two actual browser contexts and restart/network barriers must retain request logs,
    screenshots, state revisions, notice source keys, and action counts through failure and recovery

- **S07 [OC01,OC02,OC03,OC04] [runtime] Responsive triage works with resize, keyboard, drawer, and local drafts**
  - **Given** the Q10 ten-conversation mixed-state fixture, a local draft on one device whose conversation is settled
    remotely, both themes, 200% zoom, reduced motion, and 375, 390, 768, and 1440 CSS-pixel viewports
  - **When** the browser runs the machine triage journey using keyboard and touch-sized controls, resizes the desktop
    sidebar from its 260-pixel default within documented clamps, resets it, and opens/closes the mobile drawer
  - **Then** every unread/needs-input/failed/running/done/draft/settled/archive target and every offscreen/filtered request
    is found without coaching; bulk and row settle affect only selected eligible targets; **Drafts on this device** keeps
    the local draft discoverable after remote settle; and no approval or conversation action targets the wrong identity
  - **And** the resize separator exposes keyboard adjustment and reset; the mobile drawer traps focus, makes the main
    region inert, closes on Escape/scrim, and restores focus; the direct **New Chat** command remains available outside
    the drawer; interactive targets meet the touch floor; and bounded live regions announce outcomes without chatter
  - **Proof**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case q8-q10-inbox-attention --compare-wireframes` –
    planned, unexecuted at spec time; the actual served runtime must retain screenshots, computed styles, DOM/a11y,
    focus/keyboard, network, timing, and console evidence at every specified viewport/theme/zoom/motion combination

## Structural Criteria

- **SC01** `SessionService` remains the sole filesystem authority for conversation membership and owner marker metadata;
  mutations serialize through `SessionMutationCoordinator`, use optimistic revisions, and emit invalidations only after
  durable state. No SQL mirror, event store, or browser-owned server state is introduced.
- **SC02** Inbox, transcript read state, attention feed, and action controls consume S03/S04 stable conversation,
  message, attempt, event, request, result, and branch identities. S04 remains the only approval-resolution authority;
  the feed stores only owner read/dismiss markers keyed to durable event identity.
- **SC03** Active/settled/archive membership, read/unread, execution status, needs-input, and browser-local draft are
  orthogonal facts rather than one lossy status enum. The browser may overlay its own IndexedDB draft indicator but may
  not persist it as shared server truth or infer drafts on another device.
- **SC04** Auto-settle adds one `SessionConfig` field and reuses the existing maintenance schedule plus
  `TaskStatusChangedEvent`; every trigger calls the same durable eligibility function. The live event is a prompt to
  reevaluate authoritative task/session state, never completion truth by itself.
- **SC05** Server view models and Trellis templates own escaped content and semantic state; HTMX owns fragment navigation
  and OOB totals; Stimulus owns DOM-local filtering aids, resize, drawer, focus, foreground visibility, and IndexedDB
  draft overlay. SSE and polls invalidate projections rather than mutate rendered state independently.
- **SC06** D14 adds one canonical `.status-dot--muted` treatment and moves disabled callers off `.status-dot--idle`; C06
  adds stable `sourceRef`-keyed persistent failure/recovery behavior to the shared notice seam. Both changes remain
  within the existing Afterglow and polling vocabulary.
- **SC07 [runtime]** S03's conversation-loop profile remains the one actual-runtime fixture. It grows deterministic mixed-state,
  paging, multi-viewer, restart, auth-revocation, network, clock, focus, timing, and screenshot controls rather than
  introducing a second browser harness or source-marker substitute.
- **SC08** Every server read and mutation uses S01's already-resolved opaque principal and existing visibility rules;
  filters, totals, pagination cursors, feed links, and direct action endpoints cannot reveal excluded conversations or
  use client-supplied project/workspace context as authority.

## Scope & Boundaries

### Work Areas

- Filesystem session metadata, stable active/settled/archive projections, read anchors, owner attention markers, and
  one automatic-settle eligibility service.
- Bounded inbox/settled/feed query and mutation routes plus server-rendered sidebar, attention, and count fragments.
- Existing session sidebar and notification-center wireframes, templates, Afterglow status/notification canon, and
  Stimulus behavior for filtering aids, draft overlay, resize, drawer, focus, and outage notices.
- Component/integration tests and the existing actual-runtime conversation-loop profile for full E6/Q8 and the machine
  multi-viewer/triage portions of Q6/Q10.

### What We're NOT Doing

- A second approval workflow, client-selected approval authority, feed-owned request lifecycle, or extra confirmation
  state; S04 validates and resolves the exact request.
- Reordering active conversations by activity, treating read/draft/attention as one lifecycle enum, synchronizing
  browser drafts, or claiming knowledge of drafts on another device.
- A notification delivery service, operating-system notifications, multi-user assignment, a database/event store,
  virtualized lists, or a client rendering framework.
- S09's real iOS/Android keyboard and safe-area/paste checks, five owner device tasks, public/private documentation
  reconciliation, or release qualification. No unattended or synthetic result can satisfy those external gates.

## Architecture Decision

**Approach**: Extend filesystem session metadata with orthogonal lifecycle/read/attention markers and expose bounded
server projections keyed by S03/S04 identities. Use one eligibility service for row, bulk, maintenance, task-completion,
and read-transition settlement checks. HTMX reconciles server-rendered fragments while the existing shell/chat
controllers own local draft, resize, drawer, focus, foreground, and keyed polling-notice behavior.

**Why this over alternatives**: Session, request/result, exact approval, live revision, maintenance, and browser-draft
authorities already exist. Extending those seams makes concurrent/restart behavior inspectable at prototype scale while
avoiding an inbox database, notification event store, duplicate approval machine, global client store, or new scheduler.

## Technical Overview

Session metadata records settle state/time and owner read plus attention marker positions without replacing message or
request records. Active rows sort by immutable creation time and ID; bounded cursors preserve that order, while totals
are computed before pagination. The attention projection pages durable S04 events and joins independent owner read/
dismiss markers. Exact pending actions call S04's route. All mutations validate opaque principal, target identity, and
expected revision under the session coordinator, persist first, advance the S03 revision, then invalidate clients.

`sessions.auto_settle_idle_days` is a non-negative integer with zero/default meaning disabled. Positive values let the
existing maintenance pass evaluate idle conversations; associated task-completion and later-read transitions call the
same evaluator. The three durable work signals auto-unsettle. Browser drafts stay in S03's device-local IndexedDB and
are overlaid into server rows and the fixed local-drafts filter. A shared poll notice registry keys persistent failures
by `sourceRef`, removes each on its first recovery, and leaves source cadence untouched.

## Code Patterns & External References

```text
# type | path#anchor                                                               | why needed (intent)
file   | packages/dartclaw_kernel/lib/src/models.dart#Session                      | Existing immutable filesystem session metadata model
file   | packages/dartclaw_kernel/lib/src/session_config.dart#SessionConfig         | Existing sessions namespace and typed/defaulted config seam
file   | packages/dartclaw_kernel/lib/src/config_meta/agent_fields.dart#_agentFields | Existing sessions configuration metadata owner
file   | packages/dartclaw_core/lib/src/storage/session_service.dart#SessionService | Existing atomic filesystem session CRUD/list authority
file   | packages/dartclaw_core/lib/src/storage/message_service.dart#MessageService | S04 durable messages/read anchors and ordered history owner
file   | packages/dartclaw_core/lib/src/events/task_events.dart#TaskStatusChangedEvent | Existing associated-task reevaluation signal
file   | packages/dartclaw_runtime/lib/src/concurrency/session_mutation_coordinator.dart#SessionMutationCoordinator | Existing per-session serialization seam
file   | packages/dartclaw_runtime/lib/src/maintenance/session_maintenance_service.dart#SessionMaintenanceService | Existing scheduled session scan reused for idle evaluation
file   | packages/dartclaw_runtime/lib/src/web/sidebar_data_builder.dart#SidebarDataBuilder | Existing flat session projection and typed row view models
file   | packages/dartclaw_runtime/lib/src/templates/sidebar.dart#sidebarTemplate    | Existing server-rendered session sidebar owner
file   | packages/dartclaw_runtime/lib/src/templates/topbar.dart#topbarTemplate      | Existing shell-wide home for persistent attention access
file   | packages/dartclaw_runtime/lib/src/static/controllers/dc_shell_controller.js#DcShellController | Existing drawer, sidebar mutation, HTMX failure, and focus owner
file   | packages/dartclaw_runtime/lib/src/static/controllers/dc_chat_controller.js#DcChatController | Existing foreground/read, local-draft, live, and turn-poll owner
file   | packages/dartclaw_runtime/lib/src/static/controllers/shared.js#showToast   | Existing notice creation/removal seam widened for keyed persistence
file   | packages/dartclaw_runtime/lib/src/web/web_utils.dart#toastTriggerHeader     | Existing server-triggered notice payload widened with sourceRef
file   | dev/design-system/components.css#status-dot                                 | Canonical status ladder and notification-row styles
wire   | ../../wireframes/session-sidebar-control-plane.html:120                    | Integrated inbox/settled/resize/drawer reference to refine
wire   | ../../wireframes/notification-center.html:70                               | Integrated attention-feed reference to refine
```

## Constraints & Gotchas

- **Critical**: Settling, restoring, read advancement, attention markers, and auto-unsettle serialize with the same
  conversation revision. A stale bulk request is evaluated member by member; it cannot silently apply a whole stale set.
- **Critical**: An attention item is a projection of one durable S04 event/request/result. Feed read/dismiss and
  transcript read are separate markers, and no feed code persists or infers approval resolution.
- **Critical**: All counts and next-attention navigation cover authorized offscreen and filtered rows before paging.
  A visible subset or browser DOM scan cannot be the source of counts, bulk eligibility, or target selection.
- **Constraint**: Stable active position means descending immutable `createdAt`, then session ID. Settled paging uses
  descending `settledAt`, then session ID. Search/filter never writes either order.
- **Constraint**: Auto-settle sees only server facts plus the evaluating browser's disclosed local-draft IDs. It skips
  those IDs and never treats absence from that browser as proof that no device has a draft.
- **Constraint**: The existing design canon maps disabled to idle, but the accepted D14 requirement supersedes that
  mapping for this story. Add the narrow muted variant and retain idle for genuinely inactive state.
- **Constraint**: Execute only after 0.26.1 is published. Reconcile
  `0e605a2038b79c4e8d3164297506eff9a76f8fb4..HEAD` across every Code Patterns surface before editing and preserve the
  accepted behavior if symbols moved.
- **Avoid**: Counting wireframe source markers or screenshots alone as visual proof. Actual served browser runs must
  retain screenshots plus DOM, computed-style, accessibility, focus, keyboard, timing, network, and console evidence.

## Implementation Plan

### Implementation Tasks

- **TI01** Deterministic inbox fixtures expose mixed state, concurrency, paging, clocks, and outages
  - Extend S03's conversation-loop fixture/profile with 200 stable-order conversations, Q10's ten mixed-state subset,
    local drafts per browser context, exact S04 request/result records, controlled task/message/read clocks, bulk races,
    network/restart barriers, auth revocation, polling sources, and retained measurement hooks.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/inbox_fixture_test.dart` – planned, unexecuted at spec time; fixtures deterministically expose all E6/Q8 and machine Q6/Q10 cases without real-time sleeps, synthetic acceptance, or a second authority
  - **SATISFIES**: SC07

- **TI02** Existing inbox and notification wireframes define linked accepted states before UI work
  - Refine `docs/wireframes/session-sidebar-control-plane.html` and `docs/wireframes/notification-center.html` themselves
    with all eight state distinctions, compact filters/counts, offscreen attention, row/bulk settle, paged tail/feed,
    local-draft remote-settle, exact action, outage/recovery, resize, drawer, focus, phone, and desktop states.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/static/inbox_attention_wireframe_contract_test.dart` – planned, unexecuted at spec time; both existing assets parse with accessible linked state fixtures and no replacement mockup, as structural reference evidence only
  - **SATISFIES**: SC05, SC06, SC07

- **TI03** Session metadata carries orthogonal settle, read, and attention markers with stable migration
  - Extend `Session`, config metadata, and `SessionService` JSON compatibility; preserve immutable creation order and add
    revisioned settle/time, owner read anchor, feed read anchor, and dismissed event IDs with bounded retention. Keep
    execution/attention/draft outside a lossy lifecycle enum and visibility under S01's opaque principal.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/session_inbox_metadata_test.dart packages/dartclaw_kernel/test/session_config_test.dart` – planned, unexecuted at spec time; legacy/new JSON, zero/positive/invalid config, atomic writes, marker bounds, stable sort ties, and opaque-principal filtering pass
  - **SATISFIES**: S01, S02, S03, S04, SC01, SC03, SC04, SC08

- **TI04** Row and bulk lifecycle mutations share revisioned eligibility and partial-result semantics
  - Build one settle/restore/archive service over TI03 and `SessionMutationCoordinator`; accept expected revisions per
    member, preserve successes when other bulk members fail, restore by creation order, and keep settle distinct from
    S04's normal archive/request-cancellation path.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/inbox_lifecycle_contract_test.dart --name "row and bulk settle share stale-safe eligibility and reversible membership"` – planned, unexecuted at spec time; eligible, ineligible, stale, duplicate, partial, restore, settled-page, and archive cases produce exact per-member results
  - **SATISFIES**: S02, SC01, SC03, SC08

- **TI05** One eligibility service handles idle, task-completion, and read-transition auto-settle checks
  - Reuse `SessionMaintenanceService` for positive-day scans and subscribe to `TaskStatusChangedEvent` only as an
    associated-session reevaluation signal; call the same evaluator after read advancement; persist before invalidation;
    and enforce completion/read/running/failure/waiting/attention/local-draft exclusions.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/auto_settle_contract_test.dart` – planned, unexecuted at spec time; controlled clock, task lookup, event loss/replay, read transitions, default-off, positive threshold, exclusions, local draft disclosure, and restart are idempotent
  - **SATISFIES**: S03, SC01, SC03, SC04

- **TI06** Durable work signals restore settled conversations and foreground boundaries advance read state
  - Wire S04 message persistence, S03 turn start, and S04 pending-input persistence to one auto-unsettle operation;
    accept foreground visible-message boundaries for read advancement and reject hidden/SSE-only advancement. Reconcile
    markers across clients without making read, draft, feed, or ordinary result activity an unsettle trigger.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/inbox_lifecycle_contract_test.dart --name "read anchors and exactly three work signals preserve independent state"` – planned, unexecuted at spec time; all three triggers, all exclusions, hidden/foreground viewers, duplicate events, stable restore position, and revision races pass
  - **SATISFIES**: S04, SC01, SC02, SC03, SC05, SC08

- **TI07** Bounded inbox projections expose complete totals, filters, lineage, elapsed state, and settled pages
  - Extend `SidebarDataBuilder` and authorized query routes from TI03–TI06; derive independent state axes from S03/S04,
    page active/settled sets with stable cursors, compute totals and next-attention before clipping, retain current access,
    and expose server-prepared filter/empty/partial-bulk view models.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/inbox_projection_contract_test.dart` – planned, unexecuted at spec time; 200 rows prove deterministic ordering, complete filtered/offscreen counts, current access, cursor integrity, lineage, elapsed running, eight state distinctions, and authorization
  - **SATISFIES**: S01, S02, S04, SC01, SC02, SC03, SC05, SC08

- **TI08** Attention projection pages exact durable events and independent owner markers
  - Build the bounded feed from S04 event/request/result records; deduplicate by event identity; return readable source,
    reason/result, timestamp, transcript anchor, and current action availability; persist only bounded read/dismiss markers;
    retain archived history; and make pending actions non-dismissible.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/attention_contract_test.dart --name "feed projection pages durable events with independent owner markers"` – planned, unexecuted at spec time; completion/failure/needs-input/resolution, pagination, replay, marker combinations, archived history, pending dismissal refusal, and revoked visibility pass
  - **SATISFIES**: S05, S06, SC01, SC02, SC08

- **TI09** Attention actions delegate exact pending requests to S04 once
  - Validate event/conversation/attempt/request identity, principal, expiry, revision, archive, and pending state, then call
    S04's exact action route; render resolution from the durable result and never introduce a feed confirmation or
    approval record. Use the normal request-cancellation lifecycle during archive.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/attention_contract_test.dart --name "feed markers stay separate while exact pending requests resolve once"` – planned, unexecuted at spec time; concurrent viewers, repeat delivery, unknown/stale/malformed/mismatch/expiry/archive/revocation, and later-request identity forward at most one provider response
  - **SATISFIES**: S05, S06, SC01, SC02, SC08

- **TI10** Sidebar fragments render stable lifecycle controls, complete counts, and local-draft discovery
  - Implement TI02/TI07 in `sidebarTemplate` with escaped view models, semantic glyph/text state, compact filters, next
    attention, row/bulk results, bounded settled pager, lineage, elapsed running, and accessible empty state. Overlay S03
    IndexedDB draft IDs and keep **Drafts on this device** fixed after remote settle without changing server order/truth.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/templates/inbox_template_test.dart packages/dartclaw_runtime/test/static/inbox_controller_test.dart` – planned, unexecuted at spec time; rendering/controller cases cover every state, escaping, counts, filters, bulk outcomes, paging, remote settle, local draft overlay, stable identity, and HTMX swaps
  - **SATISFIES**: S01, S02, S03, S04, S07, SC03, SC05, SC08

- **TI11** Attention fragments render persistent feed navigation and exact available actions
  - Implement TI02/TI08/TI09 in the shell-wide topbar attention surface using canonical notification rows; retain
    unread totals and pagination, expose transcript links and readable reason/result, preserve focus across OOB/live
    reconciliation, and remove actions immediately when durable state makes them unavailable.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/templates/attention_template_test.dart packages/dartclaw_runtime/test/static/attention_controller_test.dart` – planned, unexecuted at spec time; accessible rendering, escaping, focus, paging, read/dismiss independence, exact action IDs, pending non-dismissal, archive, expiry, duplicate updates, and swap lifecycle pass
  - **SATISFIES**: S05, S06, S07, SC02, SC05, SC08

- **TI12** Canonical drawer and resize behavior keeps inbox commands reachable at every supported width
  - Apply TI02 through `DcShellController`: 260-pixel desktop default, documented min/max clamps, pointer drag, keyboard
    adjustment/reset, persisted width, and mobile drawer focus trap/inert/scrim/Escape/restoration. Keep a direct labelled
    **New Chat** command reachable outside the closed drawer and preserve 44-pixel touch targets and bounded announcements.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/static/inbox_controller_test.dart --name "resize and drawer preserve keyboard focus commands and touch targets"` – planned, unexecuted at spec time; pointer/key/reset/clamp/persistence, breakpoint changes, trap/inert/scrim/Escape/focus restoration, New Chat access, and live-region bounds pass
  - **SATISFIES**: S07, SC05, SC07

- **TI13** Muted status and keyed polling notices close D14 and C06 without cadence changes
  - Add `.status-dot--muted` to Afterglow and update disabled callers while retaining idle semantics. Extend the shared
    notice API and server trigger payload with stable `sourceRef`, persistent failure, and recovery clearing; tag each
    existing repeating poll source, including chat turn status, and retain its exact interval/retry scheduling.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/static/status_poll_notice_contract_test.dart packages/dartclaw_runtime/test/static/design_system_contract_test.dart` – planned, unexecuted at spec time; disabled/idle remain distinct and controlled multi-source failures yield one persistent notice per source, clear independently on recovery, and preserve captured request cadence
  - **SATISFIES**: S06, S07, SC05, SC06

- **TI14** Component and API suites prove E6/Q8 plus machine multi-viewer Q6/Q10 semantics
  - Run TI01 against TI03–TI13 with temporary filesystem storage, direct handlers, fake provider action authority,
    controlled clocks/barriers, two principals/viewers, restart, duplicate/missed invalidations, local drafts, and negative
    side-effect counters. Cover the full scenario matrix without waiting for owner/device acceptance.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/inbox_lifecycle_contract_test.dart packages/dartclaw_runtime/test/conversation/inbox_projection_contract_test.dart packages/dartclaw_runtime/test/conversation/attention_contract_test.dart` – planned, unexecuted at spec time; S01–S06 and SC01–SC08 pass with exact identity, revision, persistence, authorization, and zero-rejected-side-effect assertions
  - **SATISFIES**: S01, S02, S03, S04, S05, S06, SC01, SC02, SC03, SC04, SC05, SC06, SC08

- **TI15** Served inbox and attention journeys prove Q8/Q10 triage and multi-viewer Q6 recovery
  - Run after TI01–TI14 against the assembled runtime and both actual browser contexts. Compare TI02's accepted states at
    every specified viewport/theme/zoom/motion setting and retain screenshots, computed styles, DOM/a11y, focus/keyboard,
    request/timing, state revision, and console evidence. Keep failed observations beside reruns.
  - **Verify**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case q6-q8-q10-inbox-attention --compare-wireframes` – planned, unexecuted at spec time; S01/S06/S07 pass using served runtime evidence, with no source-marker, static-file, generated walkthrough, screenshot-only, or synthetic acceptance substitute
  - **SATISFIES**: S01, S06, S07, SC05, SC06, SC07, SC08

### Testing Strategy

- TI01 extends S03's fixture. TI03–TI09 and TI14 use real temporary-directory session/message authorities, direct Shelf
  handlers, the S04 fake provider action boundary, controlled clocks and race barriers, explicit authorization, and
  side-effect counters. TI10–TI13 use Trellis/template and DOM-controller tests for presentation logic.
- TI02 proves only that accepted wireframe states are structurally referenceable. TI15 boots the assembled served
  runtime and drives actual browser contexts; static source markers and screenshots alone cannot establish behavior,
  computed style, accessibility, focus, timing, persistence, ordering, exact action, or outage recovery.

### Validation

- Extend the existing conversation-loop browser profile and TC-07A with full E6/Q8, Q6 multi-viewer convergence, and
  Q10's machine triage set. Preserve browser screenshots plus DOM/computed-style/accessibility/focus/keyboard/network/
  timing/console evidence at 375, 390, 768, and 1440 CSS pixels, both themes, 200% zoom, and reduced motion.
- Real iOS Safari and Android Chrome keyboard/safe-area/paste checks and the five owner tasks remain S09 external release
  gates. A missing or failed external observation stays open; no human-wait task, emulation, coached walkthrough, or
  machine-generated result satisfies it.

### Execution Contract

- Do not export or execute this FIS in the public repository until 0.26.1 is published. At launch, compare
  `0e605a2038b79c4e8d3164297506eff9a76f8fb4..HEAD` across every Code Patterns surface and reconcile moved/changed
  contracts before editing.
- S03's landed producer contract supplies conversation revisions, live invalidation, browser-local drafts, and the
  actual-runtime fixture. S04's landed producer contract supplies exact durable request/result identity, history/read
  anchors, branch lineage, and the sole approval-resolution authority. S01 supplies the pinned opaque principal; its D1
  absent-workspace default remains outside this scope.
- TI01 and TI02 land first. TI03 precedes TI04–TI09; TI04–TI09 precede TI10/TI11; TI02/TI07 precede TI12; TI13 may land
  beside the presentation work; TI14 runs after component work; and TI15 runs last against the served implementation.

## Implementation Observations

- **Drift Notes:** No product-scope drift. The bounded implementation review fixed concurrent continuation with one
  versioned opaque `(timestamp, stable ID)` keyset cursor, placed attention expected-revision enforcement inside S04's
  existing approval coordinator operation, and limited pending-input restore to newly persisted requests.
- TI15 browser, visual and integration execution remains deferred to the final plan gate under the dispatch timing
  override. The served two-viewer, exact-action, deep-link-focus, paging-race, keyed-outage, drawer, zoom, theme and
  structured mismatch assertions are authored but are not counted as passed without their retained artifacts.
