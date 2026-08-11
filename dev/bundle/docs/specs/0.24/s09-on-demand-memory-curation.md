# Feature Implementation Specification: On-Demand Memory Curation

**Plan**: dev/bundle/docs/specs/0.24/plan.json
**Story-ID**: S09

## Feature Overview and Goal

**Intent**: Let an operator improve personal memory with model semantic judgment while keeping every commit explicit, bounded, conflict-safe, and host-controlled.

**Expected Outcomes**:

- [OC01] An explicit operator action curates a bounded current memory snapshot through one proposal-only model turn and the existing atomic memory authority.
- [OC02] Operators receive truthful running, succeeded, conflicted, or failed outcomes with exact changed/no-op IDs or actionable rejection reasons and no ambiguous partial success.
- [OC03] Curation never starts from a size threshold, heartbeat, scheduled-job completion, model recursion, or any other automatic trigger.

## Required Context

- `dev/bundle/docs/specs/0.24/plan.json#stories.8` – exact S09 scope, dependencies, high-risk classification, host-callback system-action seam, and automatic-dispatch removal boundary.
- `dev/bundle/docs/specs/0.24/plan.json#sharedDecisions` – canonical corpus, single revision/mutation authority, observation trust, bounded context, read-only system-action registration, and 0.24/0.27 release boundaries inherited by this story.
- `dev/bundle/docs/specs/0.24/plan.json#riskSummary.8` – proposal-only access, malformed/timeout no-op, conflict, recursion, and zero-automatic-dispatch proof obligations.
- `dev/bundle/docs/specs/0.24/s02-atomic-memory-corpus.md#technical-overview` – coherent collection snapshot, bounded corpus candidates, canonical identities/revisions/provenance, and omitted-document discipline used for curation.
- `dev/bundle/docs/specs/0.24/s05-atomic-memory-apply.md#architecture-decision` – the sole host-owned CAS mutation authority and canonical-before-derived outcome contract curation must call unchanged.
- `dev/bundle/docs/specs/0.24/s05-atomic-memory-apply.md#implementation-plan` – exact changed/no-op accounting, operation-level rejection, index degradation, and the prerequisite removal of `MemoryConsolidator` plus threshold/heartbeat/schedule wiring.
- `dev/bundle/docs/specs/0.24/s06-fresh-bounded-turn-context.md#architecture-decision` – rendering of S02's coherent candidates into the dual-capped index projection reused as curation input.
- `dev/bundle/docs/specs/0.24/prd.md#fr2-guarded-memory-tools` – shared validation/mutation authority, closed apply operations, CAS, per-operation rejection, and index-degradation semantics.
- `dev/bundle/docs/specs/0.24/prd.md#fr3-on-demand-semantic-curation` – authoritative snapshot, proposal-only, host-apply, conflict, no-op, recursion, and no-autonomy contract.
- `dev/bundle/docs/specs/0.24/prd.md#fr4-bounded-turn-context` – existing 150-line/`memory.max_bytes` index projection reused without whole-corpus loading.
- `dev/bundle/docs/specs/0.24/prd.md#fr7-operator-control-and-observability` – existing run-now surface and required running/succeeded/conflicted/failed lifecycle vocabulary.
- `dev/bundle/docs/specs/0.24/prd.md#fr8-simplification-and-release-boundaries` – no new package, database, daemon, scheduler, approval framework, wiki/KG write expansion, or 0.27 autonomy.
- `dev/bundle/docs/specs/0.24/prd.md#user-flows` – explicit curation, concurrent conflict, committed-but-index-degraded, and operator-visible result journeys.
- `dev/bundle/docs/specs/0.24/prd.md#constraints` – trusted-host/untrusted-model boundary and mandatory reuse of the shared workspace lock and atomic-write discipline.
- `dev/adrs/007-system-prompt-architecture.md#decision` – preserve provider/DartClaw base instructions when dispatching the isolated proposal turn.
- `dev/architecture/observability-operations-architecture.md#11-heartbeat--scheduling` – current heartbeat, scheduling, and job-completion seams whose automatic consolidation coupling must remain absent after S05.

