# Scoped Workspace Memory

**Plan**: dev/bundle/docs/specs/0.27/plan.json
**Story-ID**: S02

## Feature Overview and Goal

**Intent**: Give each configured named agent durable memory and maintenance of its own while preserving the owner's knowledge and administrative view behind their existing authorities.

**Expected Outcomes**:

- [OC01] A configured agent's canonical files, daily log, lexical/vector projections, journal, and curation all use its pinned workspace principal and directory.
- [OC02] Ordinary memory and conversation retrieval cannot disclose or mutate another principal's data, including when identity is omitted, forged, stale, or changed indirectly through project/session controls.
- [OC03] An agent explicitly granted `context_research` can receive cited owner knowledge with truthful provenance and audit identity, while missing grants or unavailable sources fail clearly without copying knowledge into agent memory.
- [OC04] Startup, refresh, rebuild, and maintenance keep the owner and configured workspaces independent on SQLite and PostgreSQL, including when one workspace fails or is removed.

## Required Context

- `prd.md#fr2-workspace-memory-and-scoped-knowledge-access` – the canonical corpus, tool, projection, maintenance, context-engine, retention, and failure contract.
- `prd.md#non-functional-requirements` – W3, W4, W5, and the memory/search portion of W6 define the required isolation matrix and unique marker evidence.
- `prd.md#constraints` – prototype scale, existing-authority reuse, both database backends, private-only authoring, and the published-baseline hold.
- `prd.md#assumptions` – operator-managed paths, no automatic transfer, existing context-tool grants, and tested-capability boundaries.
- `prd.md#decisions-log` – D1 requires explicit per-agent workspace configuration; D2-D4, D14, and D15 constrain configured-workspace behavior.
- `plan.json#sharedDecisions` – S01's pinned execution principal, separation from project context, existing authority ownership, and exact `agent:<agent-id>` spelling.
- `plan.json#bindingConstraints` – FR1/FR2 ownership, FR9 retention, and FR10 architecture constraints applicable to the memory surfaces in this story.
- `plan.json#stories.S02` – story scope, W3-W6 coverage, dependency, and the requirement that tools and maintenance share one owner.
- `s01-agent-workspace-execution.md#technical-overview` – consume the exact trusted `{storage principal, workspace directory}` pair pinned to filesystem session ownership; never recalculate it from caller input.

## Deeper Context

- `dev/architecture/data-model.md#derived-memory-index-document` – canonical-memory projection, backend storage, rebuild, and corpus ownership baseline.
- `dev/architecture/data-model.md#derived-conversation-index-row` – chat-facing session projection, source/rebuild contract, and separate conversation corpus.
- `dev/adrs/042-context-research-synthesis-and-citation-model.md#decision` – owner knowledge synthesis, citation resolution, and explicit failure behavior.
- `dev/adrs/050-native-hybrid-search.md#decision` – injected lexical/vector seams, principal-scoped derived storage, synchronization, and graceful vector degradation.
- `dev/adrs/054-model-first-delegation-and-one-authority-per-concern.md#the-carve-out-what-stays-deterministic` – corpus authority, CAS, codec, apply invariants, and scheduling validation remain deterministic.

## Acceptance Scenarios

- **S01 [OC01,OC02] [runtime] Ordinary memory operations stay inside the authenticated workspace**
  - **Given** owner, agent A, and agent B canonical corpora contain distinct markers and two agents have pinned configured-workspace sessions from S01
  - **When** each principal performs memory observe, apply, search, read, recent/count, and source-resolution operations through the ordinary memory surface
  - **Then** canonical files, results, counts, locators, provenance, lexical rows, and vectors contain only that principal's data, and owner data remains unchanged by agent operations

- **S02 [OC02] [runtime] Missing or forged memory identity never becomes owner authority**
  - **Given** a contextual memory call has no authenticated workspace binding, or its arguments, project selection, sender data, or session mutation claim a different principal/path
  - **When** the call reaches read, search, observe, apply, recent/count, or native source resolution
  - **Then** the call is rejected with an actionable scope error before canonical or derived access, and neither `owner` nor another configured workspace is used as a fallback

