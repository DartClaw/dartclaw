# Temporary Conversations and Export

**Plan**: dev/bundle/docs/specs/0.27/plan.json
**Story-ID**: S08

## Feature Overview and Goal

**Intent**: Let the owner have a deliberately short-lived conversation and take an explicit portable copy without
quietly retaining chat content in DartClaw-controlled storage.

**Expected Outcomes**:

- [OC01] A supported temporary conversation remains usable and recoverable by its opaque link only for the life of the
  current server process, while unsent drafts remain only in the living browser page.
- [OC02] Explicit end, graceful stop, crash, and restart leave no temporary transcript, attachment, queue, provider-home,
  search, memory, audit-content, log-content, or replayable work in any DartClaw-controlled durable surface.
- [OC03] An authorized export downloads readable redacted Markdown with timestamps, lineage, and an accurate attachment
  manifest for ordinary or temporary history after disclosing that the download is a deliberate durable copy.
- [OC04] Temporary and export availability, retention limits, ending progress, failures, and destructive-navigation
  warnings remain truthful and operable across the affected browser, viewport, keyboard, theme, zoom, and motion states.

## Required Context

Path resolution is deliberate: `dev/...` and `packages/...` are public-repository-root paths, resolved read-only during
private authoring at `../dartclaw-public/<path>` against commit `0e605a2038b79c4e8d3164297506eff9a76f8fb4`.
`prd.md`, `plan.json`, producer FIS basenames, and `../../wireframes/...` are private-canonical paths relative to this FIS;
the future disposable public implementation bundle preserves or supplies those relative targets.

- `prd.md#fr9-temporary-conversations-and-export` – the complete E10 lifetime, end, browser-draft, retention, provider,
  inventory, Q9, export, authorization, and error contract.
- `prd.md#e11-phone-keyboard-and-assistive-technology-quality` – affected dialog, action, focus, touch, responsive,
  contrast, reduced-motion, and bounded-announcement requirements.
- `prd.md#constraints` – prototype scale, existing-authority requirement, private-only authoring hold, both storage
  backends, and the published-0.26.1 gate.
- `prd.md#decisions-log` – D9 pins temporary lifetime to E10, mediated containers with volatile provider state as the
  initial target, and explicit unavailability for unproved host/provider combinations.
- `plan.json#sharedDecisions` – one submission/attempt authority, S08's temporary exception, tested capability claims,
  and the separation of pinned ownership from project context.
- `plan.json#bindingConstraints` – FR9 and FR10 bind this story directly; FR1, FR2, and FR4 constrain the ownership,
  retention-eligibility, and submission seams it consumes.
- `plan.json#stories.S08` – story scope, dependencies, asset references, E10/Q9 coverage, and provider-proof sequencing.
- `s02-scoped-workspace-memory.md#acceptance-scenarios` – consume S07's retention-ineligible conversation behavior so
  temporary content cannot enter daily logs, canonical memory, lexical rows, or vectors.
- `s03-reliable-conversation-loop.md#technical-overview` – consume stable submission/revision, attempt, queue,
  attachment ownership, authoritative snapshot, and no-automatic-replay semantics with a volatile lifetime.
- `s04-inspectable-and-recoverable-history.md#technical-overview` – consume authorized redacted display history,
  bounded windows, timestamps, tool/request/result records, attachment context, and branch/source lineage for export.
- `dev/state/PRODUCT.md#proportionality` – one owner, one process/host, megabyte-scale SQLite, and the prohibition on a
  second storage authority or distributed lifecycle machinery.
- `dev/guidelines/TESTING-STRATEGY.md#layer-4--live-integration--e2e-tests` – real binaries and assembled-runtime tests
  are required where a fake cannot prove provider/container or browser behavior.

## Deeper Context

- `../../wireframes/chat-conversation-cards.html:29` – existing integrated conversation surface to refine with
  temporary disclosure, retention status, Ending/failed state, and export confirmation before UI implementation.
- `../../wireframes/archive-session.html:27` – existing read-only conversation surface to refine with the shared export
  flow and attachment-unavailable result.
- `dev/guidelines/HTMX-GUIDELINES.md#recommended-patterns` – explicit navigation, history-restore handling, and Stimulus
  ownership for page-memory state that must never enter HTMX snapshots.
- `dev/guidelines/TRELLIS-GUIDELINES.md#security--the-rules-that-matter-most` – escape visible history, lineage,
  filenames, tool details, and errors in server-rendered temporary/export UI.
- `dev/guidelines/VISUAL-VALIDATION-WORKFLOW.md#css-presence--correct-rendering` – screenshots plus computed styles and
  interaction evidence are required for the changed responsive states.
- `https://docs.docker.com/reference/cli/docker/container/run` – Docker documents foreground stream attachment,
  keeping stdin open, no-TTY/no-detach posture, and automatic removal only after a container exits.
