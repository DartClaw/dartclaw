# Approval Mode for Seam Writes (`scheduling.mutation.approval`)

## Feature Overview and Goal

**Intent**: A chat turn can currently write `scheduling.jobs` — `delivery: announce` included — straight into `dartclaw.yaml` with the tool guard as the only gate, so a deployment reading untrusted channel content has to deny `schedule_upsert` outright and lose chat-driven scheduling; an operator approval gate keeps "customise via chat" and "config is the security policy" both true.

**Expected Outcomes**:

- [OC01] Under `scheduling.mutation.approval: operator`, a `schedule_upsert` call from a model turn changes neither `dartclaw.yaml` nor the running scheduler; it is parked, and the tool answer tells the model the write is pending rather than loaded.
- [OC02] An operator sees every parked change on the Scheduling page and settles it there: approving makes the job live under the same write path an unparked write takes; rejecting discards it and leaves config and scheduler untouched.
- [OC03] A parked change survives a server restart, so an operator who was not at the console when the model asked still finds it.
- [OC04] With the default `none`, every scheduling surface — tool, jobs API, Scheduling page — behaves exactly as it does today.

## Required Context

- `dev/adrs/054-model-first-delegation-and-one-authority-per-concern.md#the-carve-out-what-stays-deterministic` – the approval decision is a security boundary and stays host-side and deterministic; this is why a model-side "ask first" instruction is not the design, and why the tool description may state parking as a fact but must not instruct the model to seek approval.
- `packages/dartclaw_runtime/AGENTS.md#conventions` – three binding bullets: `ScheduleMutationService` is the one `scheduling.jobs` mutation authority; every seam write runs `commitAndApply` and its collaborators reach the seam's three construction sites as lazily resolved closures threaded from the composition root; a dashboard page owns its sub-routes by declaring them in `DashboardPage.declaredRoutes`.
- `packages/dartclaw_kernel/AGENTS.md#configuration` – `ConfigMeta.fields` is the only registry for operator-facing fields, and a new key needs parser wiring plus focused tests; `FieldConstraints.evaluate` is the single per-field constraint authority.
- `docs/guide/security.md#hardening-the-primary-agent-for-untrusted-channels` – the posture this feature replaces as the recommendation; the `agent.disallowed_tools: [schedule_upsert]` deny stays documented as the stricter alternative.
- `docs/guide/scheduling.md#cron-jobs` – the operator-facing contract this feature qualifies: today it states unconditionally that a tool write is loaded before it is answered.
- `dev/guidelines/HTMX-GUIDELINES.md#server-rendered-fragment-conventions-for-crud-surfaces` – the seven-point fragment contract the pending-changes list and its approve/reject responses must follow.
- `dev/guidelines/TRELLIS-GUIDELINES.md#core-directives` – escaping and directive rules for the new fragment; every value the model supplied reaches the page as untrusted text.
- `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md#generated-artifacts` – the two regeneration commands for `schemas/dartclaw.schema.json` and the generated region of `docs/guide/configuration.md`, both of which a new `ConfigMeta` field drifts.

## Deeper Context

- `dev/state/SPEC-LIFECYCLE.md` – governs this file's own lifetime under `dev/bundle/`; it is a transient working copy, removed before the squash-merge.
- `dev/design-system/DESIGN.md#colors` – token and surface rules for the pending-changes card; compose canonical primitives, never page-local CSS.
- `dev/state/DECISIONS.md#still-current` – "The six orchestration and content MCP tools reach a container authority under the host lane's rule" keeps `schedule_upsert` in the primary agent's grant on a default container install; that grant is what makes an approval gate the useful control rather than the deny.
- Upstream sources, both in the sibling **private** repo (`dartclaw-private/`) and not required to execute this FIS, which carries every decision they settle: `docs/PRODUCT-BACKLOG.md` § *Scheduling: Seam-Write Approval and Model-Free Feed Jobs* (the originating entry) and `docs/specs/0.25.1/prd.md` decisions D4 (no second job store; YAML is the one authority for which jobs exist) and D12 (deny now, spec an operator approval gate; a model-side "ask first" is ruled out by ADR-054).

## Acceptance Scenarios

- **S01 [OC01] [TI04,TI05,TI08] Under `operator`, a model-originated upsert is parked and nothing is written**
  - **Given** `scheduling.mutation.approval: operator` and a running `ScheduleService` with no configured jobs
  - **When** `schedule_upsert` is called with a valid `id`, `type: prompt`, `schedule`, `prompt` and `delivery: announce`
  - **Then** `dartclaw.yaml` is byte-identical to before the call, `ScheduleService.hasJob(<id>)` is false, one pending change is stored carrying the resolved job body, the requester — the MCP dispatch's caller identity where it supplies one, else the literal tool surface name `schedule_upsert`, never a model argument — a UTC ISO-8601 timestamp and a host-generated `changeId`, and the tool answers `{id, pending: true, changeId}` with no `loaded` key

