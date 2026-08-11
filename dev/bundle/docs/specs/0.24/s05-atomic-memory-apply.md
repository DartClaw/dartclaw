# Feature Implementation Specification: Atomic Memory Apply

**Plan**: dev/bundle/docs/specs/0.24/plan.json
**Story-ID**: S05

## Feature Overview and Goal

**Intent**: Let models curate personal memory without stale or partial writes, ambiguous success, or an append-only escape hatch that bypasses the canonical corpus contract.

**Expected Outcomes**:

- [OC01] One compare-and-swap request applies a wholly valid mix of add, revise, merge, and remove operations atomically and reports the exact changed and exact-no-op entry IDs.
- [OC02] Stale, malformed, cross-store, oversized, or otherwise invalid change sets expose actionable operation-level reasons and leave canonical memory, revision, deletion audit, and derived index unchanged.
- [OC03] Callers can distinguish canonical commit success from derived-index degradation, and forgetting removes content while retaining only content-free audit metadata.
- [OC04] Every model-facing and production surface uses the role-appropriate 0.24 memory contract, with `memory_apply` confined to personal memory and `memory_save` retired.

## Required Context

- `dev/bundle/docs/specs/0.24/plan.json#stories.4` – exact S05 scope, P2/W5 ordering, S04 dependency, high-risk classification, and the requirement to keep all operation kinds in one atomic specification.
- `dev/bundle/docs/specs/0.24/prd.md#fr2-guarded-memory-tools` – closed apply operation set, shared mutation authority, CAS conflict, personal `userId` scope, validation-before-write, removal, provider policy, and legacy-tool retirement contracts.
- `dev/bundle/docs/specs/0.24/prd.md#fr3-on-demand-semantic-curation` – all-or-nothing proposal handling, changed/no-op reporting, shared apply authority, and the prohibition on automatic curation.
- `dev/bundle/docs/specs/0.24/prd.md#fr5-retrieval-citation-and-index-integrity` – separate canonical/index outcomes, stable personal-memory identity, truthful degradation, and rebuildable derived search.
- `dev/bundle/docs/specs/0.24/prd.md#user-flows` – remembering, explicit curation, conflict, and index-failure journeys this story must enable.
- `dev/bundle/docs/specs/0.24/prd.md#fr1-coherent-memory-corpus` – binding rule that canonical content never exists only in the derived database.
- `dev/bundle/docs/specs/0.24/prd.md#fr8-simplification-and-release-boundaries` – no new package, database, daemon, scheduler, approval abstraction, wiki/KG mutation, or QMD responsibility.
- `dev/bundle/docs/specs/0.24/prd.md#constraints` – trusted host boundary, untrusted model/tool content, single-isolate runtime, canonical Markdown, and existing shared-lock/atomic-write constraints.
- `dev/adrs/002-file-based-storage.md#decision` – canonical files remain authoritative and `search.db` remains derived and rebuildable.
- `dev/architecture/security-architecture.md#canonical-tool-taxonomy` – exact own-MCP semantic mapping and provider interception behavior that renamed tools must preserve.
- `dev/architecture/security-architecture.md#toolpolicyguard` – canonical allow/deny behavior and the rule that semantic own-MCP tools never gain access through generic `mcp_call`.
- `dev/architecture/data-model.md#memory-chunk-search-index` – current derived-index ownership, source identity, owner scope, and rebuild relationship.
- `dev/architecture/data-model.md#write-safety` – existing canonical memory queue, workspace lock, and atomic-write discipline.

## Acceptance Scenarios

- [ ] **S01 [OC01] [TI03,TI05,TI06] A mixed valid personal-memory change set commits once with exact changed and no-op IDs**
  - **Given** collection revision 41, active personal entries A–E with current entry revisions, and a healthy derived index
  - **When** one `memory_apply` request at revision 41 adds a new preference, revises A, merges B and C while retaining B's identity, removes D, and submits an exact unchanged replacement for E
  - **Then** one canonical commit advances the collection to revision 42, the response associates the host-generated add ID and A/B/C/D with changed operations, associates only E with an exact no-op, and every operation is reflected together in canonical reads

- [ ] **S02 [OC01,OC03] [TI03,TI05,TI06] A wholly exact-no-op request does not fabricate a write**
  - **Given** collection revision 42 and personal entry E whose complete canonical payload and state already equal a proposed revision
  - **When** `memory_apply` submits only that exact unchanged revision at collection revision 42
  - **Then** it returns no changed IDs and exactly E as no-op, keeps collection and entry revisions at 42 and their current value, and performs no canonical, deletion-audit, or index write