- `https://docs.docker.com/reference/cli/docker/container/attach/` – an attached client can disconnect while a
  container remains running, so attachment alone is not a host-death guarantee.
- `https://docs.docker.com/reference/api/engine/version/v1.46/` – `AttachStdin`, `OpenStdin`, `StdinOnce`, and `Tty`
  are the engine configuration fields that implementation and real-Docker inspection must agree on.

## Acceptance Scenarios

- **S01 [OC01,OC02,OC04] [runtime] A supported owner starts and continues one process-lifetime conversation**
  - **Given** the owner is creating a web conversation whose effective provider is Codex and whose effective placement
    is the tested mediated-container posture
  - **When** the owner explicitly chooses Temporary after reading the process-lifetime, page-memory draft,
    content-free audit, provider-processing, external-effect, and export disclosures, then completes multiple turns and
    reopens the opaque link from another authorized tab while the same server process lives
  - **Then** the same in-memory submission/attempt/history/queue state is shown to both viewers, the provider continuity
    exists only inside that conversation's dedicated volatile authority, and no application or provider content is
    written to a host-backed session or generated-home path
  - **Proof**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case q9-temporary-supported-provider` – planned,
    unexecuted at spec time; must use the shipped Codex CLI in a real mediated container for a multi-turn conversation,
    never `FakeAgentHarness`, and retain the enabled provider/placement result plus host/container surface observations

- **S02 [OC01,OC04] [runtime] Temporary drafts survive only in the living page and never enter browser persistence**
  - **Given** a temporary conversation has unsent text and file bytes in one page, with another ordinary conversation
    and the same temporary opaque link available for in-app navigation
  - **When** the owner navigates away and back inside the living HTMX page, accepts or declines a controlled navigation
    warning, opens another tab, performs a full reload, closes the tab, restarts the browser, or restores browser history
  - **Then** in-app navigation within that page restores its draft; a destructive navigation warns before discarding;
    another tab has no draft; reload, close, restart, and restoration discard it; and no temporary text/file bytes enter
    IndexedDB, local/session storage, Cache Storage, HTMX history snapshots, form restoration, or a network cache
  - **Proof**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case q9-temporary-browser-memory` – planned,
    unexecuted at spec time; actual browser contexts inspect every storage/cache surface and restoration boundary with
    unique text/file markers and positive controls

- **S03 [OC02,OC04] [runtime] End temporary chat waits for confirmed stop and cleanup**
  - **Given** a temporary conversation is idle, waiting, streaming, stopping, or holding accepted queued work
  - **When** the owner confirms **End temporary chat**, repeats the request, races it with completion, loses the response,
    or container/process termination cannot be confirmed
  - **Then** one serialized transition refuses new mutations, uses the existing attempt stop authority, shows **Ending**,
    waits for confirmed harness/container termination, clears volatile session/history/attachments/queue/provider state,
    revokes every link, and only then reports completion; an unconfirmed step remains visible as Ending/failed and never
    claims deletion, while repeat/reconcile returns the authoritative result without dispatching held work
  - **Proof**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/temporary_conversation_contract_test.dart --name "end waits for confirmed termination and cleanup before revoking the conversation"` – planned, unexecuted at spec time; barrier-controlled idle/running/failure/repeat races prove ordering and zero replay

- **S04 [OC02] [runtime] Graceful stop, host crash, and restart erase every controlled temporary-content surface**
  - **Given** a live real-Codex temporary conversation carries unique prompt, response, attachment, queued, tool-detail,
    and lineage markers while the fixture plants positive controls in every inventoried durable host/browser/provider path
  - **When** separate runs end normally, stop the server gracefully, kill the server process without cleanup, and restart
    against the same data directory and browser profile
  - **Then** the old link is unavailable, no queued or uncertain item replays, the temporary container and its tmpfs
    provider home are gone before any later server can reclaim them, and marker sweeps find no transcript/draft/
    attachment/queue/harness/audit-content/log-content, index/vector/memory/log, browser snapshot/cache, or provider-
    session file; only disclosed content-free operational audit metadata may remain
  - **Proof**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case q9-temporary-destruction-boundaries` – planned,
    unexecuted at spec time; must launch and SIGKILL a child server, restart the same fixture, inspect real Docker and both
    supported storage backends, and fail vacuous scans whose positive controls are not found