## Acceptance Scenarios

- [ ] **S01 [OC01,OC02] [TI01,TI02,TI03,TI04] One explicit curation request commits a wholly valid mixed proposal and reports exact IDs**
  - **Given** collection revision `41`, a bounded index, current topic entries A–E, and provenance-labelled observations O1–O3
  - **When** the operator runs the existing `memory-curation` run-now action, the host snapshots revision `41`, and one proposal-only model turn returns valid add, revise, merge, remove, and exact-no-op operations referencing only included sources
  - **Then** the host applies the complete proposal once through S05's mutation authority, advances the collection to revision `42`, and reports `succeeded` with the host-generated add ID plus exact changed IDs and exact-no-op E
  - **And** the model invokes no mutation/file/job capability and cannot report commit success independently of the host result

- [ ] **S02 [OC01] [TI01,TI02] Oversized candidate state produces one explicit bounded, provenance-safe proposal context**
  - **Given** an index, topic corpus, and observation corpus that each exceed their curation limits, including newer high-priority entries before older trailing entries
  - **When** an explicit curation run assembles its proposal context
  - **Then** the index is the S06 projection capped at 150 rendered lines and `memory.max_bytes`, topic candidates are limited to 50 entries and 64 KiB, and newest uncurated observations are limited to 50 entries and 64 KiB
  - **And** selection is deterministic by index priority/recency then canonical identity, omitted documents are not opened or encoded, and the snapshot records included IDs/revisions/provenance plus truncation/coverage state
  - **Proof**: `packages/dartclaw_server/test/knowledge/knowledge_inbox_service_test.dart#S01 stable file runs a cron extraction turn and becomes durable synthesized knowledge` – green – parity/regression for one isolated, read-only, no-tools structured-output turn

- [ ] **S03 [OC02] [TI03,TI04] Post-commit index failure reports durable curation success as degraded**
  - **Given** a wholly valid current-revision proposal and an injected derived-index failure after canonical replacement succeeds
  - **When** the host applies the proposal
  - **Then** curation reports `succeeded` with the committed revision and exact changed/no-op IDs, exposes degraded index state plus its repair action, keeps the canonical change durable, and does not claim healthy convergence

- [ ] **S04 [OC02] [TI02,TI03,TI04] One invalid operation rejects the entire proposal with no changed IDs**
  - **Given** a byte-for-byte snapshot of canonical memory, revision, deletion audit, and index rows
  - **When** the model returns one structurally parseable proposal containing a valid add plus an unsupported kind, an omitted source reference, and a target not present in the bounded snapshot
  - **Then** curation reports `failed`, each operation receives its precise validation reason or a not-applied-because-proposal-rejected reason, changed/no-op ID lists are empty, and every captured canonical/index/audit value remains unchanged

- [ ] **S05 [OC02] [TI02,TI04] Malformed, timed-out, failed, or cancelled proposal turns are retryable no-ops**
  - **Given** an explicit curation run with a valid bounded snapshot
  - **When** its single model turn times out, fails, is cancelled, emits no payload, emits multiple payloads, or returns malformed/unknown structured fields
  - **Then** curation reports `failed` with a bounded reason, never calls the apply authority, changes no canonical/index/audit state, and starts no retry until another explicit operator request

- [ ] **S06 [OC02] [TI03,TI04] A concurrent memory commit makes the curation proposal conflict without partial effect**
  - **Given** curation snapshots collection revision `51` and another valid writer commits revision `52` before proposal application
  - **When** the host submits the wholly valid curation proposal with snapshot revision `51`
  - **Then** curation reports `conflicted` with current revision `52`, empty changed/no-op IDs, no curation effect, and guidance to rerun explicitly from a fresh snapshot