- [ ] **S03 [OC02,OC04] [TI01,TI02,TI06] One invalid operation rejects the whole change set with operation-level reasons**
  - **Given** a byte-for-byte snapshot of canonical memory, collection revision, deletion audit, and index rows
  - **When** a current-revision request combines a structurally valid add with a merge that repeats a target, a revision missing required provenance, and a remove aimed at a wiki, KG, observation, or learning locator
  - **Then** every operation receives either its precise validation reason or a not-applied-because-change-set-rejected reason, changed and no-op ID lists are empty, and every captured canonical/index/audit value remains byte-for-byte unchanged
  - **Proof**: `packages/dartclaw_core/test/memory/memory_file_service_test.dart#allows the exact byte limit and rejects repeated crossing appends without changing the file` – green – parity/regression

- [ ] **S04 [OC02] [TI02,TI03] Concurrent callers cannot both win the same collection revision**
  - **Given** two valid change sets built from collection revision 51 and released concurrently against the shared workspace mutation authority
  - **When** one request commits first
  - **Then** exactly one commit advances the collection once, while the other returns a typed conflict with the current revision and has no canonical, index, or audit effect
  - **Proof**: `packages/dartclaw_core/test/memory/memory_file_service_test.dart#workspace write lock blocks append until maintenance releases it` – green – parity/regression

- [ ] **S05 [OC03] [TI03,TI05,TI06] Post-commit index failure reports durable canonical success as degraded**
  - **Given** a valid current-revision change set and an injected derived-index failure after the canonical atomic replacement succeeds
  - **When** `memory_apply` commits the change set
  - **Then** its typed result exposes the new collection revision and exact changed/no-op IDs, reports canonical committed plus bounded index-reconciliation degradation facts and a recovery signal, and keeps the canonical change durable
  - **And** S05 neither stores nor clears health; S08 consumes those facts, persists degraded health, and clears it only after complete validated reconciliation
  - **Proof**: `packages/dartclaw_storage/test/memory/memory_pruner_test.dart#index failure leaves source retryable and retry creates one archive index row` – green – parity/regression

- [ ] **S06 [OC03,OC04] [TI03,TI04,TI05] Forgetting leaves only content-free metadata**
  - **Given** active personal entry D contains the unique sentinel `REMOVE-ME-9f8c`, has indexed rows, and is referenced by no other entry
  - **When** a valid remove operation commits with D's entry revision, actor/source, and nonblank reason
  - **Then** D and the sentinel are absent from active/archive canonical content, derived rows, tool output, deletion audit, and runtime audit/log output; the deletion audit retains only D's ID, time, actor/source, and reason

- [ ] **S07 [OC04] [TI06,TI07,TI08,TI09,TI10,TI11] The coherent tool contract is the only live and documented memory-write path**
  - **Given** endpoint-backed and direct-SDK provider modes, built-in jobs, producer prompts, tool discovery, policy allowlists, recipes, and current reference documentation
  - **When** DartClaw starts and each surface is inspected or exercised
  - **Then** `memory_apply` and `memory_observe` map exactly to persistent-memory write policy, `memory_search` and `memory_read` remain read-only, role-specific producers use the correct tool, threshold consolidation cannot dispatch, and no own-MCP `memory_save` tool, alias, callback, schema, policy identity, prompt, recipe, or current-document instruction remains
  - **Proof**: `packages/dartclaw_core/test/harness/claude_tool_mapping_test.dart` – green – parity/regression
  - **Proof**: `packages/dartclaw_core/test/harness/codex_approval_flow_test.dart#maps exact own-MCP approval identities and keeps unknown MCP calls generic` – green – parity/regression
  - **Proof**: `apps/dartclaw_cli/test/commands/service_wiring_local_path_bootstrap_test.dart` – green – parity/regression

## Structural Criteria

- [ ] One host-owned mutation authority performs validation, collection CAS, canonical staging/replacement, revision advancement, deletion auditing, and post-commit index reconciliation under the existing shared workspace lock.
- [ ] S05 returns typed canonical/index reconciliation facts only; S08 is the sole owner of persistent index-health state, recovery transitions, last reconciliation, and health clearing.
- [ ] The MCP schema exposes no caller-selected user/store/role escape hatch; the host binds the existing owner scope, and wiki/KG, observation, and learning write contracts remain unchanged.
- [ ] Production Dart, tool discovery, provider maps, exports, prompts, allowlists, current architecture/reference docs, and user guides contain no legacy save contract; only explicit negative tests and immutable historical/upstream provenance may name it.
- [ ] The change introduces no package, database, daemon, scheduler, approval framework, autonomous curation loop, QMD responsibility, or wiki/KG mutation path.