- **S05 [OC01,OC04] Unsupported retention combinations fail before content or execution is accepted**
  - **Given** host execution, Claude, ACP, an unmediated container, unavailable Docker, a shared/nonvolatile provider
    home, an ineligible session type, or an omitted/unknown retention request reaches creation through UI or direct API
  - **When** the owner requests a temporary conversation or attempts to mutate a missing/ended temporary ID
  - **Then** only the exact executed conformance row is offered; every other combination returns an actionable reason
    before session, upload, submission, provider, audit-content, or execution state is created; ordinary creation remains
    ordinary; and an unknown or ended opaque ID never falls through to durable storage
  - **Proof**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/api/temporary_conversation_routes_test.dart --name "unsupported and no-match retention requests fail without durable or provider side effects"` – planned, unexecuted at spec time; table-drive omissions, all provider/placement rows, authorization, ended IDs, and unavailable runtime

- **S06 [OC03,OC04] Authorized export downloads the visible redacted history and an honest attachment manifest**
  - **Given** an authorized ordinary or live temporary conversation has timestamped user/assistant messages, retained
    redacted tool/request/result details, source/branch lineage, available attachments, and at least one missing or
    inaccessible attachment, while an unauthorized caller targets the same IDs
  - **When** the owner requests export, reviews the durable-copy and file-inclusion disclosure, confirms download, or
    repeats/abandons the request
  - **Then** one `text/markdown` attachment contains only the same authorized visible redacted history, timestamps,
    lineage, and a manifest naming each attachment's filename/media type/size plus available/missing status and reason;
    attachment bytes are not embedded and this is stated in the file and confirmation; missing files do not fabricate or
    abort the remaining transcript; unauthorized/no-match requests reveal no content; and no request executes or
    publishes the export
  - **Proof**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/api/conversation_export_routes_test.dart` – planned, unexecuted at spec time; ordinary/temporary, lineage, redaction, escaping, missing files, repeat, abandon, no-match, and authorization cases assert exact download headers and parsed Markdown sections