- [ ] **S07 [OC02,OC03] [TI03,TI04,TI05] The reserved system action is unambiguous, read-only, non-recursive, and the only curation dispatch path**
  - **Given** one configured scheduled job, the registered `memory-curation` system action, over-threshold memory, an enabled heartbeat checklist, and one curation run blocked inside its model turn
  - **When** API/CLI/Web list and show scheduling entries, an operator runs curation, heartbeat and the ordinary job complete, the model attempts any tool call, and a second operator requests curation
  - **Then** list/show merge the ordinary job and immutable system-action descriptor, only the shared run endpoint starts curation, the second request reports already running, and the proposal turn's tool call is blocked
  - **And** create/edit/delete/toggle/YAML operations reject the system action without changing configuration; no timer, scheduled fire, automatic retry, successful-job callback, apply completion, or curation result dispatches it
  - **Given** separately, one startup YAML job uses reserved ID `memory-curation`, and live config create/edit requests each attempt to assign that ID to a configured job
  - **When** startup validates jobs against registered actions and each config mutation validates its proposed complete job list
  - **Then** every collision fails before scheduling starts, config or restart-pending state changes, or list/show/run publishes an ambiguous identity; the prior valid live projection remains unchanged after rejected mutations
  - **And** no system-action-wins, configured-job-wins, alias, rename, shadow, or compatibility behavior resolves the collision
  - **Proof**: `packages/dartclaw_server/test/scheduling/schedule_service_test.dart#on-demand run delivers through the configured mode` – green – parity/regression for the existing run-now job/session/delivery path

## Structural Criteria

- [ ] Curation calls the same S05 validation, collection-CAS, canonical commit, deletion-audit, and post-commit index authority as `memory_apply`; it creates no second writer, lock, queue, revision, or operation schema.
- [ ] The proposal turn uses one isolated cron session, one model turn, read-only mode, the established no-tools guard behavior, and delimiter-safe untrusted-data framing; host owner scope and expected revision never come from model output.
- [ ] The curation lifecycle has exactly `running`, `succeeded`, `conflicted`, and `failed` states. One atomically persisted, bounded action record survives restart and carries start/completion/last-success time, snapshot/current/committed revision, changed/no-op IDs, operation reasons, S05 degradation facts, and S08 health/recovery state where applicable.
- [ ] `ScheduleService` owns one immutable host-callback `SystemAction` registration seam. It merges system actions into read-only list/show and routes them through `runJobNow` plus the existing `_running` overlap guard, but never passes them to timers, pause/resume, `_executeWithRetry`, delivery, or scheduling YAML mutation.
- [ ] Registered `SystemAction` IDs are reserved. Startup and scheduling-config create/edit validate the complete configured-job ID set against them before timer setup, config/restart-pending writes, or list/show/run publication; any intersection is a typed validation failure, never a precedence or compatibility rule.
- [ ] `memory-curation` is the only registered memory system action and owns no schedule, timer, automatic retry, heartbeat hook, post-job hook, or autonomous policy. S11 exposes this same descriptor and persisted lifecycle across existing API/CLI/Web surfaces.
- [ ] Production Dart, exports, wiring, prompts, and current architecture docs contain no `MemoryConsolidator`, threshold consolidator, heartbeat consolidator, or successful-job consolidator path after S05; S09 adds only the explicit workflow and regression proof.
- [ ] Curation writes only guarded personal memory through S05; raw observations remain provenance sources, and wiki/KG write contracts remain unchanged.

## Scope & Boundaries

### Work Areas

- Bounded curation snapshot and proposal/result contracts in existing core/server memory seams
- Isolated no-tools model-turn orchestration and strict structured proposal parsing
- Shared S05 apply-authority invocation and lifecycle/result translation
- One `ScheduleService` host-callback system-action registration, shared run/overlap routing, persisted typed lifecycle, and merged read-only list/show identity
- Component/fault tests plus automatic-dispatch and recursion fitness coverage

### What We're NOT Doing

