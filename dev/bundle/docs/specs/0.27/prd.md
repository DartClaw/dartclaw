# Product Requirements Document: 0.27 Agent Workspaces and Chat & Session Experience

> **Source**: docs/ROADMAP.md#027-workstreams
> **Context**: [0.27 roadmap](../../ROADMAP.md#027-workstreams), [workspace decision D16](../0.25.2/prd.md#decisions-log), [product](../../../../dartclaw-public/dev/state/PRODUCT.md).
> **Related Assets**: [Afterglow](../../../../dartclaw-public/dev/design-system/DESIGN.md), [chat](../../wireframes/chat-conversation-cards.html), [inbox](../../wireframes/session-sidebar-control-plane.html), [commands](../../wireframes/chat-command-palette.html), [global palette](../../wireframes/command-palette-global.html), [attention](../../wireframes/notification-center.html), [September evidence](../../research/chat-session-experience-2026-09/research.md).
> **Prepared**: 2026-09-13 19:23 CEST. Planning only; no implementation or quality claim.
> **Authoring baseline**: public `0e605a2038b79c4e8d3164297506eff9a76f8fb4` on `feat/0.26.1`. Version 0.26.1 is now published; `feat/0.27` carries the separately authorized HTMX 4/Trellis preparation and 0.27.0 development pin. Reconcile the feature FIS against that integration baseline before execution. The owner authorized committing these private planning artifacts; no bundle export is included in the preparation.

## Executive Summary

- **Problem**: channel-bound agents have identities but no private workspace; the owner's web conversation loses writing/read continuity and lacks the controls needed to manage concurrent work reliably.
- **Vision**: each configured agent works within its own identity, memory and filesystem boundary; the owner writes, inspects, redirects, finds and returns to conversations through one coherent web experience.
- **Target Users**: one instance owner administering the system, people interacting through explicitly bound channel agents, and authorized read-only knowledge clients. This is not multi-user administration.
- **Success Metrics**: zero unauthorized cross-principal reads/writes in the isolation matrix, with explicitly granted owner-context reads retaining provenance; one execution per accepted submission identity; p95 local feedback ≤100 ms and warm conversation switch ≤200 ms; all E1–E12/Q1–Q10 gates and workspace W1–W6 gates discharged before their respective release claims.

### Capabilities at a Glance

| Requirement | Capability | Priority |
|---|---|---|
| FR1 | Agent workspace identity and execution isolation | Must / P0 |
| FR2 | Workspace memory and scoped knowledge access | Must / P0 |
| FR3 | Effective session context | Must / P0 |
| FR4 | Writing continuity and running-turn controls | Must / P0 |
| FR5 | Stable transcripts and actionable approvals | Must / P0 |
| FR6 | Preserved-history recovery | Must / P0 |
| FR7 | Inbox lifecycle and attention | Must / P0 |
| FR8 | Conversation discovery and human commands | Must / P0 |
| FR9 | Temporary conversations and export | Must / P0 |
| FR10 | Accessible experience and operational qualification | Must / P0 |

### Scope Highlights

- **In scope**: per-agent workspace isolation and memory, full retained web chat/inbox scope, truthful context/capabilities, exact-message search, temporary retention and export.
- **Out of scope**: multi-tenant administration, workflow UI/replay, native app shells, channel command parity, search expansion/reranking, automatic data migration between owners.
- **MVP boundary**: both workstreams satisfy their retained behavior and failure cases. Fewer stories do not remove accepted requirements.

### Key Constraints, Assumptions & Dependencies

- One owner/process/host; extend existing storage, execution policy, guards and search. No second authority, new framework or speculative workspace-management product.
- 0.26 storage/search and 0.25.2 channel binding are shipped prerequisites. Published 0.26.1 plus the HTMX 4 preparation form the baseline to reconcile before feature execution.
- Browser drafts are device-local; accepted ordinary sends/queues are server-durable; temporary state has the explicitly different lifetime in FR9.
- Capability availability is verified per provider/transport/posture. Unsupported is visible, never simulated by relabelling another action.

## Problem Definition

### Problem Statement

Bound personas currently use task-scope composition without an independent memory corpus or daily log. Giving them the owner's workspace would mix another person's identity and private data with the owner's. A selected project is an execution location, not a change of principal.

The web conversation has a usable composer and streaming path, but no persisted browser drafts or accepted user queue, preserved-history fork, durable chat tool/approval display, complete passive-view convergence or product conversation search. The sidebar does not yet implement the accepted stable inbox. These gaps cause lost input, unclear work state and unreliable recovery.

### Evidence & Context

- D13–D16 of the 0.25.2 cycle record establish the interim persona behavior and the accepted independent workspace direction.
- The baseline `SessionService`/`MessageService` still own filesystem session metadata/history; the new full-text and vector services supply the ownership dimension but current conversation/memory callers largely use `owner`.
- Existing project, execution-policy, guard, corpus, skill and scheduler owners are reusable; they currently receive deployment-wide paths in several composition-root call sites.
- Existing Afterglow components and wireframes are available. Integrated state coverage, phone behavior and E/Q acceptance remain unproven.

## Scope

### In Scope

- Agent identity files, canonical memory, daily logs/journal/curation, scoped skills and filesystem/container access; the owner's wiki/knowledge graph remain owner-owned.
- E1–E12 below in full, including backend behavior needed by chat controls, and the six workspace proof gates.
- Human command catalog and the accepted ADR-054 clarification before that catalog ships.
- Public guide/architecture/glossary/changelog and private wireframe/UX/spec reconciliation, included in the plan with explicit ownership.
- The accepted D13/D14/C06/C09 UI-canon fixes; narrowly related accessibility/context defects as settled in the Decisions Log.

### Out of Scope

- Multi-user administration, per-sender arbitration and a new tenant/account model. `user_id` is an existing storage scope, not a new login identity.
- Per-workspace wiki/KG, a second context engine, arbitrary runtime workspace CRUD, automatic corpus moves/merges, and copying owner identity or memory into agents.
- New workflow screens, full run replay, task lifecycle/review redesign, dynamic workflows, workflow studio, native desktop/mobile shells and channel/CLI command parity.
- New ranking/embedding/search backends, reranking, QMD expansion, a new artifact system, executable embeds, JS frameworks or application-wide frontend stores.
- Cross-device draft sync, queue reordering, retrospective title generation, separate successful-answer regeneration, and implicit Git worktrees on conversation forks.
- Global heartbeat/git-sync/self-improvement jobs for every workspace; only the existing memory journal/curation responsibilities become workspace-aware here.

### MVP Boundary

All Must requirements remain release scope. Provider-specific unsupported actions are allowed only where explicitly stated, and cannot turn the whole retained feature into a placeholder. Baseline publication and human/device qualification are external release gates, not synthetic passing tests.

## Functional Requirements

### User Stories

| ID | Story | Acceptance Criteria | Priority |
|---|---|---|---|
| US01 | As the owner, I bind a channel agent to its own workspace so another person's conversation cannot acquire my identity or files. | FR1 and W1/W2/W6 | Must / P0 |
| US02 | As a bound-agent user, I build that agent's memory while requesting only knowledge its policy permits. | FR2 and W3–W5 | Must / P0 |
| US03 | As the owner, I see and select effective conversation context so labels describe the next execution. | FR3/E8/Q9 | Must / P0 |
| US04 | As a writer, I keep drafts and direct running work without losing input or duplicating actions. | FR4/E1/E2/Q1/Q4/Q5 | Must / P0 |
| US05 | As a reader, I inspect stable results and resolve the exact pending request. | FR5/E3/E4/Q2/Q3/Q6/Q7 | Must / P0 |
| US06 | As the owner, I retry or branch without destroying source history or implying filesystem undo. | FR6/E5/Q9 | Must / P0 |
| US07 | As the owner, I triage many conversations without confusing unread, draft, attention, settled and archived. | FR7/E6/Q8/Q10 | Must / P0 |
| US08 | As the owner, I find an old message and invoke an authorized action with the keyboard. | FR8/E7/E9/Q5/Q7/Q9 | Must / P0 |
| US09 | As the owner, I choose temporary retention or export knowing exactly what is kept. | FR9/E10/Q9 | Must / P0 |
| US10 | As an operator on desktop or phone, I can complete the core journeys and understand their limits. | FR10/E11/E12/W1–W6 | Must / P0 |

### Feature Specifications

#### FR1: Agent workspace identity and execution isolation

**Description**: Bind a named agent to a stable, separately scoped workspace without changing the instance owner's administration model.
**Priority**: Must / P0
**Acceptance Criteria**:
- [ ] Workspaces require explicit per-agent configuration. When `agent.agents.<id>.workspace` is absent, the agent retains its existing no-workspace behavior; no workspace, workspace principal, or corpus is assigned automatically. It never silently gains the owner's USER.md, memory projection or daily-log write path, and enabling a workspace never moves existing owner or agent data automatically.
- [ ] `agent.agents.<id>.workspace` names an operator-configured directory. Relative paths resolve under the instance data directory; absolute paths are explicit operator configuration. Canonical duplicate, overlapping or owner-root bindings are rejected before serving the affected binding. Workspace paths are not accepted from channel content or a session PATCH.
- [ ] A session pins agent/workspace ownership when created. Existing sessions without workspace ownership remain on their previous boundary; configuration changes do not silently move their history or retarget a running session. A changed/removed binding refuses new turns on the stale session with a create-new-conversation remedy; existing visible history remains readable to the owner.
- [ ] A pre-workspace bound-persona session remains a legacy no-vault session. Its historical transcript/search projection stays owner-admin-only and outside all agent memory/tool corpora; rebuild never assigns it to a newly configured agent workspace. A newly configured binding requires a new conversation before further agent execution. An admin-requested fork may explicitly carry an eligible visible-history prefix into that new principal after showing the destination context; this is a deliberate copy, never an implicit migration.
- [ ] Workspace-local identity/behavior files are used for that agent. An explicit persona `prompt` remains the SOUL override; missing agent files do not fall through to owner-private identity or memory. Operator config/security grants cannot be edited by modifying identity files.
- [ ] Directory, prompt source, skills and filesystem grants agree on the same resolved workspace before admission. Container profiles remain templates; each existing execution owner retains its own authority/container lifetime. No container or cached worker crosses principals through reuse.
- [ ] The workspace does not grant projects, tools, credentials or owner knowledge. Existing placement/allowlist/guard rules remain authoritative, including explicit unsupported isolation modes. A selected project changes the execution directory only after authorization and never changes workspace ownership.
- [ ] Workspace-local provider-native skill roots coexist with the existing DartClaw-native skills and operator-installed provider capabilities under existing inheritance policy. Discovery cannot widen the tool grant; missing/unreadable skill roots produce an actionable result rather than a different workspace's catalog.
- [ ] Configuration validation and current schema-driven settings expose the workspace field with the same semantics. Main/admin behavior and unconfigured agents retain their existing routes and placement defaults.
**Inputs / Outputs**: operator config and persisted session ownership → validated workspace identity, prompt/filesystem/skill context and explicit refusal on mismatch.
**Validation**: canonical containment (including symlinks), unique ownership, current configured binding, existing path/placement/tool authority; no caller-selected storage principal.
**Error Handling**: preflight failure names the agent/path and keeps that binding unavailable; no owner-root fallback, silent rebind, automatic directory move or implicit content copy.

#### FR2: Workspace memory and scoped knowledge access

**Description**: Give each configured agent its own canonical memory and maintenance while preserving controlled access to the owner's knowledge.
**Priority**: Must / P0
**Acceptance Criteria**:
- [ ] Each agent workspace owns its canonical MEMORY.md, daily log and journal/curation input/output. Startup preflight, refresh, lexical/vector indexing and rebuild act on that same corpus and principal. SQLite and PostgreSQL enforce equivalent scope.
- [ ] The existing memory MCP tools derive workspace/caller scope from authenticated execution context for every read, search, observe, apply, recent/count and source resolution. Omitted or forged scope cannot mean `owner`; changing only an index filter while sharing canonical files is invalid.
- [ ] `owner` remains the owner's storage identity; a configured named agent uses a stable agent-derived identity. It is not derived from a path, project, browser-selected setting, provider or message sender. Rename/remove does not reassign old data to another agent or destroy it automatically.
- [ ] Agent conversation indexing, snippets, counts, anchors and sources follow pinned session ownership. The admin UI can inspect authorized conversations across workspaces; a bound agent cannot use that administrative visibility through its own tools. Search ranking stays with the existing search service.
- [ ] Agent turns append only their own permitted daily log. The current unconfigured-persona exclusion from owner logs remains. Journal/curation jobs use explicit workspace context, existing corpus CAS/apply invariants, bounded model input and existing schedules/cost limits; a failed workspace cannot cause another workspace's job or writes to run instead.
- [ ] Journal/curation operate on configured workspaces using the existing scheduler, with unique per-workspace job/run ownership. Disabled/removed bindings do not launch new maintenance; already admitted work finishes or stops through the existing execution authority. No new global heartbeat/git-sync/self-improvement fanout.
- [ ] Wiki/KG stay owner-owned. Explicitly allowing `context_research` in the agent's existing tool grant permits read-only owner-knowledge retrieval through that context-engine surface; scope here is the existing caller/tool policy, not a new document-level ACL. The agent's ordinary memory tools remain workspace-local and cannot select the owner corpus. Missing/revoked tool grants or unavailable context service return a clear denial/unavailability. Granted responses retain owner source scope/provenance and trusted agent/session audit identity, and do not automatically copy owner knowledge into agent memory. Retargeting `context_research` to the agent corpus would remove the required owner-knowledge path.
- [ ] Retention and temporary-chat exclusions propagate through log, memory, lexical and vector paths. Existing owner corpus/index/rebuild behavior remains correct.
**Inputs / Outputs**: authenticated execution principal and configured corpus → scoped memory operations, maintenance records and authorized knowledge responses.
**Validation**: one principal across canonical files, lexical/vector keys, provenance, jobs and tool resolution; deny missing/mismatched identities.
**Error Handling**: preserve failed input and canonical data under existing rules, expose affected workspace failures, and never retry against another principal.

#### FR3: Effective session context

**Description**: Expose the real agent/workspace, project, provider and next-turn settings.
**Priority**: Must / P0
**Acceptance Criteria**: the E contracts below and these milestone-specific clauses are binding.
- Session context shows immutable agent/workspace ownership separately from selectable project. Owner web-created conversations remain owner-owned; existing bound-agent conversations keep their channel/agent boundary. A new web persona-creation product is not introduced.
- Add optional project display name, with id fallback and the existing project-id identicon. Project selection defaults at creation to the configured default project; no remote favicon fetch. Working directory/reference root resolve through the same project and allowlist authority, and changes revalidate attachments/references.
- Model/effort/provider changes take effect on the next turn only. Provider change carries visible history with explicit continuity limits; ACP model/effort controls remain unavailable until the adapter proves support. Context measurements are keyed by session and source, with unavailable/stale labels.

##### E8. Explain effective context and capabilities

- Build the canonical composer toolbar: attach/context on the left, effective model/effort and send/queue controls on the right. Keep guard posture visible without presenting a bypass as a convenience toggle.
- Context details show selected project/directory, explicit attachments/references, effective behavior files and effective provider/model, with origin/availability rather than guessed inclusion. Report context use only for the correct session and measurement source; unavailable/stale data is labelled, not shown as zero. A memory-informed badge requires real provenance; never infer it from memory being enabled.
- Model, effort and project changes say **when** they take effect. During a turn, queue a next-turn configuration change or disable it with an explanation; never alter an in-flight execution invisibly. A project change revalidates draft file references and attachments before send through the existing directory/allowlist boundary.
- Provider switching promises only the continuity actually supported. If it carries visible history but loses native tool/session state, say so before applying. Do not silently pick another provider/model on failure.
- Title generation uses the already accepted schema-bound logical-agent seam once after the first completed exchange. Retain the immediate truncated title as fallback; a generated result must never overwrite a manual title or newer title revision. No retrospective batch renaming or extra summarizer service.

**Inputs / Outputs**: Session context and authorized setting changes → effective context plus capability availability.
**Validation**: the identity, eligibility, authorization and boundary conditions stated above apply to every entry point, including direct API calls.
**Error Handling**: Reject ungranted project/directory/model changes and stale context; retain the draft and previous valid settings.

#### FR4: Writing continuity and running-turn controls

**Description**: Keep writing safe across navigation, multiple viewers, admission, cancellation and restart.
**Priority**: Must / P0
**Acceptance Criteria**: the E contracts below and these milestone-specific clauses are binding.
- The default Steer behavior is an explicitly labelled stop-then-follow-up transition where cancellation is supported; it requires confirmed stop before the new attempt starts. Native injection is offered only after transport conformance. Neither path is an ordinary queued message relabelled as steering.

##### E1. Start, write and attach without losing work

- New Chat immediately presents a usable composer with inherited project/model visible. Text entered while history or capabilities load remains editable; sending waits for a valid destination and required capability data. Loading completion never submits text or replaces a draft.
- Enter sends and Shift+Enter inserts a newline; Ctrl/Cmd+Enter also sends. On a touch screen Return inserts a newline and the send button sends. Teach the newline shortcut at the control. (Owner reversed the shipped Ctrl/Cmd+Enter-only convention on 2026-09-25 to match common chat apps.) IME composition and palette selection consume Enter before send handling. Keyboard actions must not hijack OS/browser shortcuts.
- Add a visible attachment button, existing drag/paste paths, and context chips with preview, remove, upload progress, failed/retry states and meaningful names. Expose current server limits before upload; no second hard-coded limit catalog. Sending while an attachment is unresolved cannot silently omit it.
- Persist text, references and attachments per instance and conversation, including the pre-creation draft. A provisional draft transfers to the server-created conversation exactly once. Navigation, reload and a failed send do not clear it. Clear only the acknowledged submitted revision; preserve edits made while submission was in flight.
- A persisted draft revision is atomically claimed by one stable submission identity before transport. Two tabs submitting the same recovered revision reconcile to that same result; intentionally sending again creates a new revision/attempt. Accepted message/queue ownership takes attachment handles before the submitted draft is cleared. Draft edits/removal and cleanup cannot delete handles referenced by accepted work. Q4 tests this combined race, not just independent edit and retry cases.
- **Scope:** browser-local drafts, including pending file bytes in bounded IndexedDB; uploaded files stay under the existing attachment owner, referenced by handles. No cross-device draft-sync promise. The implementation must prove reload, quota failure, upload cleanup and two-tab conflict behavior before the feature is accepted. A conflicting revision must be offered for recovery, never silently overwrite current text. Show “Saved on this device” or a persistent save failure; never claim success before persistence.
- While disconnected, writing and explicit local saving remain available. Sending stays unavailable; do not silently send on reconnect. A failed local save keeps the composer content editable and provides retry plus copy/download recovery, with an unsaved warning: reload recovery is unavailable until saving succeeds. Incognito/temporary drafts follow E10 instead.

##### E2. Understand and control a running turn

| State | Visible treatment | Available behavior |
|---|---|---|
| Loading context/history | Stable transcript/composer geometry and labelled loading region | Type a draft; send only when destination/capabilities are ready |
| Submitting | Local acknowledgement, retained recoverable draft | Prevent duplicate send; reconcile unknown outcomes by submission identity |
| Accepted / waiting for capacity | Queue/admission label distinct from model activity | Continue composing; cancel admitted work if supported |
| Running before first token | Thinking/work indicator with elapsed time | Stop; Queue; Steer only when supported |
| Streaming / using tools | Incremental prose plus compact tool summaries | Read/select/copy; inspect work; queue/steer/stop |
| Needs input / approval | Exact question or requested action, jump-to-request affordance | Respond/approve/reject as authorized; continue drafting |
| Stopping | Cancellation pending | Disable repeated stop; do not claim work has stopped |
| Completed / failed / cancelled | Distinct terminal label; retained partial answer where present | Copy, explicit retry where valid, fork/edit, new follow-up |
| Disconnected / reconciling | One persistent connection indicator | Read loaded history and write; reconcile before enabling mutations |

- Queue is the default send action during a running turn, visibly named **Queue**; Steer is an explicit alternative. Neither locks ordinary drafting. Stop remains separately reachable.
- Each accepted queued item has an identity, order and visible state. Show its text/attachments, allow edit/remove before dispatch, and acknowledge the operation. Serialize cancel/edit/dispatch so a losing action reports “Already sent” rather than claiming removal. Changing queue order is not required.
- Held items use **Send next queued message**, showing the oldest held item and attachments. It releases that item only; remaining held items stay held. Dispatch begins through normal admission when no current turn owns the session. Repeated requests for the same item/revision are idempotent, including from two viewers. Release/edit/remove/dispatch share one serialized transition: a stale edit/remove/release returns the current item state and does not execute revised or different input. Uncertain prior dispatch must be reconciled before release. This is distinct from resuming provider-session history.
- Steer must identify whether it injects into the active turn or stops then starts a follow-up. Show the actual supported behavior. Do not label a queued message “steered,” and do not show success before provider acceptance.
- Stop targets the displayed turn, retains partial output and leaves pending queue items **held** until the user explicitly sends the next held item or removes them. Failure and cancellation also hold undelivered items. Restart holds them for retained conversations; temporary items expire with their process under E10. Reconnection/restart must not unexpectedly execute pending input. Uncertain dispatch is reconciled, not blindly retried.
- Outside temporary conversations (E10), acknowledged sends and queued items survive server restart. Repeated submission of the same identity produces one message/attempt. An explicit user retry has a new attempt identity linked to its source. Use existing runtime persistence and admission owners; no independent browser execution queue.

**Inputs / Outputs**: Draft revisions, files and explicit send/queue/steer/stop actions → acknowledged message/attempt/queue states.
**Validation**: the identity, eligibility, authorization and boundary conditions stated above apply to every entry point, including direct API calls.
**Error Handling**: Surface storage, quota, stale-revision, attachment and uncertain-dispatch errors without clearing newer input or executing implicitly.

#### FR5: Stable transcripts and actionable approvals

**Description**: Make conversation history stable to read and runtime work safe to inspect and resolve.
**Priority**: Must / P0
**Acceptance Criteria**: the E contracts below and these milestone-specific clauses are binding.

##### E3. Read a conversation that stays still

- Preserve the existing bottom-stickiness guard. Scroll upward, select text, expand details or focus an earlier message without being dragged back by streaming, tool completion, history loading or SSE reconnection.
- When not following the bottom, show **New activity · Jump to latest**. A deliberate jump resumes following. On conversation switch/back, restore a message anchor and relative offset, disclosure state and draft; use stable message IDs rather than only a pixel scroll value.
- Older history loads without moving the visible anchor. Deep links and search can fetch a bounded window around a message outside the initial last-200 window. A removed/inaccessible target has a clear state and a route back to the conversation.
- Completed paragraphs/code blocks retain selection and stable layout while later content streams. Keep expensive Markdown/highlighting work bounded to changed content where measurement justifies it; do not add virtualization or a rendering framework before profiling.
- Add per-message timestamps with accessible full dates, whole-message copy and code-block copy with confirmation. Wide code/tables/tool details scroll inside their own regions; prose and actions stay within the viewport. Long output gets bounded preview plus explicit expansion, without discarding the original.
- Support ordinary prose, lists, tables, code, images, attachment references, citations and actionable artifact links through existing renderers. Prefer source/preview/copy actions over raw paths. Do not add arbitrary executable embeds or a second artifact system.

##### E4. Make work and approvals inspectable

- Group tools inside their owning turn. Completed routine tools collapse to a summary; running, failed and blocked tools retain a clear status. Expand to redacted arguments, result, elapsed time and related file/artifact where available. Keep event identity stable across live updates and reloads.
- Persist the displayable tool record needed for history. Do not promise durable tool cards while only the live SSE event contains their content. Limit/redact retained payloads through existing audit/redaction rules.
- Reuse the actual approval authority. A chat approval carries request ID, action/target, consequence/scope, expiry and current resolution. Surface only approval modes the runtime can enforce. A hard guard block is not an approvable request.
- Show a compact current-request strip near the composer with a jump to the full card. Read the action before approving; no global shortcut that blindly approves whichever request is newest. Put focus into the exact request before action, then restore a predictable position.
- Two viewers resolving one request produce one resolution. The other view becomes resolved/expired, without another side effect. Disconnect/auth expiry makes approval controls unavailable until reconciled.
- Link task/workflow output and review to the existing destinations; child work shows parent/result links when real identities are available. Full run replay, guard dashboards and new workflow screens remain outside scope.

**Inputs / Outputs**: Authorized history, tool events and request identities → durable readable transcript and exact-request actions.
**Validation**: the identity, eligibility, authorization and boundary conditions stated above apply to every entry point, including direct API calls.
**Error Handling**: Missing history, failed tools, expired requests, revoked access and reconnection retain honest state and offer the specified recovery.

#### FR6: Preserved-history recovery

**Description**: Recover from a failed attempt or earlier exchange without destroying evidence.
**Priority**: Must / P0
**Acceptance Criteria**: the E contracts below and these milestone-specific clauses are binding.

##### E5. Retry, edit and fork with honest history

- **Retry** is explicit resubmission after a failed/cancelled attempt, using its original input and context, with a linked new attempt and a warning where repeating tool effects is possible. It never erases the partial result or claims to resume at the failed tool.
- **Edit and continue from here** restores the selected user prompt, attachments and references into a **new branch**. **Fork from here** copies the visible conversation prefix through the selected message into a new conversation. Original history remains accessible in both cases. Display source conversation/message and project/provider context before sending.
- A conversation fork does not copy hidden provider state, revert files, undo sent messages, reverse tool effects or implicitly create a Git worktree. Native provider continuation may be used only when its contract is verified; otherwise clearly describe the visible-history context being carried.
- Prevent an ambiguous active-turn fork: choose a completed message boundary; do not include partial output still changing. Archived/read-only/channel/task session types have explicit eligibility and authorization. Unavailable actions explain why.
- A separate “new answer” action on a successful response is deferred. Fork and edit-and-continue provide the retained recovery surface without a second regenerate implementation.

**Inputs / Outputs**: Original input or a completed message boundary → linked new attempt or visible-history branch.
**Validation**: the identity, eligibility, authorization and boundary conditions stated above apply to every entry point, including direct API calls.
**Error Handling**: Reject ineligible/stale boundaries and unauthorized contexts; preserve source and partial output on all failures.

#### FR7: Inbox lifecycle and attention

**Description**: Support stable triage across views without conflating execution, reading and filing.
**Priority**: Must / P0
**Acceptance Criteria**: the E contracts below and these milestone-specific clauses are binding.
- Auto-settle supports task completion and a configurable positive idle-day threshold; it is off until configured. E6 eligibility applies to both triggers, including unread/failed/running/needs-input exclusions. Re-evaluate a completed conversation when it later becomes read/eligible rather than losing the completion trigger. No automatic settling occurs solely because a viewer opens history.

##### E6. Return, triage and settle

- Provide manual per-row and bulk settle, a readable slim settled tail with pagination, and parent/fork lineage plus elapsed running time in applicable rows. Bulk actions apply the same eligibility and stale-state checks as single-row actions; a failed member is reported without claiming the whole selection succeeded.
- Keep the flat active order stable across activity. Creation and settle/unsettle transitions are the only automatic membership changes; restore an unsettled row at its defined stable position. A search/filter view never changes stored order.
- Distinguish **unread**, **needs input**, **failed**, **running**, **done**, **draft**, **settled** and **archived**. Read state is not execution state; reading does not resolve approval or unsettle. A draft is not a queued message.
- Record read position at a visible message boundary while the conversation is foreground; opening a hidden tab or receiving an SSE event does not mark new output read. Synchronize read/attention state across the owner's tabs/devices through existing storage. Draft indicators explicitly remain device-local under E1.
- Settle remains reversible triage, archive remains the existing stronger lifecycle. Incoming persisted messages, turn starts and pending input auto-unsettle; typing a local draft and merely viewing history do not. Auto-settle must skip running/waiting/failed work and unread results. With E1's browser-local drafts, the server cannot promise a global draft veto: a local draft remains accessible in a fixed **Drafts on this device** filter even if another client or the server settles its conversation. Auto-settle initiated by that viewer skips its known drafts; restore remains explicit and viewing does not unsettle. Verify this cross-client limit with two clients.
- The persistent attention center is a projection of the same authoritative request/result events used by transcript and sidebar. Store event identity and owner read/dismiss markers through existing storage, not another approval/state machine. Deduplicate by event/request identity; completion, failure, needs-input and resolution produce explicit entries. Resolved/expired requests lose their actions everywhere. Reading/dismissing an entry never resolves approval, marks transcript messages read, or settles a conversation; dismiss is unavailable while a request needs action. A later request has a new identity and can notify again. Archive closes invalid request actions through its normal cancellation lifecycle while historical feed items remain readable. Keep the feed paginated; one outage notice per connection/source clears on recovery. Q6/Q8 exercise the feed, counts, sidebar and exact request together.
- Give every attention row a readable reason and full title accessible by keyboard/touch. Use status text/glyphs as well as color. Damping must not lower text below contrast requirements. Keep project identity separate from attention colors.
- Compact default filters, **Waiting on you** count and next-attention navigation make off-screen needs-input discoverable without reordering all rows. Filter state, current selection and search remain clear; no empty filtered screen without a clear-filter action.
- Bound/paginate long lists, including active results when necessary, while preserving counts and current-conversation access. Keep the accepted resizable 260 px default, clamps, keyboard resizing and reset. Small screens use the existing accessible drawer, with a direct new-chat action outside it.

**Inputs / Outputs**: Message/request activity and owner actions → stable rows, read/settled markers and attention projections.
**Validation**: the identity, eligibility, authorization and boundary conditions stated above apply to every entry point, including direct API calls.
**Error Handling**: Stale actions reconcile to authoritative state; filters and disconnected views cannot hide unresolved work without a visible route to it.

#### FR8: Conversation discovery and human commands

**Description**: Find the exact exchange and invoke the same authorized action from either palette.
**Priority**: Must / P0
**Acceptance Criteria**: the E contracts below and these milestone-specific clauses are binding.
- The closed host catalog includes `/new`, `/reset`, `/stop`, `/status`, `/fork`, `/settle`, `/model`, `/effort`, `/help` and discovered skill invocation. `/fork`, `/model` and other stateful verbs open the same context/confirmation flow as their buttons. Unowned slash text passes through unchanged. Built-ins take precedence over same-name skills, which remain invocable through a disambiguated explicit skill row.
- `/` and Cmd/Ctrl+K share catalog identity, descriptions, authorization and capabilities. Global navigation/search is available without a focused conversation; session verbs appear only in a valid session context. Inventory is cached outside keystroke handling and invalidated when its provider/workspace/configuration source changes.
- The accepted ADR-054 amendment scopes the prohibition to model-facing/prose grammars and preserves explicit human keyboard affordances bound to APIs. It must land before the catalog implementation in its owning story; no separate amendment-only story is needed.

##### E7. Find the exact past exchange

- Cmd/Ctrl+K combines navigation/search/actions through the existing search service and one command catalog. A separate **Find in conversation** action searches the full transcript, including unloaded pages, with match count and next/previous controls. The browser's own Find shortcut is not silently hijacked.
- Global conversation results show title, project/origin, time and a highlighted snippet; opening lands on the matching message with context. Scope controls distinguish active/settled/archive and project. Preserve the query when navigating back.
- Enforce the same session visibility rules on results, snippets, counts, anchors and export. Empty query/results, slow response, permission loss and backend failure each have deliberate UI states. Superseded search responses never replace newer results.
- Use the 0.26 conversation search/query service and its supported SQLite/PostgreSQL behavior. Ranking details stay with that owner; no duplicate index, UI-side corpus or raw diagnostics endpoint as the product contract.

##### E9. One human command catalog

Keep the accepted ADR-054 amendment before rebuilding the catalog. The `/` and global palette share built-in verbs, skills, descriptions and capability/authorization decisions, with available scope visible. Fetch/cache inventory outside keystroke handling. Commands with destructive consequences use the same confirmation as their buttons.

Only a closed explicit user command set is host-intercepted. Unowned `/` input is passed through unchanged; the UI describes it as **Send to provider**, not as a supported command unless tested. A transport accepting `/compact` as ordinary text does not prove native compaction. Provider-native invocation and skill discovery need conformance evidence per supported harness. Read-only users cannot recover hidden commands by typing their spelling.

**Inputs / Outputs**: Queries, capability inventory and explicit human commands → scoped message targets or existing actions.
**Validation**: the identity, eligibility, authorization and boundary conditions stated above apply to every entry point, including direct API calls.
**Error Handling**: Distinguish empty from failure, reject stale/unauthorized actions, and preserve unowned provider-directed input.

#### FR9: Temporary conversations and export

**Description**: Offer explicit local retention limits and a portable visible-history copy.
**Priority**: Must / P0
**Acceptance Criteria**: the E contracts below and these milestone-specific clauses are binding.
- At least one supported provider/placement combination must complete a real temporary conversation and all E10 retention probes; disabling every combination does not deliver the feature. The initial conformance target is mediated container execution with volatile provider-writable state, extending its existing read-only root/tmpfs boundary. Host execution and other combinations remain unavailable unless they independently prove E10. The baseline's host-backed generated provider home is not volatile and cannot be reused unchanged for this claim.

##### E10. Temporary conversations and export

- Keep temporary chat and export in scope. **Lifetime:** the server process owns temporary sent history/attachment/queue state in memory until explicit **End temporary chat** or that process stops, including crash/restart. Closing a tab does not end the server conversation; no idle-expiry timer is introduced. Reopening the opaque conversation link can recover sent history only while that process is still alive.
- **Ending:** first stop/resolve active work through its existing authority, then purge the temporary conversation and revoke its links. Show **Ending** until termination and cleanup are confirmed; failure remains visible and must not claim deletion. A server restart cannot replay temporary queued work. Temporary queue acceptance is labelled as surviving only this server process, an explicit exception to E2's ordinary durability contract.
- **Drafts:** temporary unsent text/files remain in page memory, survive in-app navigation while that page lives, and are discarded by full reload, tab close or browser restart. State this difference before creation and warn before a controlled navigation would discard unsent work. Never write temporary drafts into ordinary draft storage. HTMX/browser history must not snapshot their content.
- **Retention boundary:** no application-level durable DartClaw transcripts, drafts, attachment bytes, search entries, derived memory, content-bearing audit/log records or controlled harness transcripts. Retain only content-free operational audit metadata (opaque ID, action/time, result), disclosed before creation. Provider processing and external tool effects remain possible; neither is undone on ending.
- The temporary-chat slice must trace host storage, harness transcripts, upload files, indexing, memory ingestion, browser history/cache and audit paths. Durable spill files cannot be justified by deletion on graceful exit, because crash is part of the contract. Unsupported provider/storage combinations are unavailable with a reason. Do not call persistent data incognito because its sidebar row is hidden.
- Q9 exercises explicit end, server stop/crash/restart, tab close, full reload and browser restoration using unique text/file markers. Probe every inventoried durable surface after each applicable boundary; verify only the disclosed audit metadata remains. Provider processing/external effects are outside the local-retention assertion, but provider session files controlled by DartClaw are inside it.
- Export offers a readable Markdown transcript, timestamps, lineage and an attachment manifest; it states whether files are included and reports missing files. Apply the same authorization/redaction as the visible history. A requested export deliberately creates a durable copy, including for temporary chat; state that before download. No export directly executes or publishes content.

**Inputs / Outputs**: Explicit temporary creation/end or export request → process-lifetime conversation or disclosed durable download.
**Validation**: the identity, eligibility, authorization and boundary conditions stated above apply to every entry point, including direct API calls.
**Error Handling**: Unsupported retention combinations are unavailable; failed end remains Ending/failed until termination and cleanup are confirmed.

#### FR10: Accessible experience and operational qualification

**Description**: Make the complete experience usable and document the observed operating contract.
**Priority**: Must / P0
**Acceptance Criteria**: the E contracts below and these milestone-specific clauses are binding.
- Extend the existing five chat/inbox/palette/attention wireframes with linked states before their corresponding UI implementation; reuse revised Afterglow components and its drift-checked asset path. Integrated coverage includes loading, offline, upload failure, conflicting drafts, queue/steer/stop, approvals, branches, search, settle/archive and temporary/export at phone and desktop widths.
- Retain the four already decided canon changes as tasks in their owning features: the knowledge-hub layer filter uses canonical tabs rather than link-style chips with selected state (D13); disabled status has a muted status-dot distinct from idle (D14); repeated polling failures produce one persistent notice per failing source, cleared on recovery, with unchanged cadence (C06); canonical keyboard/ARIA disclosure uses a native button or details/summary with truthful expanded state and applies to tool calls and the existing workflow-step disclosure (C09). The latter is a shared-widget correction, not a new workflow screen.
- Every feature story owns its relevant automated/browser/visual checks. One explicit documentation and integration story owns public guide/architecture/glossary/CHANGELOG plus private UX specs, wireframe inventory/deviations and feature-comparison reconciliation. Public and private tasks are separately named within that story; no private commit occurs without a request. Final qualification requires a maintainer execution context with both canonical repositories available and authorized. Commands run from the public root; private document destinations resolve against the verified private root. Editing disposable exported copies does not complete a canonical private task, and a public-only runner stops before that story until the same story can resume in the two-repo context.
- Documentation covers workspace ownership and configured defaults, project versus workspace, owner-knowledge grants, settle versus archive, queue versus steer, provider limitations, command precedence, browser-local drafts and temporary retention. Correct affected architecture Current-through markers and stale glossary/guide claims against the implemented contract.
- Run the repository's prescribed workspace-wide analyze/build/test/format, architecture/fitness and PostgreSQL checks, including integration/release gates. Preserve failed observations alongside reruns. Real device and owner acceptance are release qualification outside unattended implementation, explicitly recorded; a machine-generated result cannot substitute for them.

##### E11. Phone, keyboard and assistive-technology quality

- Provide and document the core shortcut map for new conversation, conversation switching, composer focus and stopping the displayed turn. Palettes teach available shortcuts with `kbd` hints. Approval keys work only after focus is in the exact request described by E4; no global blind-approval shortcut is introduced.
- Validate 375, 390, 768 and 1440 px in both themes; add 200% zoom and reduced motion. Use real iOS Safari and Android Chrome for keyboard, safe-area and paste/upload qualification. Emulated viewport screenshots cannot prove virtual-keyboard behavior.
- Keep composer and essential actions reachable above the virtual keyboard, allow multiline input growth within a bound, and preserve transcript scrolling. Collapse secondary controls into a labelled menu; do not squeeze model/effort/send into unreadable fragments.
- Essential touch actions target 44 × 44 CSS px. No hover-only action, color-only status or unlabeled icon. Maintain 4.5:1 normal-text and 3:1 large-text/control-boundary contrast against the actual background, including damped rows.
- Keep existing drawer focus trap/inert/Escape behavior, main skip link and canonical dialogs. Restore focus after fragment swaps without stealing focus from composition, a palette or a pending approval.
- Screen readers receive turn/state and final-answer announcements through a bounded live region, never every token. Message actions, tool disclosures, attachment removal and resize all work by keyboard; reduced motion suppresses decorative streaming/arrival animation.

##### E12. Verify the whole experience

These are proposed release budgets and acceptance gates, not current measurements. The early fixture/measurement slice records hardware, browser, viewport, dataset, build and transport conditions. Default local run: production assets, loopback server, warmed session navigation, deterministic harness. Also run 150 ms added round-trip latency and a 10-second disconnection to separate UI feedback from network/provider latency.

| Gate | Required evidence |
|---|---|
| Q1 Local responsiveness | p95 input feedback ≤100 ms; pending-send feedback ≤100 ms. Accepted/waiting/running state is visible within 500 ms on the local fixture, separately timed from first model token. |
| Q2 Navigation | p95 warmed conversation selection → painted target transcript ≤200 ms over 30 switches. Cold loads show a stable labelled shell within 100 ms and separately report transcript readiness. Do not count an empty swap as a rendered conversation. |
| Q3 Representative load | 200 conversations, 10 active/attention states, 2,000 messages in the selected conversation, long code/table output and 8 attachment chips. Keep current last-200 history paging; load 100 older messages without shifting the anchor more than 4 px. During deterministic concurrent streaming, no UI long task exceeds 100 ms in the measured 30-second sample. |
| Q4 Draft/send integrity | Switch, reload, provisional creation, failed send, acknowledgement loss and quota failure. Also submit one recovered draft revision with attachment A simultaneously from two tabs; lose one acknowledgement, remove/edit A in the losing tab and reload. One accepted message/attempt, intact accepted attachment and retained newer draft edits; cleanup deletes only unreferenced handles. Exact reload recovery applies to successfully persisted revisions; quota failure instead requires editable in-memory content, unsaved warning and copy/download/retry recovery. Prove reload recovery separately after a successful save. |
| Q5 Running controls | Provider-specific steer semantics, queued edit/remove racing dispatch, stop racing completion, retained queue held after stop/error/restart, and explicit single-item release with two held items; race/repeat release against edit/remove from two viewers. Test Claude/Codex/ACP through capabilities; unsupported is an explicit result. |
| Q6 Multi-viewer truth | Initiating and passive viewer agree after channel/cron/other-tab turns, missed events, reconnect and server restart. One approval resolution; no duplicated tools/messages. Resolve/read/dismiss and settle/archive across viewers during duplicate event delivery; transcript, feed, sidebar and counts converge. Revoked access cannot fetch stale content. |
| Q7 Reading/search | Selection and anchor survive streaming/final reload; search opens a matching message beyond the initial page; back restores search/query/draft; missing targets recover clearly. |
| Q8 Attention lifecycle | Stable order; all three auto-unsettle triggers; read does not approve/unsettle; filtered/off-screen pending requests visible in counts; auto-settle exclusions and device-local-draft caveat exercised. |
| Q9 History/context/privacy | Retry/new branch preserves original and attachment context; no implication of filesystem undo; project references revalidated; unknown telemetry explicit; manual title wins; temporary lifetime, each destruction/reload/crash boundary and negative durable-content probes from E10; export verified end to end. |
| Q10 Usability/accessibility | E11 matrix plus keyboard and screen-reader journeys. The instance owner runs five tasks without coaching: start/attach, redirect, recover draft, find old answer, resolve/settle. Each must reach its stated end state with no lost input, wrong mutation, abandoned task or blocking keyboard/screen-reader failure. A failed task keeps Q10 open until its owner fixes the cause and the same journey passes on re-run; retain both observations. These single-owner acceptance runs are not a statistically representative usability study. Also triage ten mixed-state conversations (unread, needs-input, failed, running, done, draft, settled and archived) with actionable rows off-screen and filters active. Fail on any missed actionable item, wrong approval/settle action or target requiring coaching. Record path, errors, backtracks and confusion; return failures to the inbox/attention owner. No parity claim from screenshots alone. |

Use seeded deterministic harnesses for repeatable failures and real-provider runs for capability claims. Backend tests, browser journey assertions, screenshots/computed styles and owner task walkthroughs prove different properties; all are required for their assigned gates. Track failing gates in the owning story, fix and re-run them. An averaged score cannot compensate for lost drafts, duplicate execution or misleading approval/privacy controls.

**Inputs / Outputs**: Integrated fixtures, provider/device runs and operator documentation → reproducible evidence and release readiness.
**Validation**: the identity, eligibility, authorization and boundary conditions stated above apply to every entry point, including direct API calls.
**Error Handling**: Any failed or unavailable gate remains recorded and prevents the corresponding claim; no synthetic or averaged pass.

### User Flows

1. Configure an agent workspace → validate binding → receive a bound channel message → pin ownership → compose workspace context → execute with matching grants → append only its log/memory/index → request owner knowledge only through granted context access.
2. New owner chat → see project/model → write/attach → save device draft → acknowledge send → stream while reading earlier → queue/stop → explicitly release a held item → switch/return with draft and anchor intact.
3. Pending tool request → inspect exact action → resolve in one viewer → observe consistent resolution in transcript/inbox/feed → settle → external activity auto-unsettles without changing unrelated row order.
4. Search old exchange → open matching message outside initial page → fork/edit from a completed boundary → revalidate context/files → send a new attempt → return to unchanged source and preserved query.
5. Choose supported temporary mode after disclosure → write/send → explicitly export if desired → end or restart → confirm negative durable-content probes and no queued replay.

### UI Wireframes

The five Related Assets are the required design basis. They are integrated-state inputs, not evidence of passing E11/Q10. Update their inventory/deviations with linked state coverage before consuming changed designs; no separate workspace dashboard is required.

### Data Requirements

- Workspace ownership is immutable per session; project/provider settings have explicit next-turn semantics. Principal, project, channel origin, provider session, task and workflow remain distinct identities.
- Session metadata/history, queue/submission state, readable tool/request projection, read/settled markers and attention identity each have one existing host owner extended as needed. The baseline's session filesystem authority is not migrated to SQL just because task/search stores are SQL-backed.
- Lexical/vector projections are derived and scoped; rebuilding never reassigns ownership or exposes temporary data. No separate UI corpus or duplicate approval state machine.
- Draft revisions and pending file bytes are browser-local; accepted attachment handles are owned by accepted work before draft cleanup. Temporary content never enters those durable paths.

## Non-Functional Requirements

Q1–Q10 above retain the complete chat proof protocol. These additional workspace gates are acceptance requirements, with unique test markers in owner, agent A and agent B corpora.

| Gate | Requirement and pass condition |
|---|---|
| W1 Binding | Owner, configured agent, unconfigured agent, renamed/removed binding, restart, legacy no-vault and stale-session cases resolve their specified context or refuse; no silent rebind or content move. A unique legacy transcript marker remains admin-readable and absent from every agent corpus before/after configuration and both-backend rebuild. |
| W2 Execution isolation | Host/container and supported-provider matrix proves correct prompt/files/skills/project grants and no cross-principal worker/container reuse; invalid paths, symlink aliases, duplicate/overlapping roots and ungranted projects are rejected. Unsupported placement remains explicit. |
| W3 Memory isolation | Write/read/search/recent/count/apply and source resolution cannot access another principal's markers; equivalent SQLite/PostgreSQL lexical and vector paths, startup/rebuild and omitted/forged identity cases. Owner corpus remains intact. |
| W4 Maintenance | Two configured workspaces run log/journal/curation with independent input/output and failure behavior. Unconfigured personas do not write owner logs; removing one binding launches no further job for it and leaves other jobs correct. |
| W5 Context access | Granted owner knowledge is served through the context engine with scope/provenance; absent grant, stale source and unavailable service fail explicitly without owner corpus fallback or automatic memory copying. |
| W6 Cross-track | An owner inspecting a bound-agent conversation sees truthful ownership; project changes, forks, search, queued restarts and temporary exclusion preserve it. A persona cannot acquire the admin UI's cross-workspace visibility through its tools. |

| Category | Requirement | Threshold / Target |
|---|---|---|
| Responsiveness | Input/send feedback and navigation | Q1/Q2 budgets; no current measurement is implied |
| Reliability | Durable ordinary acknowledgements, stable read anchors and convergent viewers | Q3–Q8 with no lost acknowledged input or duplicate attempt |
| Security/privacy | Scoped files, prompts, tools, search and honest retention | W1–W6 and Q9; zero unauthorized marker disclosures/writes; explicitly granted context reads retain provenance |
| Accessibility | Both themes, 375/390/768/1440 px, 200% zoom, reduced motion, keyboard/screen reader and real phone keyboards | E11/Q10, including 44 px touch targets and required contrast |
| Architecture | Existing authorities/packages and provider-native conventions | No duplicate policy/store/catalog or framework; necessary growth is justified through existing governance |
| Operations | Docs and proof correspond to the actual release tree | FR10; missing hardware/provider evidence is recorded, never counted as passing |

## Edge Cases

| Scenario | Expected Behavior | Recovery Path |
|---|---|---|
| Workspace root aliases owner/another agent through a symlink | Binding refused before a turn or corpus preflight writes | Correct config; retry preflight |
| Agent workspace changes while an older session exists | Existing ownership remains readable but no silent execution rebind | Create a conversation under the new binding |
| Two viewers submit one draft revision and remove its attachment | One accepted attempt retains the attachment; newer draft survives | Reconcile by revision/submission identity |
| Stop races completion while two items are queued | Correct terminal state; remaining items held | Explicit oldest-item release after reconciliation |
| Project change makes a file reference invalid | No hidden directory switch or silently omitted reference | Re-select/remove reference and send explicitly |
| Approval expires or another viewer wins resolution | Current request state replaces stale action; one side effect | Return focus to the exact request/result |
| Search result loses access or its message is gone | No stale snippet/anchor content disclosure | Explain unavailable target; preserve query/back navigation |
| Another device settles a conversation with a local draft | Draft remains in the device-drafts filter | Open/read without implicit unsettle |
| Temporary server crashes | No durable content or queued execution survives | Explicit new temporary conversation; disclose lost unsent/history scope |
| Provider lacks steer, approval or telemetry | Unsupported action/source labelled, never guessed | Use an explicitly available action or choose a supported provider |

## Constraints & Assumptions

### Constraints

- Canonical product: prototype, one owner, one process/host, a handful of instances and one maintainer. Preserve the existing Dart/Trellis/HTMX/SSE/Stimulus architecture and both storage backends.
- ADR-054/041 retain model-first delegation and one authority per concern; security, resource, persistence, protocol and stop decisions stay deterministic. Existing title generation must use a declared schema-bound logical-agent capability, not a new heuristic summarizer.
- Session filesystem persistence and 0.26 search/backends are baseline facts. Extend their actual owners; do not infer the correct store from old comments or package descriptions.
- User instruction: minimize story count. Consolidate by implementation surface and user outcome; supporting model/API/migration/UI/tests are tasks in the same story where they fit. Split only on a proved fresh-session/module boundary or the FIS size gate. Historical 30–35 and 6–10 counts do not constrain this plan.
- All 0.27 authoring stays in private. The 0.26.1 publication prerequisite is met; the HTMX 4 preparation does not export this bundle or start its feature stories. Recheck the patch-to-release and preparation diffs against touched contracts before feature execution.
- Per-feature tests/visual validation belong to their feature. Integrated automated gates and required docs have explicit ownership. Real owner/device acceptance remains an external release gate, not an unattended story that waits for a person.

### Assumptions

- Existing owner-created web chats remain owner-owned. Agent workspaces serve configured logical/channel agents; adding a web persona chooser is outside the accepted request.
- Configured workspaces are operator-managed paths, not a new workspace registry/service. The accepted key names a directory; no automatic owner-data transfer or filesystem deletion is introduced.
- Existing per-client context-engine policy expresses allowed tools, not subsets of the owner's documents. An agent's explicit `context_research` grant is the owner-knowledge read permission; workspace-local memory reads derive identity from trusted caller context. No new client/account model or document ACL is assumed.
- Capability claims are bounded to tested provider/transport/posture combinations. Implementing a requested control requires conformance; a provider merely accepting input is not proof.

### Dependencies

| Dependency | Why It Matters |
|---|---|
| Integration baseline reconciliation | Publication prerequisite met; reconcile the authored contracts against published 0.26.1 and HTMX 4 preparation before feature execution |
| 0.26 full-text/vector ownership and SQLite/PostgreSQL contracts | Existing projection and tenant-key seams for workspaces and chat search |
| 0.25.2 channel agent binding and execution ownership | Existing route to named agents and policy/capacity behavior |
| Afterglow/0.23 canon | Existing component grammar, theme tokens, accessible dialogs and sidebar drawer |
| Provider conformance and real phone/owner access | Required for capability and Q10 release claims; not assumed available in unattended execution |

## Decisions Log

| Decision | Rationale | Alternatives Considered |
|---|---|---|
| D1 Workspaces require explicit per-agent configuration (owner confirmed 2026-09-14) | An absent workspace key preserves existing no-workspace behavior, without automatic workspace assignment or data movement | Automatically assigning a workspace to every named agent |
| D2 Separate workspace principal and project | ADR-054 one authority and the existing Project entity prevent cwd labels from redefining memory ownership | A project-as-workspace identity would mix permissions and corpus ownership |
| D3 Pin session ownership and refuse stale rebinds | Reload/config changes must not move a conversation's identity behind the user's back | Resolving a new workspace from mutable config on every turn |
| D4 Reuse filesystem session authorities, corpus services and scoped search | Preserve current owner/caller contracts and avoid a second store or index | Whole-session SQL migration, generic workspace platform, duplicate UI corpus |
| D5 Device-local drafts; server-owned durable accepted queue | E1/E2 distinguish writing convenience from acknowledged execution; one revision claim prevents duplicate sends | Cross-device draft sync, browser execution queue, file bytes in localStorage |
| D6 Steer defaults to disclosed stop-then-follow-up; native injection requires proof | Current harness API has cancellation but no verified steer method | Queue relabelled as steer, blind provider-name behavior |
| D7 Read/settled/feed markers project shared request/result identity | Reading, triage and approving have different effects; E6 keeps one request authority | A separate attention approval state machine |
| D8 Human command catalog stays; ADR-054 is amended before its implementation | Explicit human keyboard actions do not replace model MCP tools | Reintroducing a model-facing prose grammar or two palette catalogs |
| D9 Temporary lifetime and privacy remain E10; initial conformance targets mediated containers with volatile provider state | Existing read-only root/tmpfs is a usable isolation seam, but generated provider homes are currently host-backed; host execution remains unavailable without independent proof | Hidden persistent sessions, durable spill files, invented provider support, or calling an empty capability matrix a delivered feature |
| D10 Debt absorption: D13, D14, C06, C09 plus relevant C01/C02/C08/C10 behavior | Canon selection/disclosure, disabled status, outage dedup, readable identicons/foreground, dialog tabs and timestamp consistency directly affect retained journeys | Standalone tiny debt stories; changes outside the involved canon/callers |
| D11 Effective model/effort/default display is scoped to FR3/FR8; global D16/D17 metadata redesign deferred | Effective session capability data is necessary; a new application-wide config abstraction is not | Expanding the milestone into all provider/config metadata |
| D12 D02/D04/D15/D29/C11 and TD-051 deferred to their owning future work | Whole-app shadows/scanner, knowledge paging semantics, task icon retirement, restart dispatch and task acceptance are not prerequisites of these outcomes | Adding unrelated cleanup or task-lifecycle stories to 0.27 |
| D13 One combined plan; explicit public/private doc tasks may share one story | Minimize orchestration/FIS overhead while preserving document accountability | Separate plan/IDs per track and a story per document |
| D14 Owner-knowledge access uses the existing explicit context-tool grant | Existing policy controls tools and trusted caller context already identifies the agent; make read handlers contextual instead of inventing a permissions subsystem | Treating a tool allowlist as document-level ACLs, or letting ordinary agent memory tools select owner data |
| D15 Legacy bound sessions retain admin-only projection and no agent vault | Conservative preservation of D13 and the no-silent-migration requirement; only an explicit eligible admin fork copies history into a new workspace | Inferring a new workspace owner during rebuild, moving history on config reload, or exposing legacy transcripts to agent tools |

No release readiness is claimed by authoring this document. The plan records the baseline/export deferral and any remaining proof or decision holds explicitly.