- **S07 [OC03,OC04] [runtime] Temporary and export controls remain accessible and visually truthful**
  - **Given** create disclosure, live temporary status, unsent-draft warning, export confirmation/result, Ending,
    end-failed, ended/no-match, and unsupported states at 375, 390, 768, and 1440 CSS px in both themes, 200% zoom, and
    reduced motion
  - **When** the owner completes each flow by keyboard, changes focus during swaps, triggers rapid state changes, and
    downloads and inspects the Markdown result
  - **Then** essential actions remain at least 44 × 44 CSS px, labelled and non-hover-only; dialogs follow the canonical
    focus trap/Escape/return contract; status is not color-only; text and control boundaries meet contrast requirements;
    Ending/failure/complete announcements are bounded; reduced motion suppresses decoration; focus is not stolen from
    composition; and screenshots plus DOM/computed-style/accessibility/network evidence match the refined wireframes
  - **Proof**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case q9-temporary-export-e11 --compare-wireframes` – planned, unexecuted at spec time; must drive the served UI in a real browser and retain screenshots, focus/keyboard, ARIA, live-region, download, cache, console, and network evidence

## Structural Criteria

- **SC01** Temporary state is an explicit retention policy inside the existing session/message, S03
  submission/attempt/queue, attachment, S04 display-history, and turn authorities. It introduces no temporary service
  platform, SQL session migration, durable event log, shadow transcript, or second lifecycle authority.
- **SC02** Temporary creation is an owner-authorized web `user` conversation with the same pinned owner/session,
  project, placement, tool, and credential authorities as ordinary work. An absent agent-workspace key preserves
  no-workspace behavior and neither changes this scope nor selects a temporary principal.
- **SC03 [runtime]** The initial enabled row is mediated-container Codex only after executed conformance. Its dedicated
  authority uses a container tmpfs generated home, no host generated-state mount, no durable provider resume, no reuse
  by ordinary/other temporary sessions, and an EOF-observing root on a retained non-TTY, non-detached stdin attachment.
  Loss of the server-owned pipe counts as a lifetime anchor only after the real-Docker matrix proves root exit and
  automatic removal on the supported host/runtime row.
- **SC04 [runtime]** Every automatic content sink consumes retention eligibility before writing: session/meta/history,
  attachments, S03 queue/attempt state, S04 tools/approvals/lineage, S02 conversation index/daily log/memory/vector,
  provider homes, audit, process logs, and browser history/cache/storage. Temporary audit retains only the disclosed
  opaque ID, action, time, and result through the existing audit authority.
- **SC05** Export reads S04's authorized redacted visible-history projection rather than raw provider events or storage,
  streams one Markdown download without a server spill file, embeds no attachment bytes, and cannot execute or publish.
- **SC06** The two existing wireframes are refined before dependent UI work; structural/template tests support them,
  while actual browser screenshots and interactions prove visual, focus, storage, cache, and download behavior.

## Scope & Boundaries

### Work Areas

- Existing conversation/session authorities with explicit durable versus process-lifetime retention
- S03 submissions, attempts, queue, revisions, attachments, live snapshots, and S02 retention-eligibility consumers
- Mediated container authority lifetime plus Codex generated-home and process continuity
- Existing audit/log authorities and the complete automatic content-sink inventory
- Temporary/export HTTP, Trellis template, HTMX, and chat Stimulus controller surfaces
- `docs/wireframes/chat-conversation-cards.html`, `docs/wireframes/archive-session.html`, and the shared real-browser
  conversation-loop profile

### What We're NOT Doing

- Host, Claude, ACP, unmediated-container, or any other provider/placement temporary mode – each remains unavailable
  until it independently executes the complete E10 conformance matrix.
- Undoing provider processing, network disclosure, project/workspace file edits, or other deliberate external tool
  effects – creation discloses that these effects may persist and ending does not reverse them.
- Cross-device temporary history/drafts, an idle-expiry timer, reopening after server restart, or browser-persistent
  temporary drafts – each contradicts E10's explicit process/page lifetimes.
- Bundling attachment bytes, arbitrary export formats, publishing, importing, replaying, or executing an export – the
  accepted portable copy is one readable Markdown download with a manifest.
- A generic retention platform, second store/index/audit sink, new event log, workflow/task/channel temporary mode, or
  automatic cleanup justified only by graceful exit – existing authorities and crash-proof volatile placement suffice.

## Architecture Decision

**Approach**: Carry one trusted durable/process retention policy through the existing conversation authorities. A
temporary owner conversation receives a dedicated mediated Codex container whose generated state is provisioned inside
tmpfs. The existing Docker CLI process runs that container in the foreground with an EOF-observing root and a retained
stdin connection; export streams S04's redacted visible projection. The exact host-death chain remains an empirical
eligibility condition rather than an inference from Docker flags.
**Why this over alternatives**: It supplies a concrete crash mechanism to prove while avoiding host spill files,
provider-native flag guesses, hidden persistent sessions, a generic daemon API client, a second conversation store, or
an empty support matrix.

## Technical Overview

`SessionService` remains the identity/lifecycle owner and holds temporary `Session` records in process memory; the same
`MessageService`, S03 mutation/snapshot, attachment, and S04 display-history interfaces route that retention to bounded
in-memory state instead of filesystem writes. The policy travels as trusted session context, never from a turn/tool
argument. S02's eligibility consumer rejects temporary events before conversation indexing, daily logging, or memory.

Each temporary conversation leases its own Codex mediated container. `ContainerManager` mounts
`containerGeneratedStatePath` as uid-1000 owner-only tmpfs instead of the baseline host bind mount, and the existing
generated-config seam writes bounded Codex config into that mounted path through the owned container process. The
temporary branch uses the existing `StartCommand` CLI seam to retain the foreground process; its lifecycle-bearing
arguments are `docker run --rm -i -a stdin ... IMAGE cat`, alongside the manager's existing hardened flags, labels, and
required mounts. This replaces the baseline `docker create`/`docker start` plus `sleep infinity` root. It uses no `-t`,
no `-d`, and no substitution of the turn bridge's separate `docker exec -i` connection. The image's Debian `cat`
command is the container root and exits on EOF. Graceful release closes the retained process stdin, awaits CLI/root
exit, and confirms inspect absence before forgetting the authority. Implementation
must inspect the live container and prove the CLI maps to `Config.AttachStdin=true`, `Config.OpenStdin=true`,
`Config.StdinOnce=true`, `Config.Tty=false`, and `HostConfig.AutoRemove=true`; if it does not, this launch is ineligible.
Docker documents these primitives and removal after exit, but does not promise that server pipe loss or SIGKILL closes
this attachment, that root observes EOF, or when removal finishes. TI11 and TI12 therefore must observe the complete
server-EOF/SIGKILL → attached-client disconnect → root exit → container removal chain on real Docker before
restart, with no startup reclaim accepted as evidence. Codex keeps its thread map only in the live harness process and
receives no durable resume request. The row stays unavailable if any configured value or empirical boundary fails.

End serializes against S03 admission, confirms turn/harness/container termination, then clears every in-memory owner and
revokes links. Export reads the same redacted view model as S04 and streams Markdown directly. Browser drafts use a
module-lifetime map that survives Stimulus reconnects/HTMX navigation in the same document; temporary responses are
`no-store`, HTMX snapshots omit content, and full document lifetime boundaries clear the map.

## Code Patterns & External References

```text
# type | path#anchor | why needed (intent)
file | packages/dartclaw_core/lib/src/storage/session_service.dart#SessionService | Keep session identity/lifecycle ownership while adding process retention
file | packages/dartclaw_core/lib/src/storage/message_service.dart#MessageService | Keep accepted messages and S04 display history behind one authority
file | packages/dartclaw_runtime/lib/src/concurrency/session_mutation_coordinator.dart#SessionMutationCoordinator | Serialize creation/admission/end and repeat/race outcomes
file | packages/dartclaw_runtime/lib/src/turn_manager.dart#TurnManager.cancelTurnById | Confirm the active attempt stops before temporary cleanup
file | packages/dartclaw_runtime/lib/src/api/session_attachment_routes.dart#registerSessionAttachmentRoutes | Route bounded temporary upload bytes without filesystem files
file | packages/dartclaw_core/lib/src/search/conversation_index_projection.dart#ConversationIndexProjection | Consume S02 retention eligibility before append/rebuild projection
file | packages/dartclaw_core/lib/src/container/container_executor.dart#ContainerExecutor | Extend the existing generated-state seam for direct volatile provisioning
file | packages/dartclaw_runtime/lib/src/container/container_manager.dart#ContainerManager.start | Preserve hardened flags while replacing host state with tmpfs and attaching temporary lifetime
file | packages/dartclaw_core/lib/src/harness/codex_environment.dart#CodexEnvironment.containerAuthClean | Reuse auth-clean generated config without seeding login or inventing a provider flag
file | packages/dartclaw_core/lib/src/harness/codex_harness.dart#CodexHarness._prepareEnvironment | Keep container bridge/config/thread ownership and remove content-bearing prompt logs
file | packages/dartclaw_kernel/lib/src/guard_audit.dart#GuardAuditLogger | Keep one audit sink while reducing temporary entries to disclosed content-free metadata
file | packages/dartclaw_runtime/lib/src/api/session_routes.dart#sessionRoutes | Own creation, lookup, temporary lifecycle, export routing, and direct-API refusal
file | packages/dartclaw_runtime/lib/src/templates/chat.dart#chatAreaTemplate | Render escaped retention, end, export, and failure states from prepared view models
file | packages/dartclaw_runtime/lib/src/static/controllers/dc_chat_controller.js#DcChatController | Own page-memory drafts, navigation warnings, cache avoidance, focus, and downloads
wire | ../../wireframes/chat-conversation-cards.html:29 | Integrated temporary/end/export states to refine before UI work
wire | ../../wireframes/archive-session.html:27 | Read-only export and unavailable-attachment states to refine before UI work
url | https://docs.docker.com/reference/cli/docker/container/run | Pin foreground stdin attachment, no-TTY/no-detach posture, and removal-after-exit semantics
url | https://docs.docker.com/reference/cli/docker/container/attach/ | Prevent treating attached-client lifetime as container lifetime without proof
url | https://docs.docker.com/reference/api/engine/version/v1.46/ | Pin create/inspect fields for the retained root stdin connection
```

## Constraints & Gotchas

- **Critical**: The baseline generated provider home is a host bind mount under the data directory. Deleting it in
  `ContainerManager.stop` proves graceful cleanup only; temporary mode must use tmpfs plus the process-lifetime anchor,
  and the crash probe must observe container exit and host-path absence before any restart cleanup runs.
- **Critical**: `-i`, `--rm`, or the existing `docker exec -i` bridge does not by itself prove server-lifetime cleanup.
  Temporary mode requires the distinct foreground root attachment and exact inspected engine fields above, plus real-
  Docker evidence that host EOF and server SIGKILL each lead through root exit to removal. Startup reclaim cannot close
  a failed or missing boundary.
- **Critical**: At least the mediated-container Codex row must pass and remain enabled. Disabling all combinations,
  relabelling the baseline host-backed home, using `FakeAgentHarness`, or treating startup reclaim as erasure does not
  deliver this story.
- **Constraint**: Provider processing and deliberate external tool effects can persist. This exception does not permit
  DartClaw-controlled transcript, upload, tool-detail, audit/log content, search, memory, or built-in ingestion writes;
  their callers must consume the trusted retention policy, including S02's ineligible-source seam.
- **Assumption**: Export is the deliberate durable exception. Because E10 requires a Markdown transcript and disclosure
  of file inclusion but does not require a file bundle, the smallest coherent export embeds no attachment bytes and
  states that in both confirmation and Markdown; a temporary export does not change the source conversation's lifetime.
- **Constraint**: Browser page memory is document-lifetime state, not `sessionStorage`. HTMX controller reconnects must
  retain it, while reload, tab/browser close, bfcache/history restoration, and explicit end must not.
- **Constraint**: D1 requires explicit per-agent workspace configuration. Temporary mode is an explicit owner web-session
  choice and cannot create, infer, or move a named-agent workspace principal; an absent key preserves no-workspace behavior.
- **Constraint**: Real iOS Safari, Android Chrome virtual-keyboard behavior, and Q10 owner/device tasks remain S09
  external release evidence. S08 still owns executed desktop/mobile real-browser proof and the provider privacy proof.
- **Constraint**: Execute only after 0.26.1 is published. Reconcile
  `0e605a2038b79c4e8d3164297506eff9a76f8fb4..HEAD` across every Code Patterns surface and all S02/S03/S04 producer
  contracts before editing; no private-to-public export or public write occurs during authoring.

## Implementation Plan

### Implementation Tasks

- **TI01** The shared conversation fixture inventories and probes every temporary content surface
  - Extend S03's deterministic conversation-loop fixture with unique markers, positive controls, child-server
    graceful/SIGKILL/restart control, browser storage inspection, Docker inspection, and SQLite/PostgreSQL sink sweeps.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/temporary_retention_fixture_test.dart` – every named host/browser/provider surface and boundary can independently fail, and an empty scan cannot pass
  - **SATISFIES**: S04, SC04, SC06