- Removing `MemoryConsolidator`, `memory_save`, or their legacy wiring again – S05 owns that contraction; S09 proves the automatic path stays absent and does not restore it.
- Adding scheduled, threshold, heartbeat, idle-time, or retry-driven curation – 0.27 owns autonomous stewardship and policy.
- Adding an approval system or letting the model call `memory_apply` directly – the explicit operator action starts host orchestration, and the host alone commits.
- Redesigning job, CLI, API, dashboard, or Memory/Knowledge presentation – S09 supplies the merged read-only list/show/run contract and lifecycle; S11 presents it on the existing surfaces.
- Applying curation operations to wiki, KG, runtime learnings, raw observations, or opaque legacy spans – they may supply bounded provenance/context, but S05's personal-memory operation contract remains closed.

## Architecture Decision

**Approach**: Add one immutable `SystemAction` host-callback registration seam inside `ScheduleService`, reserve every registered action ID before accepting configured jobs, merge only a collision-free set into read-only list/show/run, and register `memory-curation` there. The callback persists the bounded typed curation lifecycle, snapshots S02 corpus candidates rendered through S06, runs one isolated no-tools proposal turn, then submits the parsed operations and host-held revision to S05's mutation authority.
**Why this over alternatives**: A fake `ScheduledJob` would inherit timer/retry/delivery/YAML semantics and is not runnable through the current callback filter. The small system-action branch reuses the existing operator endpoint and overlap guard without another scheduler, administration surface, writer, approval layer, or model-held commit capability.

## Technical Overview

`ScheduleService` keeps configured `ScheduledJob` execution unchanged and adds a separate immutable `SystemAction` map. Before `start()` can arm timers or any list/show/run consumer receives the merged projection, construction/wiring rejects a configured-job ID present in the action map. Config create/edit applies the same reserved-ID check to the proposed complete job list before YAML or restart-pending state changes. There is no precedence, shadowing, renaming, alias, or compatibility path. A collision-free list/show merges both descriptor kinds; run-now resolves either kind and shares the existing synchronous `_running` overlap guard. A system action invokes its host callback directly, persists typed running/terminal records, and bypasses timer registration, pause/resume, automatic retry, scheduled delivery, and every YAML create/edit/delete path.

An accepted curation callback records `running` through the existing file-backed atomic `KvService`, consumes S02's coherent collection snapshot and bounded corpus candidates, and renders the index portion through S06. Snapshot content is framed as untrusted data and carries stable IDs, entry revisions, provenance, and truncation state. A one-turn, read-only, no-tools worker returns exactly one structured operation proposal; the host rejects malformed output before any mutation and attaches the snapshot revision and owner scope itself. S05's authority then returns applied, exact-no-op, validation-rejected, conflicted, canonical-failed, or committed-but-index-degraded facts. Curation atomically persists their bounded mapping to the four lifecycle states; S08 remains the owner of durable index health. No terminal path retries or dispatches another curation run.

## Code Patterns & External References