- **S03 [OC01,OC04] [runtime] Startup and offline rebuild reconcile every configured corpus without reassigning history**
  - **Given** owner plus agent A and agent B have independent canonical markers, one configured corpus may be invalid, and legacy no-vault transcripts exist
  - **When** runtime startup, stopped-file refresh, or `dartclaw rebuild-index` performs preflight and complete lexical/vector reconciliation
  - **Then** each healthy corpus is authenticated and projected under its pinned principal, an affected workspace reports its own failure without substituting another corpus, the owner remains intact, and rebuild never assigns legacy transcripts to a configured agent

- **S04 [OC01,OC04] [runtime] Logs, journal, and curation run independently for configured workspaces**
  - **Given** agent A and agent B are configured for the existing journal/curation schedules and one workspace's input or execution fails
  - **When** their turns append daily logs and the existing scheduler fires journal and curation work
  - **Then** each run reads and writes only its workspace, uses that workspace's bounded snapshot and CAS/apply scope, carries a unique job/run owner, and one failure cannot launch or write through another workspace
  - **And** an unconfigured persona writes no owner log, while a removed/disabled binding launches no new workspace maintenance and does not disturb owner or other-workspace jobs

- **S05 [OC03] [runtime] Explicit context access returns cited owner knowledge without changing ownership**
  - **Given** a configured agent's existing tool grant explicitly allows `context_research` and owner wiki, KG, memory, and inbox sources contain identifiable records
  - **When** the agent requests owner knowledge through that context-engine tool
  - **Then** retrieval stays on the owner knowledge sources, the citation packet retains owner source scope/provenance plus trusted agent/session audit identity, and no retrieved record is copied into the agent corpus automatically

- **S06 [OC03] [runtime] Context access failures remain explicit and content-free**
  - **Given** the agent lacks or has lost the `context_research` grant, a cited source is stale, or the context service/layer is unavailable
  - **When** the agent requests or resolves owner knowledge
  - **Then** policy denial, stale-source omission, or layer/service unavailability is reported through the existing context-engine contract without ordinary-memory owner fallback, fabricated citations, cross-workspace disclosure, or automatic copy

- **S07 [OC02,OC04] [runtime] Conversation memory/search follows pinned session ownership across lifecycle changes**
  - **Given** owner, configured-agent, legacy no-vault, and retention-ineligible conversations have unique message markers, with the last supplied through the consumer seam S08 later uses for temporary conversations
  - **When** append indexing or rebuild runs before and after project changes, an explicit eligible fork, a queued restart, binding removal, and retention exclusion
  - **Then** configured conversations remain under their pinned agent principal, owner/admin inspection keeps authorized cross-workspace visibility, agent tools cannot acquire that visibility, legacy transcripts remain admin-only and unassigned, and ineligible content leaves no daily-log, canonical-memory, lexical, or vector record

## Structural Criteria

- **SC01 [runtime]** SQLite FTS/vector and PostgreSQL FTS/pgvector enforce equivalent principal and corpus isolation for memory and conversation operations; real backend tests prove the PostgreSQL claim.
- **SC02** `MemoryCorpusService`, `MemoryApplyService`, existing search ports, and the existing scheduler remain the single authorities; no second store, index, scheduler, curation run ledger, workspace registry, client/account model, or document ACL is introduced.
- **SC03 [runtime]** Existing owner memory, wiki, KG, inbox, search ranking, provenance, audit, startup, and rebuild behavior remains correct and owner-scoped.
- **SC04 [runtime]** Configuration reload/removal performs no automatic data move, reassignment, copy, or deletion, and creates no per-workspace heartbeat, git-sync, or self-improvement fanout.

## Scope & Boundaries

### Work Areas

- Canonical corpus/file services, startup preflight, health, refresh, and post-commit projection composition
- Ordinary memory MCP tools, authenticated caller context, canonical/native source resolution, and audit provenance
- Memory and conversation lexical/vector principal selection for SQLite and PostgreSQL
- Conversation append indexing, complete rebuild, administrative inspection, and retention eligibility
- Turn daily-log selection plus journal/curation corpus, CAS/apply, job, session, and removal lifecycle
- Offline `rebuild-index` coverage for owner and configured workspace sources
- W3/W4/W5 and memory-W6 runtime fixtures with unique owner/agent/legacy markers and real PostgreSQL coverage

### What We're NOT Doing