- **TI02** The existing conversation wireframes define temporary, end, and export states before UI work
  - Refine both referenced assets with pre-creation/export disclosures, live retention status, draft-loss warning,
    Ending/failed/ended states, Markdown download result, and an available/missing attachment manifest at phone/desktop.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/static/temporary_export_wireframe_contract_test.dart` – both assets parse with accessible relationships and referenceable fixtures for every changed state; this is structural evidence only
  - **SATISFIES**: S07, SC06

- **TI03** Existing conversation authorities enforce an explicit process retention policy
  - Extend `SessionService`/`MessageService` and S03's submission, attempt, queue, revision, snapshot, and S04 display
    records so temporary owner sessions use bounded process memory and trusted context; durable behavior stays unchanged.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/temporary_conversation_contract_test.dart --name "temporary and ordinary conversations share authorities with distinct retention"` – all record kinds route correctly, direct/forged policy input is refused, and ordinary persistence regresses nowhere
  - **SATISFIES**: S01, S03, S04, S05, SC01, SC02

- **TI04** Temporary attachments and automatic memory/search consumers leave no durable content
  - Route temporary upload bytes/metadata through the existing attachment owner in memory, and carry TI03 eligibility
    through every S02 append/rebuild/daily-log/memory/vector consumer before it writes on SQLite or PostgreSQL.
  - **Verify**: `cmd: dart test --reporter=failures-only --run-skipped packages/dartclaw_runtime/test/conversation/temporary_retention_consumers_test.dart packages/dartclaw_runtime/test/integration/temporary_retention_postgres_live_test.dart` – upload/accepted/queued/tool histories remain readable in-process while filesystem, index, vector, log, and memory markers stay absent on both backends
  - **SATISFIES**: S01, S04, SC01, SC04