```text
# type | path#anchor | why needed (intent)
file | packages/dartclaw_server/lib/src/scheduling/schedule_service.dart#ScheduleService.runJobNow | Existing operator start and synchronous overlap guard to share while branching system actions away from retry/delivery/timers
file | packages/dartclaw_server/lib/src/scheduling/scheduled_job.dart#ScheduledJob | Configured timer/retry/delivery contract that `SystemAction` must not impersonate or inherit
file | packages/dartclaw_server/lib/src/api/config_api_routes.dart#configApiRoutes | Current YAML-only list/show and mutation routes to merge with immutable actions for reads and reject for writes
file | packages/dartclaw_server/lib/src/api/config_routes.dart#configRoutes | Existing shared run endpoint and immediate started/conflict/not-found outcomes
file | packages/dartclaw_core/lib/src/storage/kv_service.dart#KvService | Existing file-backed atomic JSON persistence for the single bounded curation lifecycle record
file | apps/dartclaw_cli/lib/src/commands/wiring/scheduling_wiring.dart#SchedulingWiring.wire | Composition root for built-in jobs, heartbeat, and the obsolete automatic consolidator couplings removed by S05
file | packages/dartclaw_server/lib/src/knowledge/knowledge_inbox_service.dart#KnowledgeInboxService._runExtractionTurn | One-turn isolated cron session with read-only/no-tools policy and structured assistant output
file | packages/dartclaw_server/lib/src/knowledge/knowledge_inbox_service.dart#KnowledgeExtraction.fromAssistantText | Delimited structured-output parsing and malformed-payload rejection pattern
file | packages/dartclaw_security/lib/src/task_tool_filter_guard.dart#TaskToolFilterGuard | Established session-local read-only and no-tools enforcement seam
file | packages/dartclaw_server/lib/src/behavior/heartbeat_scheduler.dart#HeartbeatScheduler._runHeartbeat | Heartbeat checklist/sync lifecycle that must have no curation coupling after S05
file | packages/dartclaw_server/lib/src/turn_manager.dart#TurnManager.startTurn | Host-owned execution-capacity, isolated session policy, and terminal `TurnOutcome` lifecycle
```

## Constraints & Gotchas

- **Settled curation bounds**: reuse existing limits rather than add config – S06 renders S02 candidates into the index projection (150 rendered lines and `memory.max_bytes`); from S02's coherent corpus candidates, S09 selects at most 50 priority/recency-selected current personal entries within 64 KiB and at most 50 newest uncurated observations within 64 KiB. Selection reports truncation and never pre-reads omitted content.
- **Settled opaque-legacy boundary**: because S05's closed operations cannot target opaque spans, S09 may include a bounded opaque locator as provenance for a new structured add but never deletes or rewrites the opaque source; broadening that mutation contract requires upstream amendment.
- **Critical – proposal is not authority**: the model supplies only S05-shaped operations and source references. The host supplies owner scope, expected collection revision, identity, validation, persistence, and the final success claim.
- **Critical – one invalid operation rejects all**: parsing may establish structure, but the S05 authority validates the entire proposal against the snapshot and current locked state before any sink; no best-effort operation skipping is allowed.
- **Critical – canonical truth precedes derived state**: a post-commit index failure remains `succeeded` with explicit degraded index state and repair action; pre-commit failure is `failed` with no changed IDs.
- **Avoid – scheduled-job leakage**: system actions share only descriptor reads, run-now routing, and overlap. Do not synthesize a cron/interval/once schedule, call `_executeWithRetry`, deliver a scheduled-job result, expose pause/toggle, or serialize an action into configuration.
- **Critical – reserved action identity**: validate the full registered-action/configured-job ID intersection before publication or mutation. Never choose a winner, silently hide an entry, auto-rename, or preserve a colliding legacy job through compatibility behavior.
- **Avoid – hidden retry or recursion**: use one model turn and zero automatic retries; running overlap, model tool denial, closed operation kinds, and absence of completion hooks jointly prevent self-dispatch.
- **Plan overlap**: S05 TI09 already retires the consolidator class, prompt, exports, CLI construction, heartbeat/schedule dependencies, and dispatch-only tests. S09 must consume that result, add the explicit curation path, and prove threshold, heartbeat, and post-job dispatch remain zero rather than repeat the removal.

## Implementation Plan

### Implementation Tasks

- [ ] **TI01** Each curation run receives one coherent bounded candidate snapshot
  - Consume S02's coherent corpus snapshot/candidate seam and S06's bounded index renderer; include one collection revision, deterministic current personal entries and observations, stable IDs/revisions/provenance, and explicit truncation without opening omitted content. S05 is the later apply authority, not the snapshot source.
  - **Verify**: Boundary and limit-plus-one tests prove S01–S02, including exact index/entry/observation caps, priority/recency selection, coherent revision, unopened omitted sources, and bounded opaque-provenance handling.