- Assigning a workspace when the configuration key is absent or moving data automatically – absent keys preserve no-workspace behavior; this FIS applies only after S01 supplies an explicitly resolved configured binding.
- Retargeting `context_research` to the agent corpus – its purpose here is explicitly granted, read-only owner knowledge; ordinary memory tools provide workspace-local memory.
- Adding document-level ACLs, per-agent MCP client accounts/tokens, a workspace lifecycle registry, or another search/ranking service – existing tool policy, caller identity, configuration, and search seams own those concerns.
- Moving, copying, deleting, or reassigning existing owner, agent, or legacy data on configuration change or rebuild – all such transfer requires a separate explicit operation.
- Fanout of heartbeat, workspace git sync, or self-improvement jobs – FR2 limits new per-workspace scheduling to memory journal/curation behavior.

## Architecture Decision

**Approach**: Consume S01's pinned `{storage principal, workspace directory}` as one trusted memory context. Compose the existing corpus/file/search/apply services per configured directory while sharing the selected backend's principal-keyed lexical/vector tables, and pass that same context through tools, conversations, rebuild, and memory jobs. Keep `context_research` on owner sources behind the existing explicit tool grant.
**Why this over alternatives**: It extends each current authority and makes files plus derived rows agree, without a parallel workspace platform or an index-only filter that leaves canonical files shared.

## Technical Overview

The owner keeps the existing `owner` context. Each configured agent receives the exact `agent:<agent-id>` and canonical directory resolved and pinned by S01. Runtime memory composition selects corpus, file, health, lexical/vector, and apply services from that pair; no consumer derives identity from a path, project, sender, browser state, or tool argument.

SQLite and PostgreSQL retain their current memory/conversation tables and `user_id` isolation. Startup and offline rebuild enumerate only the owner plus current configured bindings, authenticate each canonical corpus, and project rows/vectors under its principal. Legacy session sources remain in their admin-only owner projection and are never inferred into a workspace. A failed configured corpus is unavailable by name; it does not poison or replace another context.

Ordinary memory tools become contextual end to end. Journal, curation, and daily logs receive the same trusted pair, with unique existing-scheduler identities and per-workspace apply/run scope. `context_research` remains a distinct read-only owner-knowledge path: existing tool authorization decides reachability, existing citation/source owners decide truth, and the authenticated caller supplies audit attribution rather than changing the retrieval corpus.

## Code Patterns & External References

```text
# type | path#anchor | why needed (intent)
file | packages/dartclaw_core/lib/src/memory/memory_corpus_service.dart#MemoryCorpusService | Keep one canonical file authority and directory-keyed CAS/commit lifecycle
file | packages/dartclaw_core/lib/src/memory/memory_file_service.dart#MemoryFileService.appendDailyLog | Reuse canonical daily-log writes for the selected workspace corpus
file | packages/dartclaw_core/lib/src/search/sqlite_fts_index.dart#SqliteFtsIndex | Preserve existing lexical user/corpus isolation on SQLite
file | packages/dartclaw_core/lib/src/search/postgres_fts_index.dart#PostgresFtsIndex | Preserve equivalent lexical user/corpus isolation on PostgreSQL
file | packages/dartclaw_core/lib/src/search/vector_index.dart#SqliteVectorIndex | Preserve principal-scoped SQLite vectors; reconcile the advanced checkout before implementation
file | packages/dartclaw_core/lib/src/search/vector_index.dart#PostgresVectorIndex | Preserve equivalent pgvector scope and transactional replacement
file | packages/dartclaw_core/lib/src/search/conversation_indexer.dart#ConversationIndexer | Change append/delete projection ownership from one injected owner to pinned session ownership
file | packages/dartclaw_core/lib/src/search/conversation_index_projection.dart#ConversationIndexProjection.rebuild | Rebuild chat-facing messages under authoritative session ownership and exclusions
file | packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart#StorageWiring._wirePersonalMemoryBeforeTaskStorage | Extend startup preflight/recovery without adding another storage composition root
file | packages/dartclaw_runtime/lib/src/memory_handlers.dart#createMemoryHandlers | Bind canonical files, search/read/recent/count/source resolution, observe, and apply to one context
file | packages/dartclaw_runtime/lib/src/mcp/mcp_server.dart#McpCallerContext | Reuse transport-authenticated agent/session identity; never accept caller scope in tool arguments
file | packages/dartclaw_runtime/lib/src/mcp/memory_tools.dart#MemorySearchTool | Make ordinary retrieval contextual like existing observe/apply tools
file | packages/dartclaw_runtime/lib/src/mcp/context_research_tool.dart#ContextResearchTool._retrieveMemory | Preserve owner knowledge retrieval and citation behavior rather than retargeting it
file | packages/dartclaw_runtime/lib/src/turn_runner_memory.dart#_TurnRunnerMemory._appendDailyLog | Select the pinned configured workspace and retain the unconfigured-persona exclusion
file | packages/dartclaw_runtime/lib/src/memory/memory_apply_service.dart#MemoryApplyService.apply | Preserve deterministic CAS, closed operations, audit, and bounded run scope per corpus
file | packages/dartclaw_runtime/lib/src/memory/memory_curation_job.dart#buildMemoryCurationJob | Reuse bounded snapshot plus apply-scope curation for each configured workspace
file | packages/dartclaw_runtime/lib/src/runtime/scheduling_wiring.dart#SchedulingWiring.wire | Register unique workspace journal/curation jobs in the existing scheduler only
file | apps/dartclaw_cli/lib/src/commands/rebuild_index_command.dart#RebuildIndexCommand.run | Extend stopped-runtime rebuild across explicit principals and both selected backends
file | dev/fitness/test/memory_architecture_test.dart#memory architecture scanners | Keep curation behind apply/CAS and avoid a durable curation lifecycle subsystem
```