- **TI05** Temporary Codex authorities keep generated state in container memory for exactly the server lifetime
  - Extend `ContainerExecutor`/`ContainerManager` and `CodexEnvironment.containerAuthClean` so the dedicated temporary
    authority provisions config into owner-only uid-1000 tmpfs, exposes no host generated-state mount, and is never
    shared or resumed durably. Replace the temporary row's baseline create/start and `sleep infinity` root with
    `docker run --rm -i -a stdin ... IMAGE cat` through the existing retained `StartCommand`, preserving its hardened
    flags, labels, and required mounts; prohibit TTY/detach and keep this root stdin connection distinct from every
    `docker exec -i` bridge. Graceful release closes stdin, awaits exit, and confirms removal before clearing ownership.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/container/temporary_container_manager_test.dart packages/dartclaw_core/test/harness/codex_harness_container_test.dart` – argument/configure/reuse/end/parent-pipe-loss cases prove exact CLI shape, EOF-observing root, mount shape, ownership, readable config, authority isolation, and zero host home; a hermetic CLI double may assert intent here but cannot establish the host-death guarantee
  - **SATISFIES**: S01, S04, S05, SC03

- **TI06** Temporary audit and process logs retain metadata without conversation content
  - Carry TI03's policy through the existing audit/logger callers, retaining only opaque ID, action, time, and result
    for temporary operations; remove Codex prompt previews and bound every error so prompts, filenames, tool arguments/results, and provider output cannot enter logs.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_kernel/test/guard_audit_test.dart packages/dartclaw_core/test/harness/codex_harness_test.dart packages/dartclaw_runtime/test/conversation/temporary_retention_consumers_test.dart` – temporary pass/warn/block/failure paths retain disclosed metadata and reject every unique content marker while ordinary diagnostics remain useful
  - **SATISFIES**: S04, SC04

- **TI07** End temporary chat completes one confirmed stop-cleanup-revoke transition
  - Use `SessionMutationCoordinator` and `TurnManager.cancelTurnById`; reject new mutations after ending starts, await
    harness/container exit and volatile-owner clearing, retain failed/unconfirmed state, then revoke all HTTP/SSE links.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/conversation/temporary_conversation_contract_test.dart --name "end waits for confirmed termination and cleanup before revoking the conversation"` – every idle/running/queue/completion/repeat/lost-response/failure interleaving has one authoritative outcome and no replay
  - **SATISFIES**: S03, S04, S05, SC01, SC03, SC04

- **TI08** Temporary drafts live only in one browser document
  - Implement TI02 through `DcChatController` with a module-lifetime map across Stimulus reconnects, explicit in-app
    navigation restoration/warnings, `no-store` temporary responses, no HTMX content snapshots, and clearing on end or full document lifetime boundaries.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/static/temporary_chat_controller_test.dart` – deterministic DOM/storage cases prove same-page navigation, cross-tab absence, reload/restore/end clearing, warning decisions, and zero IndexedDB/local/session/cache/history content
  - **SATISFIES**: S02, S03, S07, SC04, SC06