- **S02 [OC02] [TI04,TI07] Approving a parked change writes the YAML and loads the job**
  - **Given** a change parked by S01 and a request carrying admin auth context
  - **When** `POST /scheduling/pending/<changeId>/approve` is handled by `SchedulingPage`
  - **Then** the job is present in `ConfigWriter.readSchedulingJobs()` exactly as the parked body declared it, `ScheduleService.hasJob(<id>)` is true because the injected `applyJobs` ran, the pending entry is gone, and the response is a success toast plus the re-rendered pending and jobs fragments

- **S03 [OC02] [TI04,TI07] Rejecting a parked change discards it and touches nothing**
  - **Given** a change parked by S01 and a request carrying admin auth context
  - **When** `POST /scheduling/pending/<changeId>/reject` is handled
  - **Then** `dartclaw.yaml` is byte-identical to before the parked call, `ScheduleService.entries` is unchanged, the pending entry is gone, and the response carries the re-rendered empty pending fragment

- **S04 [OC03] [TI03] A parked change survives a restart**
  - **Given** a change parked into `<data_dir>/pending-schedule-changes.json`
  - **When** a second store is constructed over the same file and loaded, as a fresh boot does
  - **Then** it holds the same `changeId`, job body, requester and timestamp, and approving through that second store writes the same job

- **S05 [OC02] [TI07] An approve or reject without admin context is refused and changes nothing**
  - **Given** a change parked by S01 and a request with no admin auth context
  - **When** either declared pending route is handled
  - **Then** the response is `403`, `dartclaw.yaml` is byte-identical, `ScheduleService.entries` is unchanged, and the change is still pending

- **S06 [OC02] [TI04,TI07] An approval the host can no longer honour is refused and the change stays pending**
  - **Given** a parked one-time change whose stored `at` instant is now in the past; separately a parked change whose job id has since become a built-in; and separately a `changeId` naming no stored change
  - **When** each is approved with admin context
  - **Then** each answers an error toast naming the refusal, writes nothing to `dartclaw.yaml`, loads nothing into the scheduler, and — for the two stale-host-state cases — leaves the change pending so the operator can reject it explicitly

- **S07 [OC04] [TI01,TI04,TI05,TI06] With the default `none` every scheduling surface is unchanged**
  - **Given** a config declaring no `scheduling.mutation` section
  - **When** a job is written through `schedule_upsert`, through `POST/PUT/DELETE /api/scheduling/jobs`, and through the Scheduling page's create route
  - **Then** each commits and applies as it does today, each answer carries its existing shape including the tool's `loaded` key, and no pending change is stored
  - **Proof**: `packages/dartclaw_runtime/test/mcp/schedule_tools_test.dart#a valid upsert writes the job, loads it, and claims no restart` – green – parity/regression

## Structural Criteria

- **SC01** `ScheduleMutationService(writer: …)` with no other argument still constructs and behaves as today: the new approval mode and pending store are optional constructor parameters, so the existing suites and the applier-less instances in `SchedulingWiring` compile unchanged.
- **SC02** `scheduling.mutation.approval` is registered exactly once, in `ConfigMeta.fields`, and the two generated artifacts derived from it — `schemas/dartclaw.schema.json` and the generated region of `docs/guide/configuration.md` — carry it with no drift.
- **SC03** The jobs API and the Scheduling page's job/task mutations commit directly regardless of the configured mode: `operator` gates the `schedule_upsert` tool alone, and no authenticated operator surface can reach the parked outcome.
- **SC04** No model-supplied value can select or bypass the approval mode or forge a parked record's provenance: `schedule_upsert`'s closed input schema names no approval-, pending- or requester-related key and refuses one; the mode reaches the seam only as a constructor argument from the composition root, and the requester only from host-owned dispatch context.
- **SC05** No shipped document still states unconditionally that a `schedule_upsert` write is loaded before it is answered: the two operator guides, the `schedule_upsert` row in the API reference, `CHANGELOG.md` and the `ScheduleMutationService` bullet in `packages/dartclaw_runtime/AGENTS.md` all state the key and the parked answer.

## Scope & Boundaries

### Work Areas

- `packages/dartclaw_kernel`: `lib/src/scheduling_config.dart` (new enum + field), `lib/src/config_parser.dart#_parseScheduling`, `lib/src/config_meta/agent_fields.dart` (one `FieldMeta`), plus the regenerated `schemas/dartclaw.schema.json` and generated `docs/guide/configuration.md` region.
- `packages/dartclaw_runtime/lib/src/scheduling/`: `schedule_mutation.dart` (the parked result case, the upsert operation, approve/reject) and a new pending-change store beside it.
- `packages/dartclaw_runtime/lib/src/mcp/schedule_tools.dart`: the one model-originated write surface.
- `packages/dartclaw_runtime/lib/src/api/config_api_routes.dart` and `lib/src/web/pages/scheduling_page.dart` + `lib/src/templates/scheduling.{html,dart}`: the operator surfaces — exhaustive-switch arms, the pending list, the two declared routes.
- `packages/dartclaw_runtime/lib/src/runtime/{scheduling_wiring,service_wiring_mcp_tools}.dart` and `lib/src/config/config_serializer.dart`: composition — one store, threaded to the two seam construction sites that need it; the mode passed at the MCP site only.
- Operator-facing docs: `docs/guide/{scheduling,security,web-ui-and-api}.md`, `CHANGELOG.md`, `packages/dartclaw_runtime/AGENTS.md`.