## Scope & Boundaries

### Work Areas

- Canonical personal-memory validation, mutation, revision, and deletion-audit authority
- Derived-index reconciliation and typed apply outcome facts for S08
- MCP handlers, schemas, exports, discovery, and direct-SDK tools
- Claude/Codex canonical mappings, guard policy identity, and CLI/server wiring
- Memory-producing prompts/jobs and obsolete consolidation dispatch
- Component/security/wiring tests plus behavior-local tool, prompt, recipe, and reference documentation

### What We're NOT Doing

- Designing `memory_observe`, `memory_search`, or `memory_read` behavior – S04 owns those contracts; this story only consumes them for migration and policy parity.
- Building the explicit curation operator or prompt workflow – later plan stories consume this apply authority; 0.24 adds no autonomous curation.
- Mutating wiki, KG, raw observations, or bounded learnings through `memory_apply` – their existing guarded contracts remain separate.
- Changing QMD, adding database/hybrid/vector search, or broadening rebuild/recovery architecture – those remain later-story/milestone work.
- Persisting, clearing, or presenting index health – S08 owns durable health/recovery and S11 owns operator presentation; S05 reports only the facts produced by this apply attempt.
- Performing the residual cross-document governance audit, ADR lineage reconciliation, or roadmap/release handoff – S12 owns that final pass after all behavior stories land.
- Rewriting historical changelog entries or upstream 0.24 requirements that name the retired tool as migration provenance – current operational and instructional documentation must still converge.

## Architecture Decision

**Approach**: Reuse the prerequisite canonical corpus service as one host-owned personal-memory CAS authority: validate and stage the entire closed change set under the shared lock, atomically commit canonical Markdown/revision/audit once, then reconcile the derived index and report its outcome separately.
**Why this over alternatives**: Separate mutation tools, compatibility aliases, or index-first writes would fragment atomicity, policy identity, and source-of-truth semantics.

## Technical Overview

`memory_apply` receives one expected collection revision and a bounded nonempty operation list. The host binds owner/personal-memory scope and validates every operation against one locked snapshot before any sink is touched. A valid changed set is staged in memory and atomically replaces canonical state once; the collection revision advances once regardless of changed-operation count. Exact no-ops remain explicit and do not create revisions. Derived-index reconciliation starts only after canonical success, so an index failure returns bounded degradation facts rather than rollback or generic success; S08 converts those facts into persistent health and owns recovery. MCP, direct-SDK, provider-policy, prompt/job, and behavior-local documentation surfaces converge on the same four-tool memory vocabulary, while prerequisite observation/learning capture remains distinct.

## Code Patterns & External References

```text
# type | path#anchor | why needed (intent)
file | packages/dartclaw_core/lib/src/memory/memory_file_service.dart#MemoryFileService | Existing workspace lock, bounded file handling, and atomic canonical-write seam
file | packages/dartclaw_server/lib/src/memory_handlers.dart#createMemoryHandlers | Current handler composition and canonical/index outcome boundary to supersede
file | packages/dartclaw_server/lib/src/mcp/memory_tools.dart#MemorySaveTool | MCP schema/callback pattern and legacy surface to retire
file | packages/dartclaw_core/lib/src/harness/canonical_tool.dart#CanonicalTool | Stable provider-independent policy and audit taxonomy
file | packages/dartclaw_core/lib/src/harness/claude_code_harness.dart#_buildMemorySdkMcpServers | Direct-SDK schema path that must match endpoint-backed tools
file | apps/dartclaw_cli/lib/src/commands/wiring/harness_wiring.dart#HarnessWiring | Registration, exact own-MCP mapping, worker construction, and callback wiring
file | apps/dartclaw_cli/lib/src/commands/wiring/scheduling_wiring.dart#SchedulingWiring | Built-in producer policy and obsolete consolidation wiring
file | packages/dartclaw_server/lib/src/behavior/memory_consolidator.dart#MemoryConsolidator | Threshold-driven append-only curation path to remove completely
```

## Constraints & Gotchas