- **TI09** Conversation export streams authorized readable redacted Markdown with accurate lineage and attachments
  - Read S04's visible-history projection under the existing session authorization, format timestamps/tool details and
    source/branch links, record every attachment's availability and non-inclusion, use an opaque-ID-safe filename, and
    stream the download without a host spill file or action execution.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/api/conversation_export_routes_test.dart` – parsed ordinary/temporary exports, headers, lineage, redaction, escaping, missing attachments, no-match, authorization, repeat, and absence of server files all pass
  - **SATISFIES**: S06, SC05

- **TI10** Server-rendered temporary and export controls expose only truthful effective actions
  - Implement TI02 with prepared view models and escaped Trellis fragments; creation and export require their
    disclosures, unsupported modes show reasons, Ending/failure reconcile from authority, and the export download follows explicit confirmation.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/api/temporary_conversation_routes_test.dart packages/dartclaw_runtime/test/templates/temporary_export_template_test.dart` – direct API and rendered states enforce auth, retention capability, disclosure, no-match, safe output, cache headers, and valid action availability
  - **SATISFIES**: S01, S03, S05, S06, S07, SC02, SC05, SC06

- **TI11** Every destruction boundary has negative durable-content and no-replay proof
  - Run TI01 after TI03-TI10 against assembled SQLite and real PostgreSQL configurations; end, graceful stop, SIGKILL,
    and restart each get independent markers and scans before cleanup can mask a failure. For each real-Docker row,
    inspect the live authority and retain actual `Config.AttachStdin`, `Config.OpenStdin`, `Config.StdinOnce`,
    `Config.Tty`, `HostConfig.AutoRemove`, root command, tmpfs, mounts, state, and container-runtime/version values.
  - **Verify**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case q9-temporary-destruction-boundaries` – all inventoried sink probes find their positive controls and no forbidden marker; separate host-pipe-close and child-server-SIGKILL runs observe attached-client disconnect, `cat` root exit, automatic removal, tmpfs loss, and absence by Docker inspect before any restart/reclaim; restart finds no old link/container/provider home and dispatches no retained queue item
  - **SATISFIES**: S04, SC01, SC03, SC04

- **TI12** Mediated-container Codex is enabled only by executed real-provider conformance
  - Run the shipped Codex CLI through the assembled mediated container for a bounded live-provider multi-turn exchange,
    attachment, end, graceful server stop, host-pipe loss, child-server SIGKILL, and restart; retain provider/placement/
    version, actual Docker inspect fields, root-exit/removal timing, and surface evidence. Keep the row unavailable if the
    intended CLI-to-engine mapping differs or any closure/removal probe fails.
  - **Verify**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case q9-temporary-supported-provider --live-provider` – one genuine Codex/container row proves exact inspected stdin/TTY/auto-remove configuration and the pre-restart EOF/SIGKILL-to-root-exit/removal chain while passing all E10 local-retention boundaries; a fake harness, scripted-only upstream, startup reclaim, mere `-i`/`--rm`, or an all-disabled matrix fails
  - **SATISFIES**: S01, S04, S05, SC03, SC04

- **TI13** The served temporary/export experience meets Q9 and affected E11 behavior in a real browser
  - Run after TI02/TI08-TI12 at every required viewport/theme/zoom/motion setting; retain screenshots, DOM/computed
    styles, accessibility/focus/keyboard/live-region results, storage/cache inspection, network requests, console output, and parsed download evidence.
  - **Verify**: `cmd: bash dev/testing/profiles/conversation-loop/run.sh --case q9-temporary-export-e11 --compare-wireframes` – all S01/S02/S03/S06/S07 clauses pass with retained evidence and every failed observation remains beside its rerun
  - **SATISFIES**: S01, S02, S03, S06, S07, SC05, SC06

### Testing Strategy

- TI03-TI10 use component/API/template/DOM tests with bounded in-memory temporary records, real temporary-directory
  ordinary authorities, S03 race barriers, fake external provider responses, and unique allowed/forbidden marker sets.
  Each absence assertion has a positive control and asserts the complete inventory rather than accepting an empty result.
- TI04 proves the S02 retention consumer on SQLite and real PostgreSQL/pgvector. TI11 launches child server processes so
  SIGKILL prevents application cleanup, checks the inspected root attachment and Docker/disk absence before starting any
  later process, then proves the restarted runtime cannot find the opaque link or dispatch old queue state. Failure of
  EOF, root exit, or automatic removal is a failed capability row; startup reclamation is never a recovery proof.