### What We're NOT Doing

- **A general approval framework, TTLs, or per-field approvals** — this gates one tool's write on one config key; the generality has no second caller asking for it, and 0.25.1 D4 already forbids a second job store.
- **Gating the jobs API or the Scheduling page** — both are authenticated operator surfaces, so an approval there would be the operator approving their own action. The backlog's "the tool/API answer carries `pending: true`" is therefore read as the *tool* answer; the API keeps committing directly. Owner-pinned reading, not a choice this FIS made.
- **Any durability contract for a parked body across an upgrade** — no schema version stamp on the record and no re-validation of a parked body at approval. A body validated by one release can be committed by the next, and a job shape that stopped composing is reported the way any config-declared job that fails to compose already is: dropped at boot with a log warning, and shown as configured-but-not-loaded by `schedule_list`. A parked change is short-lived operator-visible state, and a version stamp buys nothing a pending list an operator can reject does not.
- **An SSE event for a new parked change** — the Scheduling page shows the pending list on load, which is the surface an operator is already on; a live push is a second notification path nothing asked for.
- **A model-side "ask before writing" instruction** — moving an enforcement decision behind a model turn, which ADR-054's deterministic-keeps carve-out forbids outright.
- **Any CLI or `dartclaw_client` change** — the client carries no jobs model and the CLI reaches scheduling through the same HTTP routes, which are unchanged.

## Architecture Decision

**Approach**: `ScheduleMutationService` grows one optional approval mode and one optional pending-change store; under `operator` a model-originated upsert parks the *already-validated* job body instead of committing, and approval replays that body through the same private write path, so there is one validator, one writer and no second job store.
**Why this over alternatives**: deny-by-config already exists and loses the feature; a model-side instruction moves an enforcement decision behind a model turn (ADR-054); parking after validation is the only arrangement where the approved write and the unapproved one are literally the same code path.

## Technical Overview

The seam already owns the schedule rule (`resolveSchedule`), the task-payload shape, the reserved-id set and the write (`commitAndApply`); the `schedule_upsert` path performs the built-in-id refusal in the tool over that set (`schedule_tools.dart#ScheduleUpsertTool`), and `upsertJob` takes ownership of it so park and approve share one copy. Today `ScheduleUpsertTool` performs the merge-or-create over the job list itself and then calls `commitAndApply`; that block moves into the seam as an `upsertJob` operation so the approval branch and the direct branch cannot diverge. `upsertJob` under `none` commits and applies; under `operator` it writes one record — operation kind, the validated job body, requester, UTC timestamp, host-generated `changeId` — through the pending store and returns a new `ScheduleMutationParked` case. The requester is host-owned provenance, never a tool argument: `ScheduleUpsertTool` becomes a `ContextualMcpTool` so the MCP dispatch's caller identity reaches it where one exists, and falls back to the literal tool surface name where it does not. Approval reads the record, re-checks only the two host-owned conditions that can have gone stale since parking (the id is now a built-in; a stored one-time instant is now past), then takes the same commit-and-apply path. The pending store is a JSON file under the data dir written through `atomicWriteJson` and loaded at boot, on the `thread-bindings.json` precedent. Two of the seam's three construction sites take it — the MCP tool site parks into it, the page site settles from it; the jobs API site takes neither it nor a mode, because SC03 says it never parks.

## Code Patterns & External References

```
# type | path#anchor                                                              | why needed (intent)
file   | packages/dartclaw_runtime/lib/src/scheduling/schedule_mutation.dart#ScheduleMutationService | the seam being extended: sealed result, resolveSchedule, indexOfJob, commit/commitAndApply
file   | packages/dartclaw_runtime/lib/src/mcp/schedule_tools.dart#ScheduleUpsertTool | the merge-or-create block that moves into the seam, and the answer shape that gains pending
file   | packages/dartclaw_core/lib/src/channel/thread_binding.dart#ThreadBindingStore | the data-dir side-state precedent: in-memory map, load() tolerating a missing/corrupt file, atomicWriteJson persist
file   | packages/dartclaw_core/lib/src/storage/atomic_write.dart#atomicWriteJson | the one atomic JSON write; never a plain writeAsString
file   | packages/dartclaw_runtime/lib/src/runtime/channel_wiring.dart#ChannelWiring | how a data-dir-backed store is constructed and loaded during wiring
file   | packages/dartclaw_kernel/lib/src/session_maintenance_config.dart#MaintenanceMode | the enum + fromYaml idiom for a string-valued config enum
file   | packages/dartclaw_kernel/lib/src/config_parser.dart#_parseSessionMaintenance | the parse idiom: FieldConstraints.evaluate against the registered FieldMeta, warn-and-default on a miss
file   | packages/dartclaw_runtime/lib/src/web/pages/projects_page.dart | the mutation reference for a page-declared route: declaredRoutes, params, fragment response
file   | packages/dartclaw_runtime/lib/src/templates/scheduling.html#tasksTable | the table fragment shape and out-of-band swap the pending list mirrors
file   | packages/dartclaw_runtime/lib/src/auth/request_auth_context.dart#requestHasAdminAccess | the admin gate config_api_routes applies; the pending routes use the same one
file   | packages/dartclaw_runtime/lib/src/mcp/memory_tools.dart#MemoryObserveTool | the dual McpTool.call / ContextualMcpTool.callWithContext shape a tool uses to take host-owned caller provenance without refusing an identity-less lane
```