- **Settled operation shapes**: each operation has a unique caller correlation ID; add supplies complete topic/content/provenance and no canonical ID, revise supplies target ID + expected entry revision + complete replacement state, merge supplies one retained target + at least one distinct source with all entry revisions and complete replacement provenance, and remove supplies target ID + entry revision + actor/source + nonblank reason.
- **Settled snapshot semantics**: every target resolves against the pre-request snapshot; one canonical ID may occur in only one operation (including merge membership). Cross-operation dependencies and duplicate targets reject the whole request instead of introducing order-dependent behavior.
- **Settled identity/no-op semantics**: add always receives a host-generated changed ID; revise is no-op only when its normalized complete state is exactly unchanged; merge and active removal are changes. Merge retains the declared existing target ID and content-free-audits removed source IDs. Missing/inactive targets are invalid, not idempotent no-ops.
- **Settled no-op revision semantics**: a wholly exact-no-op request succeeds without a canonical/index write or revision advance; a mixed valid request advances collection revision once and reports changed/no-op operations separately.
- **Critical – validate before every sink**: unknown kinds/fields, malformed IDs/revisions, missing provenance, invalid personal scope, duplicate/overlapping targets, size/bounds violations, and stale collection/entry revisions must be settled before canonical, audit, or index mutation.
- **Critical – canonical truth precedes derived state**: canonical write/revision failure is wholly rejected; only a failure after canonical commit may return committed-but-index-degraded, and canonical content must never roll back to match a failed index.
- **Avoid – generic MCP fallback**: exact DartClaw mutation tools retain persistent-write policy/audit identity on Claude and Codex; a renamed own-MCP tool may not become `mcp_call`, while unrelated third-party tools remain generic.
- **Removal inventory**: implementation must rescan every `memory_save`, `memorySave`, and `MemorySave` literal/symbol before completion; map each production/current-document hit to the appropriate new contract or delete it, preserving only explicit negative tests and immutable historical/upstream provenance.

## Implementation Plan

### Implementation Tasks

- [ ] **TI01** The apply request contract is closed, bounded, and personal-memory-only
  - Follow `packages/dartclaw_server/lib/src/mcp/memory_tools.dart#MemorySaveTool` for strict schema shape, but enforce the operation assumptions and reject unknown fields, cross-store locators, caller-selected scope, overlap, malformed revisions, missing provenance, and corpus limits before mutation.
  - **Verify**: Focused table tests cover every operation's valid shape plus unknown kind/field, duplicate target, malformed ID/revision, missing provenance, oversized content, and wiki/KG/observation/learning targets.

- [ ] **TI02** Invalid and stale change sets are side-effect free and actionable
  - Reuse `packages/dartclaw_core/lib/src/memory/memory_file_service.dart#MemoryFileService` lock/atomic-write seam; validation and collection/entry CAS must complete against one snapshot before canonical, audit, or index sinks.
  - **Verify**: Component failure-injection tests prove S03 and S04 by comparing canonical bytes, revision, deletion audit, and index rows before/after every rejection while asserting operation-level reasons and current-revision conflict data.

- [ ] **TI03** Wholly valid change sets commit once with exact operation accounting
  - The prerequisite corpus authority must stage add/revise/merge/remove together, preserve the merge target identity, host-generate add identity, advance changed entry revisions and collection revision exactly once, and report changed/no-op operation IDs and canonical entry IDs.
  - **Verify**: Temp-workspace component tests prove S01, S02, and concurrent winner/loser behavior through canonical reads, exact revisions, exact result sets, and absence of intermediate/partial state.

- [ ] **TI04** Retired personal entries leave no content-bearing residue
  - Remove and merge-source retirement use the prerequisite deletion-audit seam; retain only entry ID, time, actor/source, and reason while removing active/archive canonical content and derived rows.
  - **Verify**: A sentinel-based component/security test proves S06 by scanning canonical files, index rows, tool result, deletion audit, and captured runtime audit/log output for the removed content.

- [ ] **TI05** Canonical and derived-index outcomes remain independently truthful
  - Follow the source-of-truth boundary in `dev/adrs/002-file-based-storage.md#key-design-choices`; reconcile only after canonical success and return typed facts that distinguish canonical outcome, index outcome, failing stage, bounded reason, recovery signal, and revision without persisting or clearing health in S05.
  - **Verify**: Failure injection before canonical replacement proves total rejection, while injection after replacement proves S05's durable new revision, exact result IDs, and explicit degradation facts with no S05-owned health write; S08 owns the later persistence/recovery integration proof.

- [ ] **TI06** `memory_apply` is the single model-facing curated-memory mutation contract
  - Wire its strict schema and typed result through `packages/dartclaw_server/lib/src/memory_handlers.dart#createMemoryHandlers`, `packages/dartclaw_server/lib/src/mcp/memory_tools.dart`, MCP exports/discovery, and `packages/dartclaw_core/lib/src/harness/claude_code_harness.dart#_buildMemorySdkMcpServers` without a save alias.
  - **Verify**: MCP schema/compliance and direct-SDK tests exercise all operation shapes, typed conflict/rejection/no-op/applied/index-degraded results, closed additional properties, and absence of `memory_save` discovery.