These are public-repository-root paths at execution. During private authoring, they were inspected read-only at public commit `0e605a2038b79c4e8d3164297506eff9a76f8fb4`. The shared checkout has advanced in `vector_index.dart`; execution must reconcile that file and all S01-produced surfaces against the published 0.26.1 tree before editing.

## Constraints & Gotchas

- **Constraint**: D1 requires explicit per-agent workspace configuration. An absent workspace key preserves no-workspace behavior; no workspace, principal, or corpus is assigned automatically, and an unconfigured persona cannot write owner memory/logs implicitly.
- **Critical**: The trusted memory context is exactly S01's pinned pair. A user-controlled identity parameter, current config lookup for an existing session, project/cwd, sender, provider, or browser selection cannot replace either member.
- **Critical**: Scoping only `user_id` is insufficient. Canonical files, health/manifests, post-commit projection, native resolution, jobs, and derived rows must all use the same principal and directory.
- **Constraint**: Owner wiki/KG/inbox and `context_research` retrieval remain owner-owned. Contextualizing the call adds trusted audit attribution and policy enforcement; it must not redirect those sources to the agent workspace.
- **Constraint**: Curation still writes only through `MemoryApplyService.apply`, keeps bounded input and CAS/run scope, and creates no durable curation lifecycle record. Scheduling uses existing cadence and cost/concurrency authorities.
- **Constraint**: PostgreSQL evidence uses a real provisioned PostgreSQL/pgvector backend. Fakes or SQL-shape inspection cannot establish SC01.
- **Constraint**: S02 completes the memory/log/index consumer behavior for a retention-ineligible source; S08 later supplies temporary-conversation classification through that seam, so S02 neither implements temporary mode nor waits on it.
- **Constraint**: Project, fork, and queued-restart coverage varies persisted session ownership/source metadata at the indexing boundary. It does not depend on S04/S05 UI; S09 owns only the joined journey evidence, not behavior deferred from this FIS.
- **Avoid**: Reusing one global handler/corpus and changing only its index argument. That can pass lexical tests while reading or writing the wrong canonical files.

## Implementation Plan

### Implementation Tasks

- **TI01** Configured workspace memory contexts are independently ready at runtime startup
  - Extend `StorageWiring` around its existing preflight/health/projection owners so each S01 pair selects one canonical corpus/file context; invalid configured corpus state is reported for that binding without owner/other-workspace fallback.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/storage_wiring_memory_preflight_test.dart packages/dartclaw_runtime/test/runtime/workspace_memory_wiring_test.dart` – planned/unexecuted at spec time; proves owner/A/B directory-principal agreement, stopped-file refresh, independent health, and isolated startup failure
  - **SATISFIES**: S03, SC02, SC03

- **TI02** Ordinary memory tools use authenticated workspace context for every operation
  - Carry `McpCallerContext` through search/read as already done for observe/apply, select the matching corpus plus principal in `createMemoryHandlers`, and reject missing/mismatched context before search, recent/count, canonical/native resolution, capture, or CAS apply.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/memory_handlers_test.dart packages/dartclaw_runtime/test/mcp/memory_tools_test.dart packages/dartclaw_runtime/test/mcp/mcp_server_test.dart` – planned/unexecuted at spec time; proves all ordinary operations, source resolution, omitted context, forged arguments, no owner fallback, and truthful provenance/audit
  - **SATISFIES**: S01, S02, SC02, SC03