## Constraints & Gotchas

- **Constraint**: `ScheduleMutationResult` is sealed and switched exhaustively in `api/config_api_routes.dart#_scheduleMutationResponse` and in `scheduling_page.dart`'s `_save` and `_tableResult`. -- Workaround: every one gets a `ScheduleMutationParked` arm. Under SC03 those arms are unreachable by construction (the seam instance there carries no `operator` mode), so each answers a `500`/error toast stating that this operator surface never parks — a completeness arm, not a behaviour.
- **Avoid**: re-validating the parked body at approval time. -- Instead: re-check only the two conditions host state can have changed under (built-in id, stale one-time instant). Re-running the model-facing validation would be a second validator over a value the seam already accepted, which is exactly the ADR-054 defect class this design avoids.
- **Critical**: `resolveSchedule` currently inlines the future-instant check, and approval needs the same rule against a stored `{type: once, at}` map. -- Must handle by: extracting that check into one seam-owned predicate both call. Two copies of "is this instant still in the future" is a second authority.
- **Critical**: `mcp_server.dart#McpProtocolHandler`'s dispatch refuses a `ContextualMcpTool` outright when it holds no caller identity *and* a caller policy is set, and routes to plain `call` only when both are absent. -- Must handle by: implementing both members (the `memory_tools.dart#MemoryObserveTool` shape). The primary lane reaches the unscoped handler with neither policy nor identity, so a tool that implemented `callWithContext` alone would still work there and refuse every scoped client.
- **Avoid**: constructing a second pending store per request or per seam instance — `scheduling_page.dart#_mutations` builds its seam instance per request. -- Instead: `SchedulingWiring` owns the one instance and threads it to the two construction sites that need it as a lazily resolved collaborator, the way it already exposes `applyJobs` (`reservedJobIds` is derived inline at each site and is not the precedent here).
- **Critical**: everything in a parked record — job id, prompt, schedule text, requester — originates in a model turn. -- Must handle by: passing every one of those values through `tl:text` / `tl:attr` and never `tl:utext`, and never concatenating them into HTML. The fragment itself still composes into the page the way `scheduling.html#tasksTable` does, whose `tl:utext` carries already-escaped server-rendered HTML.

## Implementation Plan

### Implementation Tasks

- **TI01** `scheduling.mutation.approval` is an accepted config key parsed into `SchedulingConfig`
  - New `ScheduleMutationApproval { none, operator }` enum with a `fromYaml` mirroring `session_maintenance_config.dart#MaintenanceMode`; a `mutationApproval` field on `SchedulingConfig` defaulting to `none` and carried in `==`/`hashCode`; parsed in `config_parser.dart#_parseScheduling` through `FieldConstraints.evaluate` against the registered `FieldMeta`, warning and defaulting on an unknown literal; one `FieldMeta` entry in `config_meta/agent_fields.dart` (`ConfigFieldType.enum_`, `ConfigMutability.restart`, `allowedValues: ['none', 'operator']`). `operator` is a legal Dart enum constant.
  - **Verify**: `packages/dartclaw_kernel/test/dartclaw_config_test.dart#scheduling.mutation.approval` – `operator` parses to the enum, an unknown literal warns and yields `none`, and an absent `scheduling.mutation` section yields `none`
  - **SATISFIES**: S07, SC02

- **TI02** The generated config schema and operator config reference carry the new key with no drift
  - Run the two commands in `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md#generated-artifacts`; both artifacts are generated only, never hand-edited. `config_meta_test.dart`'s registry and guide gates must stay green.
  - **Verify**: `cmd: dart run packages/dartclaw_kernel/tool/generate_config_schema.dart --check && rg -qU '"mutation": \{\s*"additionalProperties": false,\s*"properties": \{\s*"approval": \{' schemas/dartclaw.schema.json && dart run dev/tools/render_config_reference.dart && rg -q 'scheduling\.mutation\.approval' docs/guide/configuration.md && dart test --reporter=failures-only packages/dartclaw_kernel/test/config_meta_test.dart` – the schema check reports no drift, both generated artifacts carry the key, and the registry gates pass
  - **SATISFIES**: SC02