- [ ] **TI02** The curation model can emit only one structured proposal
  - Follow `KnowledgeInboxService._runExtractionTurn`: use an isolated cron session, `maxTurns: 1`, read-only plus no-tools policy, preserved base instructions, and delimiter-safe framing; accept exactly one closed proposal and no model-supplied owner/revision/success state.
  - **Verify**: Turn/policy/parser tests prove S01–S02 and S04–S05 across valid output, hostile snapshot text, tool attempts, missing/duplicate/malformed payloads, timeout, failure, and cancellation while asserting the apply authority is untouched on every rejection.

- [ ] **TI03** The host is the sole curation commit authority
  - Submit TI02 operations and TI01's host-held revision through S05's shared service; preserve its whole-set validation, exact changed/no-op accounting, CAS conflict, canonical failure, and committed-but-index-degraded results without a curation-specific writer.
  - **Verify**: Temp-corpus component/fault tests prove S01 and S03–S07 through exact canonical bytes, revisions, deletion audit, index rows, per-operation reasons, current conflict revision, and degraded recovery signal.

- [ ] **TI04** One small ScheduleService system-action seam makes run-now executable and inspectable
  - Add an immutable `SystemAction` descriptor/host callback beside, not inside, `ScheduledJob`. Reserve every registered action ID; reject startup composition and config create/edit proposals whose complete configured-job set intersects it before scheduling, config/restart-pending writes, or publication. Merge collision-free jobs/actions for read-only list/show, resolve both through `ScheduleService.runJobNow` and the shared overlap set, and route the callback around timers, pause/resume, `_executeWithRetry`, delivery, automatic retry, and YAML mutation.
  - Register `memory-curation` through that seam and atomically persist its single bounded `running|succeeded|conflicted|failed` lifecycle/result record through the existing file-backed `KvService` rather than a new store or generic job-history system. Interrupted persisted `running` settles to bounded `failed` recovery state on startup; it never resumes automatically.
  - **Verify**: Schedule, route, persistence-reopen, and assembled API/CLI/Web contract tests prove startup rejects a colliding YAML ID before timers or list/show/run publication; config create and edit reject a reserved ID before YAML/restart-pending changes while preserving the prior live projection; collision-free list/show/run remains merged; and no precedence/compatibility path exists. The same tests prove immutable write rejection, all four exact lifecycle payloads, already-running rejection, interrupted-run settlement, zero timers/reschedule/retry/delivery/YAML writes, and one curation callback per accepted explicit request.

- [ ] **TI05** Explicit run-now remains the only curation dispatch path
  - Consume S05's consolidator removal; retain normal heartbeat checklist/workspace sync and ordinary scheduled-job execution/delivery while adding no threshold, heartbeat, successful-job, apply-result, or curation-completion hook.
  - **Verify**: Assembled-wiring tests prove S07 for over-threshold memory, heartbeat, successful prompt/callback jobs, and recursive model output; a production/current-doc reference scan finds no consolidator class/export/prompt/session key or automatic dispatch wiring.

### Testing Strategy

- [TI01,TI03] Use temp canonical workspaces plus the prerequisite real codec/authority and in-memory derived index. Capture canonical bytes, revision, deletion audit, and index rows before each malformed, invalid, conflict, canonical-failure, and index-failure case.
- [TI02] Reuse the knowledge-inbox fake-turn/parser pattern, but assert curation's stricter single-payload schema and untrusted snapshot framing. Drive timeout/cancellation deterministically through fake outcomes, never wall-clock sleeps.
- [TI03,TI04] Coordinate the concurrent writer and running-overlap cases with `Completer` barriers. Table-drive lifecycle mapping and exact result fields through the service boundary consumed by S11. Use separate startup-YAML, config-create, and config-edit collision fixtures and assert validation occurs before timers, publication, file writes, and restart-pending markers.
- [TI05] Keep behavioral heartbeat/schedule tests as the primary proof; use repository scans only as an absence/fitness backstop and exclude immutable historical/upstream requirement provenance explicitly.

## Implementation Observations

_No observations recorded yet._