- **TI03** Lexical and vector operations preserve workspace principal and corpus on SQLite
  - Feed the selected principal through post-commit projection, hybrid retrieval, synchronize/rebuild, fetch/recent/count, and conversation rows while retaining the existing FTS/vector implementations and ranking.
  - **Verify**: `cmd: dart test --run-skipped --reporter=failures-only packages/dartclaw_core/test/search/sqlite_fts_index_test.dart packages/dartclaw_core/test/search/sqlite_vector_index_test.dart packages/dartclaw_runtime/test/runtime/storage_wiring_memory_hybrid_lifecycle_test.dart packages/dartclaw_runtime/test/integration/workspace_memory_isolation_integration_test.dart` – planned/unexecuted at spec time; proves owner/A/B same-ID isolation, full operation coverage, lexical/vector synchronization, source identity, and owner ranking parity
  - **SATISFIES**: S01, S02, S03, S07, SC01, SC03

- **TI04** PostgreSQL enforces the same workspace memory and conversation contract
  - Reuse `PostgresFtsIndex`/`PostgresVectorIndex` through the same runtime principal path as SQLite; cover startup, incremental projection, full rebuild, retrieval, mutation, failure, and corpus separation against a real backend.
  - **Verify**: `cmd: dart test --reporter=failures-only --run-skipped -t integration packages/dartclaw_core/test/search/postgres_fts_index_live_test.dart packages/dartclaw_core/test/search/postgres_vector_index_live_test.dart packages/dartclaw_runtime/test/integration/workspace_memory_postgres_live_test.dart` – planned/unexecuted at spec time; with `DARTCLAW_TEST_POSTGRES_URL` and pgvector provisioned, proves behavioral parity and zero owner/A/B marker leakage on real PostgreSQL
  - **SATISFIES**: S01, S03, S07, SC01, SC03

- **TI05** Conversation indexing and rebuild follow pinned session ownership and retention eligibility
  - Resolve each append/delete/rebuild row from filesystem session ownership, keep authorized admin aggregation separate from agent-scoped search, retain legacy no-vault rows as admin-only, and consume a retention-eligibility seam that omits ineligible sources without defining S08's temporary mode.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/search/conversation_index_projection_test.dart packages/dartclaw_core/test/search/conversation_indexer_test.dart packages/dartclaw_runtime/test/runtime/storage_wiring_conversation_index_test.dart packages/dartclaw_runtime/test/session/session_lifecycle_conversation_index_test.dart` – planned/unexecuted at spec time; proves append/rebuild identity across project/fork/restart/removal, admin-versus-agent visibility, legacy non-assignment, and durable exclusion
  - **SATISFIES**: S03, S07, SC01, SC03, SC04

- **TI06** Offline rebuild reconciles owner and configured workspaces without moving data
  - Extend `RebuildIndexCommand.run` to enumerate only explicit owner/configured source pairs, authenticate each corpus, rebuild memory/conversation lexical and vector rows under its principal, report per-workspace failures, and never infer legacy ownership.
  - **Verify**: `cmd: dart test --reporter=failures-only apps/dartclaw_cli/test/commands/rebuild_index_command_test.dart apps/dartclaw_cli/test/commands/rebuild_index_conversation_test.dart` – planned/unexecuted at spec time; proves SQLite rebuild isolation, stable owner data, legacy non-assignment, JSON/human diagnostics, and failure preservation
  - **SATISFIES**: S03, S07, SC01, SC03, SC04

- **TI07** PostgreSQL offline rebuild preserves the same workspace boundaries
  - Exercise TI06's enumeration against the real PostgreSQL FTS/pgvector stores, including one failed workspace, complete conversation projection, and unchanged owner/legacy sources.
  - **Verify**: `cmd: dart test --reporter=failures-only --run-skipped -t integration apps/dartclaw_cli/test/commands/rebuild_index_command_postgres_live_test.dart` – planned/unexecuted at spec time; with `DARTCLAW_TEST_POSTGRES_URL` and pgvector provisioned, proves principal-scoped rebuild publication and failure preservation on the real backend
  - **SATISFIES**: S03, S07, SC01, SC03, SC04