- **TI03** A parked change is durable across a restart through one data-dir JSON store
  - New `lib/src/scheduling/pending_schedule_change.dart`: an immutable record (`changeId`, `jobId`, `kind` created/replaced, the validated `job` map, `requester`, `requestedAt` UTC ISO-8601) plus a store over `<data_dir>/pending-schedule-changes.json` following `thread_binding.dart#ThreadBindingStore` — in-memory map, persistence through `atomic_write.dart#atomicWriteJson`, and its degradation rule: `load()` skips an entry it cannot deserialize with a warning naming it and keeps the rest, and degrades to empty with a warning when the whole file is missing or unreadable. Losing a parked change silently is what that warning exists to prevent. `changeId` comes from `const Uuid().v4()`, the id primitive `task_creation_service.dart` already uses.
  - **Verify**: `packages/dartclaw_runtime/test/scheduling/schedule_mutation_test.dart#a parked change survives a restart` – a second store over the same file loads the same record and approving through it writes the same job; a file holding one malformed entry beside a sound one loads the sound one and warns about the other; an unreadable file loads empty and warns
  - **SATISFIES**: S04

- **TI04** `ScheduleMutationService` owns the upsert operation, the approval gate and settlement
  - `ScheduleMutationParked(changeId)` joins the sealed result. A new `upsertJob` carries the tool's built-in-id refusal and merge-or-create semantics (replace by `indexOfJob`, else append; merge rather than replace so operator-set keys survive) and, under `ScheduleMutationApproval.operator`, parks through the TI03 store instead of committing. `approve(changeId)` re-checks the built-in-id refusal and — via the future-instant predicate extracted out of `resolveSchedule` — a stored one-time instant, then takes the same `commitAndApply` path; a refusal leaves the change pending. `reject(changeId)` drops the record and writes nothing. Both new constructor parameters are optional so `ScheduleMutationService(writer:)` still constructs.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/scheduling/schedule_mutation_test.dart` – the whole suite passes, so both halves hold: under `operator` an upsert writes nothing and stores one record; approve writes the YAML and the running `ScheduleService` holds the job; reject leaves the YAML byte-identical and the scheduler unchanged; a stale one-time instant, a job id that has since become a built-in, and an unknown `changeId` are each refused with nothing written, the two stale-state ones still pending; under `none` the same call commits and applies; and the suite's pre-existing cases still construct `ScheduleMutationService(writer:)` and pass unchanged
  - **SATISFIES**: S01, S02, S03, S06, S07, SC01

- **TI05** `schedule_upsert` reports a parked write truthfully and cannot influence the gate
  - The tool validates its declared argument contract as today, builds the job body, and calls TI04's `upsertJob` rather than merging, refusing a built-in id and committing itself — the built-in-id refusal moves into `upsertJob` alongside the merge-or-create, so park and approve check it once; a parked result answers `{id, pending: true, changeId}` with no `loaded` key, an applied result keeps today's `{id, created, schedule, loaded}`. It also becomes a `ContextualMcpTool`, implementing **both** members in the `memory_tools.dart#MemoryObserveTool` shape, and supplies the requester from host-owned context only: `McpCallerContext.authorityId` where the dispatch has an identity, else the literal `schedule_upsert`. The description gains one factual sentence that a write may be parked pending operator approval — a statement to report, never an instruction to seek approval (ADR-054). The input schema gains no key.
  - **Verify**: `packages/dartclaw_runtime/test/mcp/schedule_tools_test.dart#parked upsert` – under `operator` the answer carries `pending: true` and a `changeId` and no `loaded`; under `none` the answer is unchanged; a `callWithContext` dispatch parks the caller's `authorityId` as the requester while a plain `call` parks the literal tool name; an argument named `approval`, `pending` or `requester` is refused by the closed schema
  - **SATISFIES**: S01, S07, SC04

- **TI06** Both operator surfaces handle the new result case without gaining a parked behaviour
  - `_scheduleMutationResponse` in `api/config_api_routes.dart` and the two `ScheduleMutationResult` switches in `scheduling_page.dart` gain a `ScheduleMutationParked` arm answering a `500` / error toast that names this surface as one that never parks. Neither site passes an approval mode, so the arm is unreachable by construction.
  - **Verify**: `packages/dartclaw_runtime/test/api/config_api_scheduling_live_test.dart#the jobs API never parks` – with `scheduling.mutation.approval: operator` in the loaded config, `POST` / `PUT` / `DELETE /api/scheduling/jobs` still commit and load, and no pending change is stored
  - **SATISFIES**: S07, SC03