- [ ] **TI07** Persistent-memory policy identity is exact across supported providers
  - Extend `packages/dartclaw_core/lib/src/harness/canonical_tool.dart#CanonicalTool` and `apps/dartclaw_cli/lib/src/commands/wiring/harness_wiring.dart#HarnessWiring` so apply/observe are writes, search/read are reads, exact own-MCP tools map semantically on Claude/Codex, and third-party calls remain generic.
  - **Verify**: Provider mapping/approval tests prove both endpoint and direct-SDK paths hit the intended canonical guard identity, preserve raw identity for audit, respect deny/allow policy, and never grant a write via `mcp_call`.

- [ ] **TI08** Production memory producers use only their role-appropriate 0.24 write contract
  - Rescan journal, pre-compaction, self-improvement, knowledge-inbox, schedule, and other production callers: observations/learnings use S04's closed observe roles, curated personal writes use CAS apply with a current revision, and sourced wiki/KG knowledge is not copied into personal memory.
  - **Verify**: Producer and assembled-wiring tests prove each job/prompt's exact allowed tools and destination role, including that untrusted journal/inbox content cannot become prompt-authoritative personal memory without a valid apply.

- [ ] **TI09** Threshold-driven append-only consolidation is absent
  - Retire `packages/dartclaw_server/lib/src/behavior/memory_consolidator.dart#MemoryConsolidator` plus exports, heartbeat/schedule dependencies, CLI construction, prompts, and dispatch-only tests; S09 consumes this completed absence and proves that its explicit system action does not restore any automatic path.
  - **Verify**: Scheduling/heartbeat tests and a production-reference scan prove no size threshold can launch a consolidation turn and no orphan constructor/export/prompt remains.

- [ ] **TI10** The legacy memory-save runtime and API surface is absent
  - Remove residual tool classes, callbacks, constants, schemas, provider maps, source labels/locators, status counters, rebuild/pruner assumptions, tests, and package-agent facts across `apps/` and `packages/`, adapting each live consumer to prerequisite canonical roles rather than string-renaming derived identity.
  - **Verify**: Analyzer, barrel/discovery/wiring suites, and a production scan find no `memory_save`, `memorySave`, or `MemorySave` contract while negative tests still prove an unregistered/third-party old spelling cannot gain own-MCP semantics.

- [ ] **TI11** Behavior-local documentation teaches the coherent tool and producer contract
  - Update only documentation directly changed by S05 behavior: affected tool/API references, producer prompts and recipes, provider-policy rows, ADR-007/ADR-016, package guidance, and the current changelog entry must agree on observe/apply routing, CAS/current revision, personal-only mutation, exact outcomes, deletion privacy, and truthful provider limits.
  - **Verify**: Link/fitness checks plus a targeted scan of S05-owned surfaces find no live instruction, example, table, or policy row that advertises the old tool; every affected recipe names the correct role-specific write path. S12 owns the residual cross-document governance audit and release lineage.

- [ ] **TI12** Release, package, and knowledge boundaries remain intact
  - Preserve core's SQLite-free boundary, storage/server/CLI ownership, existing lock/atomic-write primitives, and wiki/KG/QMD contracts; introduce no package, DB, daemon, scheduler, approval framework, or autonomous loop.
  - **Verify**: Architecture/fitness checks pass and the diff contains no new package/database/scheduler/approval surface or wiki/KG mutation reachable from `memory_apply`.

### Testing Strategy

- [TI01] Table-drive the pure operation/schema matrix, including malformed JSON-decoder number shapes, unknown fields, operation overlap, scope/locator rejection, and boundary-sized UTF-8 content.
- [TI02,TI03,TI04,TI05] Use per-test temp workspaces plus in-memory SQLite; capture canonical bytes/revisions/audit/index before calls, coordinate concurrent CAS calls with completers rather than delays, and inject failures immediately before canonical replacement and immediately after canonical success.
- [TI06,TI07] Exercise the MCP handler result rather than private validators, then cover Claude hook and Codex approval mapping through their existing protocol-adapter/wiring suites. Assert both allowed writes and denied/generic false positives.
- [TI08,TI09,TI10,TI11] Keep one assembled CLI wiring proof and focused producer tests; use repository scans only for absence/inventory, never as the sole proof of behavioral routing.

## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Tag semantics: see the AndThen FIS Mutability Contract. Spec authors leave this section empty._

_No observations recorded yet._