- **TI08** Daily logs use the pinned configured workspace or stay unwritten
  - Select `MemoryFileService` in `_appendDailyLog` from S01 session ownership; configured agent turns append only their corpus, owner stays owner, unconfigured personas remain excluded, and retention-ineligible turns write nothing.
  - **Verify**: `cmd: dart test --run-skipped --reporter=failures-only packages/dartclaw_runtime/test/turn_prompt_memory_test.dart packages/dartclaw_runtime/test/runtime/service_wiring_mcp_scope_test.dart packages/dartclaw_runtime/test/integration/workspace_memory_isolation_integration_test.dart` – planned/unexecuted at spec time; proves owner/A/B log markers, unconfigured exclusion, project/restart stability, retention exclusion, and no write on missing/stale binding
  - **SATISFIES**: S04, S07, SC03, SC04

- **TI09** Journal and curation jobs retain independent workspace execution and CAS scope
  - Register uniquely owned existing-scheduler jobs only for active configured bindings; each consumes that pair's corpus and `MemoryApplyService`, preserves bounded snapshot/run scope and current schedules/cost limits, and stops future launches after removal without affecting admitted or sibling work.
  - **Verify**: `cmd: dart test --run-skipped --reporter=failures-only packages/dartclaw_runtime/test/behavior/memory_journal_test.dart packages/dartclaw_runtime/test/memory/memory_curation_job_test.dart packages/dartclaw_runtime/test/runtime/scheduling_wiring_test.dart packages/dartclaw_runtime/test/runtime/scheduling_live_wiring_test.dart packages/dartclaw_runtime/test/runtime/service_wiring_mcp_scope_test.dart packages/dartclaw_runtime/test/integration/workspace_memory_isolation_integration_test.dart` – planned/unexecuted at spec time; proves two-workspace inputs/outputs, job/run uniqueness, CAS scope, failure isolation, removal, admitted-run handling, and zero heartbeat/git-sync fanout
  - **SATISFIES**: S04, SC02, SC03, SC04

- **TI10** Explicit context-engine grants preserve owner knowledge, provenance, and denial boundaries
  - Keep `ContextResearchTool` retrieval on owner memory/wiki/KG/inbox, rely on the existing tool policy for reachability, and retain trusted agent/session audit attribution, citation resolution, layer degradation, and read-only/no-copy behavior.
  - **Verify**: `cmd: dart test --run-skipped --reporter=failures-only packages/dartclaw_runtime/test/mcp/context_research_tool_test.dart packages/dartclaw_runtime/test/mcp/mcp_server_test.dart packages/dartclaw_runtime/test/runtime/service_wiring_mcp_scope_test.dart packages/dartclaw_runtime/test/integration/workspace_memory_isolation_integration_test.dart` – planned/unexecuted at spec time; proves explicit grant, revoked/missing grant, owner-layer provenance, trusted audit principal, stale/unavailable source handling, and absence of agent-corpus writes
  - **SATISFIES**: S05, S06, SC02, SC03

### Testing Strategy

- Use unique owner, agent A, agent B, legacy, and retention-ineligible markers. Every isolation assertion enumerates both allowed and forbidden sets so a globally empty result cannot pass.
- Unit/contract tests exercise canonical files, context propagation, CAS, scheduling, SQLite FTS/vector, and rebuild routing. The two future workspace integration files drive the real runtime composition boundary; all `cmd:` targets are exec-time planned/unexecuted checks and no nonexistent test was treated as a spec-time behavioral red.
- PostgreSQL/pgvector parity is established only by TI04 and TI07's live integration commands with `DARTCLAW_TEST_POSTGRES_URL`; ordinary SQLite tests and fake backends remain supporting evidence.
- S02 tests the retention consumer with an injected ineligible source. S08 later binds its temporary-conversation classification to that seam; S09's joined journey cannot substitute for these memory assertions.

### Execution Contract

- Do not implement or export until S01 produces its pinned context contract and 0.26.1 is published. At execution start, reconcile every touched symbol against the release tree, especially the advanced `vector_index.dart`, before editing.
- TI01 establishes workspace service selection. TI02-TI05 consume it for tools/projections. TI06-TI07 extend offline rebuild, TI08-TI09 extend memory maintenance, and TI10 validates the deliberately separate owner-knowledge path. Run real backend integration after all consumers are wired.

## Implementation Observations

### Run: 2026-09-14 11:50 UTC – repair-proof