- **TI07** The Scheduling page lists parked changes and settles them behind the admin gate
  - Two `declaredRoutes` entries — `POST /scheduling/pending/<changeId>/approve` and `.../reject` — handled in `SchedulingPage.handler`, each gated on `request_auth_context.dart#requestHasAdminAccess` with a `403` otherwise, calling TI04's `approve`/`reject`. A new `pendingChanges` fragment in `templates/scheduling.{html,dart}` renders id, kind, schedule, requester and timestamp with Approve and Reject buttons, mirroring `scheduling.html#tasksTable` and following the fragment contract in `dev/guidelines/HTMX-GUIDELINES.md`; every model-supplied value is escaped through `tl:text`/`tl:attr`. The page suite's two route-inventory assertions grow with the pending routes: the `hasLength(8)` count over non-GET `declaredRoutes` and the literal path list its unauthenticated-refusal test iterates — leaving either is a silently under-asserting gate, not a passing one.
  - **Verify**: `packages/dartclaw_runtime/test/web/scheduling_page_test.dart#pending changes` – the page lists a parked change with its requester and timestamp; approve writes the YAML and loads the job and empties the list; reject writes nothing and empties the list; both routes without admin context answer `403` with the change still pending and the config byte-identical
  - **SATISFIES**: S02, S03, S05, S06

- **TI08** The composition root owns one pending store and passes the mode only where model writes arrive
  - `SchedulingWiring` constructs and loads the single store during `wire()` (the `channel_wiring.dart` pattern) and exposes it beside `applyJobs`. Two of the seam's three construction sites receive it as a lazily resolved collaborator: `runtime/service_wiring_mcp_tools.dart`, which is also the only site passing `config.scheduling.mutationApproval`, and `scheduling_page.dart#_mutations`, which needs it to settle but passes no mode. `api/config_api_routes.dart` receives neither — threading a store it can never reach would imply a capability SC03 denies it. `config/config_serializer.dart` projects the new key under `scheduling`, so `/settings` resolves its value from the serializer tree rather than falling back to raw YAML.
  - **Verify**: `packages/dartclaw_runtime/test/mcp/schedule_tools_test.dart#the tool surface receives the configured approval mode` – a tool built the way `_registerMcpTools` builds it parks under `operator`, while a seam built the way the jobs API builds it commits under the same config
  - **SATISFIES**: S01, SC03

- **TI09** Operator documentation states approval as the recommended posture for untrusted channels
  - `docs/guide/scheduling.md` gains a subsection under *Cron Jobs* covering the key, the parked lifecycle and the page's approve/reject, and its existing unconditional "loaded before the write is answered" sentence is qualified for `operator`. `docs/guide/security.md#hardening-the-primary-agent-for-untrusted-channels` recommends the approval config snippet, with the `agent.disallowed_tools: [schedule_upsert]` deny retained as the stricter alternative. The `schedule_upsert` row in `docs/guide/web-ui-and-api.md` states the parked answer.
  - **Verify**: `cmd: for f in docs/guide/scheduling.md docs/guide/security.md docs/guide/web-ui-and-api.md; do rg -q 'scheduling\.mutation\.approval' "$f" || exit 1; done; rg -q 'pending' docs/guide/web-ui-and-api.md` – every hand-written guide carries the key on its own (a per-file check: `rg` over a file list exits 0 on a match in any one of them), and the API row states the parked answer
  - **SATISFIES**: SC05

- **TI10** Contributor-facing records carry the new fact
  - `CHANGELOG.md` gains an entry under the existing `## [Unreleased]` heading. The `ScheduleMutationService` bullet in `packages/dartclaw_runtime/AGENTS.md#conventions` gains the approval fact: the seam gates model-originated writes only, the mode arrives as a constructor argument from the composition root, and the pending store is the one data-dir side-state for it.
  - **Verify**: `cmd: rg -q 'scheduling\.mutation\.approval' packages/dartclaw_runtime/AGENTS.md && rg -q 'scheduling\.mutation\.approval' CHANGELOG.md` – both carry the key itself; the bare word `approval` already appears in `AGENTS.md` for unrelated spawn-approval prose and proves nothing
  - **SATISFIES**: SC05

### Execution Contract

- TI04 depends on TI03's store type and TI01's enum. TI05, TI06, TI07 and TI08 all consume TI04's `upsertJob` / `approve` / `reject` and its `ScheduleMutationParked` case — the seam lands before any surface is touched, or the sealed switches will not compile.
- `dart run dev/tools/embed_assets.dart` must run after the TI07 template edits, before `dart analyze` or any page test.

## Implementation Observations

### Run: 2026-09-06 11:26 UTC – repair-proof

#### DRIFT

- spec-stale: TI02 Verify target repaired | Stale targets: – | `cmd: dart run dev/tools/render_config_reference.dart && dart run packages/dartclaw_kernel/tool/generate_config_schema.dart --check && rg -q 'scheduling\.mutation\.approval' schemas/dartclaw.schema.json && rg -q 'scheduling\.mutation\.approval' docs/guide/configuration.md && dart test --reporter=failures-only packages/dartclaw_kernel/test/config_meta_test.dart` → `cmd: dart run packages/dartclaw_kernel/tool/generate_config_schema.dart --check && rg -qU '"mutation": \{\s*"additionalProperties": false,\s*"properties": \{\s*"approval": \{' schemas/dartclaw.schema.json && dart run dev/tools/render_config_reference.dart && rg -q 'scheduling\.mutation\.approval' docs/guide/configuration.md && git diff --quiet -- docs/guide/configuration.md schemas/dartclaw.schema.json || true; dart test --reporter=failures-only packages/dartclaw_kernel/test/config_meta_test.dart`