- Fake harnesses may exhaustively prove mutations and failure ordering, but cannot close provider privacy. TI12 requires
  the shipped Codex binary, a real container, host mediation, and a live provider exchange. It records the exact supported
  row rather than inferring provider support from flags, family names, or config shape.
- TI13 extends the same S03 conversation-loop browser profile. Marker scans and screenshots support diagnosis; actual
  navigation, storage/cache inspection, downloads, keyboard/focus, accessibility, and computed rendering prove the UI.

### Validation

- S08 owns feature-level desktop/mobile real-browser evidence and real provider/container conformance. Real iOS Safari,
  Android Chrome virtual-keyboard checks, Q10 owner tasks, and the full joined release matrix remain S09 external evidence;
  unavailable or failed external runs stay open and no emulation, screenshot, fake harness, or generated walkthrough
  substitutes for them.

### Execution Contract

- Do not export or execute this FIS until 0.26.1 is published. At launch, reconcile the pinned baseline against the
  published public tree and the completed S02/S03/S04 producer contracts before editing; preserve unrelated moving-tree work.
- TI01 establishes the inventory and non-vacuous fixture. TI02 refines the two existing assets before TI08/TI10/TI13.
  TI03 establishes retention; TI04/TI06 consume it. TI05 establishes volatile provider placement. TI07 depends on
  TI03/TI05. TI08-TI10 consume the host contracts. TI11/TI12 run after all sinks and lifecycle paths are wired; TI13 runs last.
- Completion requires executed TI11 and TI12 evidence. The story remains blocked if no provider/placement row is enabled,
  if provider generated state is host-backed, if configured Docker fields differ from the pinned launch contract, if
  EOF/SIGKILL cleanup depends on later restart reclamation, or if any Proof/Verify target reports a temporary content
  marker on a controlled durable surface.

## Implementation Observations

- 2026-09-14: `HarnessWiring` owns the effective temporary-conversation capability. It combines the existing
  `ProviderExecutionInventory` verdict for the configured provider and exact `container(workspace)` policy with live
  Docker/profile availability; the creation route consumes that result without deriving another provider matrix. The
  empirical EOF/SIGKILL/live-provider qualification remains a final-candidate release gate, not product configuration
  or persisted runtime state. The development candidate exposes the row for the committed matrix to exercise, but the
  row must not be reported or shipped as supported until that exact unmodified tree passes TI11-TI13.

- 2026-09-14: The execution coordinator explicitly deferred TI04's live PostgreSQL half and all TI11-TI13 real
  Docker, live-provider, child-crash, and browser/visual runs to the final plan gate. This overrides this FIS's original
  executed-proof completion condition for the story branch. The fixtures, commands, setup requirements, assertions, and
  expected artifact manifest are committed; no capability claim should be promoted from the unexecuted heavy rows.
- 2026-09-14: `ConversationRetention` is the one trusted discriminator. `SessionService` and `MessageService` remain the
  owners and use bounded process memory; production `StorageWiring` installs the fail-closed resolver. S04 history,
  approval, branch and context state remain in `ConversationState`; S05 telemetry stays there, while usage KV and the
  auxiliary automatic-title session/prompt are skipped before launch for process retention.
- 2026-09-14: Temporary execution is derived from the host session and takes a dedicated worker authority. The Codex
  generated home is provisioned through the existing container executor into tmpfs. The retained Docker foreground
  process and its root stdin are separate from every `docker exec -i` turn or bridge process.
- 2026-09-14: One unrelated existing regression failed during the affected-owner sweep:
  `turn_runner_daily_log_test.dart` expected redaction below 262144 code units and observed 4267542. S08 does not modify
  the serializer under test. The integration branch repaired the shared serializer cause in `c6cedd075db9` and
  `01ac1d27a565`; the merged tree must verify that repair because this older story worktree deliberately does not carry it.
- 2026-09-14: The executable conformance fixture uses the installed normal Codex login, the canonical built AOT server,
  and the verified local embedding model. It requires no fixture-only provider credential. Release qualification remains
  pending until the exact composed multi-turn, EOF, SIGKILL, PostgreSQL, browser-storage, and visual rows execute.
- 2026-09-14: The destruction fixture accepts an independent `sqlite` or `postgres` backend for each confirmed-end,
  graceful-stop, and SIGKILL boundary. The composed `eof` mode names the confirmed API-end row and invokes the separate
  actual-stdin-close owner test; the dispatcher retains all six backend/boundary rows. Each row creates real tool detail,
  branch lineage, active work, and held queue markers, retains the child identities, and runs sink checks before the
  queue, after the queue, and after the boundary or restart. PostgreSQL controls query actual
  `conversation_chunks` and `conversation_vectors` rows, while browser-storage evidence remains confined to browser runs.
  Negative assertions fail explicitly under `set -e`, turn artifact variables are assigned before use under `set -u`,
  and a missing AOT executable points to the canonical `bash dev/tools/build.sh`.