#### DRIFT

- spec-stale: TI03 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/search/sqlite_fts_index_test.dart packages/dartclaw_core/test/search/sqlite_vector_index_test.dart packages/dartclaw_runtime/test/runtime/storage_wiring_memory_hybrid_lifecycle_test.dart packages/dartclaw_runtime/test/integration/workspace_memory_isolation_integration_test.dart` → `cmd: dart test --run-skipped --reporter=failures-only packages/dartclaw_core/test/search/sqlite_fts_index_test.dart packages/dartclaw_core/test/search/sqlite_vector_index_test.dart packages/dartclaw_runtime/test/runtime/storage_wiring_memory_hybrid_lifecycle_test.dart packages/dartclaw_runtime/test/integration/workspace_memory_isolation_integration_test.dart`

### Run: 2026-09-14 11:50 UTC – repair-proof

#### DRIFT

- spec-stale: TI08 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/turn_prompt_memory_test.dart packages/dartclaw_runtime/test/integration/workspace_memory_isolation_integration_test.dart` → `cmd: dart test --run-skipped --reporter=failures-only packages/dartclaw_runtime/test/turn_prompt_memory_test.dart packages/dartclaw_runtime/test/integration/workspace_memory_isolation_integration_test.dart`

### Run: 2026-09-14 11:50 UTC – repair-proof

#### DRIFT

- spec-stale: TI09 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/behavior/memory_journal_test.dart packages/dartclaw_runtime/test/memory/memory_curation_job_test.dart packages/dartclaw_runtime/test/runtime/scheduling_wiring_test.dart packages/dartclaw_runtime/test/runtime/scheduling_live_wiring_test.dart packages/dartclaw_runtime/test/integration/workspace_memory_isolation_integration_test.dart` → `cmd: dart test --run-skipped --reporter=failures-only packages/dartclaw_runtime/test/behavior/memory_journal_test.dart packages/dartclaw_runtime/test/memory/memory_curation_job_test.dart packages/dartclaw_runtime/test/runtime/scheduling_wiring_test.dart packages/dartclaw_runtime/test/runtime/scheduling_live_wiring_test.dart packages/dartclaw_runtime/test/integration/workspace_memory_isolation_integration_test.dart`

### Run: 2026-09-14 11:50 UTC – repair-proof

#### DRIFT

- spec-stale: TI10 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/mcp/context_research_tool_test.dart packages/dartclaw_runtime/test/mcp/mcp_server_test.dart packages/dartclaw_runtime/test/runtime/service_wiring_mcp_scope_test.dart packages/dartclaw_runtime/test/integration/workspace_memory_isolation_integration_test.dart` → `cmd: dart test --run-skipped --reporter=failures-only packages/dartclaw_runtime/test/mcp/context_research_tool_test.dart packages/dartclaw_runtime/test/mcp/mcp_server_test.dart packages/dartclaw_runtime/test/runtime/service_wiring_mcp_scope_test.dart packages/dartclaw_runtime/test/integration/workspace_memory_isolation_integration_test.dart`

### Run: 2026-09-14 18:26 CEST – execution

#### OBSERVATION

- Reconciled the story against S01's current `AgentWorkspace` session snapshot: consumers use its exact `storagePrincipal` and canonical directory, and stale or mismatched session bindings fail without owner fallback.
- Preserved S03's `ConversationState.includesMessage` as the single visibility decision for append and rebuild. Administrative aggregation includes persisted removed-workspace principals without granting that aggregation to agent memory tools.

#### DRIFT

- implementation-baseline: Claude's direct SDK MCP seam carried trusted turn context only for `memory_apply` and `memory_observe`; `memory_search` and `memory_read` still selected global owner callbacks. The existing `ContextualMemoryToolHandler` contract now covers all four ordinary memory operations, matching the already-contextual HTTP bridge without adding a second dispatcher.

### Run: 2026-09-14 18:44 CEST – review-repair

#### OBSERVATION

- The joined runtime composition fixture now executes an agent-owned `TurnRunner` turn, fires its registered workspace
  journal through `ScheduleService`, invokes granted `context_research`, verifies caller audit identity and owner
  provenance, and proves the research call copies nothing into the agent corpus.

#### DRIFT

- proof-incomplete: TI08 and TI09 now include the runtime composition fixture; the original joined commands coupled
  component tests to a storage-only integration fixture and did not make the composition boundary load-bearing.