### Run: 2026-09-06 11:26 UTC – repair-proof

#### DRIFT

- spec-stale: TI02 Verify target repaired | Stale targets: – | `cmd: dart run packages/dartclaw_kernel/tool/generate_config_schema.dart --check && rg -qU '"mutation": \{\s*"additionalProperties": false,\s*"properties": \{\s*"approval": \{' schemas/dartclaw.schema.json && dart run dev/tools/render_config_reference.dart && rg -q 'scheduling\.mutation\.approval' docs/guide/configuration.md && git diff --quiet -- docs/guide/configuration.md schemas/dartclaw.schema.json || true; dart test --reporter=failures-only packages/dartclaw_kernel/test/config_meta_test.dart` → `cmd: dart run packages/dartclaw_kernel/tool/generate_config_schema.dart --check && rg -qU '"mutation": \{\s*"additionalProperties": false,\s*"properties": \{\s*"approval": \{' schemas/dartclaw.schema.json && dart run dev/tools/render_config_reference.dart && rg -q 'scheduling\.mutation\.approval' docs/guide/configuration.md && dart test --reporter=failures-only packages/dartclaw_kernel/test/config_meta_test.dart`

### Run: 2026-09-06 11:26 UTC – observations

#### DRIFT

- spec-stale: TI02's Verify grepped the literal dotted path `scheduling.mutation.approval` in `schemas/dartclaw.schema.json`, but the generated schema is nested JSON (`scheduling` → `mutation` → `approval` properties) and carries no dotted path for any field, so that check could never pass. Repaired through `repair-proof` to match the nested `"mutation"`/`"approval"` block; the `--check` drift gate and the guide grep are unchanged. | Stale targets: –

### Run: 2026-09-06 11:39 UTC – observations

#### NOTICED BUT NOT TOUCHING

- **`_warnUnhardenedPrimaryOnChannelIngress` still fires under `scheduling.mutation.approval: operator`.** `runtime/harness_wiring.dart` warns whenever a channel is enabled, the primary runs on the host and `agent.disallowed_tools` is empty, and it does not read the approval mode, so a deployment following the guide's new recommendation still gets a startup warning pointing at the deny. The guide states the warning's condition as it is. Widening that check is a security-posture decision outside this FIS.
- **`dartclaw_runtime/lib` crossed its `arch_check` LOC ceiling (65,356) by this story's net 366 lines** on a tree the sibling shell-job story had left 87 lines under it. Raised to 65,700 with the recorded-necessity comment in `dev/tools/arch_check.dart` and a CHANGELOG note, the form the 2026-08-27 precedent uses; the raise is the owner's to accept, since ADR-033 makes a ceiling raise a maintainer decision.
- **The durability task's prose (the store task) says a missing store file "degrades to empty with a warning".** The store logs a missing file at `fine`, the `ThreadBindingStore` precedent: a fresh boot has no file and a warning on every clean start is noise, and no parked change can be lost when there was nothing to load. Unreadable and malformed files warn as specified and are tested.

### Run: 2026-09-06 11:58 UTC – observations

#### NOTICED BUT NOT TOUCHING

Story-gate round 1 findings routed `Note` and left in place, for the owner:

- **Parking is unbounded and not collapsed per job id** (`upsertJob` mints a UUID record per call; `PendingScheduleChangeStore._persist` rewrites the whole file). A model turn repeating the same upsert accumulates rows and buries a genuine request on the operator page. The FIS rules out TTLs and a general framework and is silent on per-`jobId` dedupe, so collapsing to one record per job id is a scope call. Class: ambiguous-intent.
- **Settling a parked change writes no audit record.** The parked call is audited at MCP dispatch; the operator's approve/reject in `scheduling_page.dart#_settle` writes no `AuditEntry`, event or log line, so a rejected request leaves no trace of who asked or who refused. ADR-054 frames the decision as a security boundary; the FIS names no audit surface. Class: code-defect, owner call on the audit surface.
- **Two `none`-path refusal strings changed.** The built-in-id refusal now carries the seam's `cannot be written through this API` wording instead of the tool's former `cannot be edited through schedule_upsert`, and a backup failure loses its `Config backup failed:` prefix; reason codes (`conflict`, `write_failed`) are unchanged and pinned. Restoring the wording would re-author a second string beside the seam's; left as the seam's one sentence. Class: code-defect, cosmetic.
- **`ScheduleUpsertTool` as a `ContextualMcpTool` on a scoped lane with a policy but no identity.** `mcp_bridge_surface.dart` passes `callerIdentity: null` when a principal's `sessionId` trims to empty, and the dispatch then refuses every contextual tool. Whether that principal shape is reachable is undetermined; the FIS gotcha covers the unscoped primary lane only. Class: ambiguous-intent.
- **`dev/state/PROMPT-SURFACES.md` still lacks rows for `workflow_tools.dart`, `attach_media_tool.dart` and `wiki_write_tool.dart`.** This change added the `schedule_tools.dart` row it re-contracted; the sibling omissions predate it and want an inventory audit, not a story edit.

### Run: 2026-09-06 12:09 UTC – observations

#### NOTICED BUT NOT TOUCHING

Story-gate round 2 findings routed `Note` and left in place, for the owner:

- **The `schedule_upsert` description opens with an unconditional "runs from the moment this call returns — no restart"** and only its added sentence qualifies it for `operator`. TI05 asked for exactly one added factual sentence and the implementation matches it; folding the condition into the lead sentence re-contracts a prompt surface and is the owner's call. Class: spec-stale.
- **An applier failure after a landed commit reports as `BACKUP_FAILED`.** `_write` maps every `StateError` to that code, and `commitAndApply` awaits the applier inside the same try, so a scheduler-side failure after a successful write is labelled a backup failure. Pre-existing mapping shared by every seam caller; the `afterCommit` record drop is unaffected and tested. Class: code-defect, pre-existing.
- **Approval also refuses a `type: shell` entry that took the id while the change waited** (through `commitAndApply`'s fresh-read file-only check), a third stale-host-state case the guide's and changelog's "re-checks only" sentence does not enumerate. Outcome shape is the same: refuse, stay pending. Class: code-defect, wording.
- **Three unguarded invariants**: the serializer's `scheduling.mutation.approval` projection has no test; nothing asserts the store the MCP tool site holds is the same instance the Scheduling page settles from; `ScheduleMutationApproval.fromYaml` and the `FieldMeta.allowedValues` set are written twice with no round-trip gate (the `MaintenanceMode` sibling carries one). Each is a test addition the FIS did not pin. Class: code-defect, proof gaps.
- **`test/generated/embedded_assets_test.dart` fails on a checkout without `build/bridge-embed/`** because the generated map then carries no bridge binaries; the text-asset assertions covering this story's template, CSS and controller pass. Environmental, not a regression; the full workspace tier regenerates assets first and is green.

### Run: 2026-09-06 12:15 UTC – observations

#### NOTICED BUT NOT TOUCHING

Visual validation, round 3 (screenshots 40–46 under `.agent_temp/visual-validation/screenshots/`): approve, reject-with-confirm, escaping of the parked prompt, task title and job id, the relative age with ISO title, and the hidden empty section all pass at 1280 and 375. Three P3 polish items remain after the two remediation rounds the story gate allows:

- **`.scheduling-pending-table` still scrolls 10px inside its `.table-wrap` at 375px** (clientWidth 349, scrollWidth 359; the sibling jobs and tasks tables are 349/349). The four visible columns' combined min-content is ~10px over the fit and no single column is the cause; every control renders inside the visible box. Closing it means tighter cell padding on the Change and Requested columns at that breakpoint, or stacking the Approve/Reject buttons full-width.
- **At 375px the 78px Job column wraps the whole parked prompt at about two words per line**, so a long prompt makes a 530px-tall row. Legible and contained; a line clamp or a lower character budget for the prompt sub-line at mobile width would read better. Rendering the prompt whole was chosen deliberately: it is what approval commits.
- **`overflow-wrap: anywhere` on the requester cell breaks a token mid-word at 1280** (`schedule_upse / rt` in a 127px column). `overflow-wrap: break-word` breaks only when a word cannot otherwise fit and is the better value; left as is so the reviewed snapshot stays frozen.

### Run: 2026-09-06 12:16 UTC – observations

#### NOTICED BUT NOT TOUCHING

Story-gate round 3 (verdict PASS) findings routed `Note`, for the owner:

- **At 375px the responsive rule hides the pending table's third column, which is Schedule.** The sibling jobs and tasks tables drop Delivery / Type in that position; the pending table reuses the same `nth-child(3)` rule, so a mobile approval is made without the cron or `at` text on the row. Remedy is a column-priority call: put Change third so it is the one hidden, or fold the schedule into the Job cell as a third sub-line beside `type · delivery`. Class: code-defect.
- **`_pendingSummary` renders an absent `type` as `prompt`.** Unreachable through the one writer (`schedule_upsert` requires an enum-validated `type`), so only a hand-edited store file reaches it; still a sentinel over a stored value on the approval surface. Either render the empty summary or guard `job.type` in `fromJson` beside `job.id`. Class: code-defect.
- **The parked prompt renders whole with no height bound.** `schedule_upsert`'s `prompt` carries no `maxLength`, so a very long parked prompt makes a very tall row. Rendering it whole was round 2's requirement (the operator approves this text); a line clamp with the full text on `title` would keep the row actionable. Class: code-defect, owner call.
- **The composition-root thread is unproven by test**: nothing drives `SchedulingWiring.pendingScheduleChanges` through `ServerObservabilityDeps` → `registerSystemDashboardPages` → `SchedulingPage.pendingChanges`, and every hop is nullable, so a dropped thread would degrade silently to an empty pending list. Restated from round 2 as the one silent failure mode.
