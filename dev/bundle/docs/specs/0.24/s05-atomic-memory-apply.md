# Feature Implementation Specification: Atomic Memory Apply

**Plan**: dev/bundle/docs/specs/0.24/plan.json
**Story-ID**: S05

## Feature Overview and Goal

**Intent**: Let models curate personal memory without stale or partial writes, ambiguous success, or an append-only escape hatch that bypasses the canonical corpus contract.

**Expected Outcomes**:

- [OC01] One compare-and-swap request applies a wholly valid mix of add, revise, merge, and remove operations atomically and reports one typed record per caller-supplied correlation ID carrying that operation's outcome, canonical entry ID, and resulting collection revision.
- [OC02] Stale, malformed, cross-store, oversized, or otherwise invalid change sets expose actionable operation-level reasons and leave canonical memory, revision, deletion audit, and derived index unchanged.
- [OC03] Callers can distinguish canonical commit success from derived-index degradation, and forgetting removes content while the audit retains only host-derived metadata plus the caller's own verbatim reason – the host never copies entry content into the audit.
- [OC04] Every model-facing and production surface uses the role-appropriate 0.24 memory contract, with `memory_apply` confined to personal memory and `memory_save` retired.

## Required Context

- `dev/bundle/docs/specs/0.24/plan.json#stories.4` – exact S05 scope, P2/W5 ordering, S04 dependency, high-risk classification, and the requirement to keep all operation kinds in one atomic specification.
- `dev/bundle/docs/specs/0.24/s01-canonical-memory-model.md#implementation-plan` – the core-owned Markdown codec, corpus validator, and canonical entry identity/revision shapes every apply operation stages and validates against.
- `dev/bundle/docs/specs/0.24/s02-atomic-memory-corpus.md#architecture-decision` – the sole lock/revision/atomic-commit corpus authority this story mutates through; existing writers including `MemoryFileService` are delegating writers under it, never a second mutation path.
- `dev/bundle/docs/specs/0.24/s04-observation-and-retrieval-tools.md#technical-overview` – prerequisite `memory_observe`/`memory_search`/`memory_read` contracts and provider read/write classification this story consumes for parity and retirement.
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

- [x] **S01 [OC01] [TI03,TI05,TI06] A mixed valid personal-memory change set commits once with exact per-operation outcomes**
  - **Given** collection revision 41, active personal entries A–E with current entry revisions, and a healthy derived index
  - **When** one `memory_apply` request at revision 41 adds a new preference, revises A, merges B and C while retaining B's identity, removes D, and submits an exact unchanged replacement for E
  - **Then** one canonical commit advances the collection to revision 42, the result returns one record per correlation ID – the add, A, B, C, and D each carrying a changed outcome with their canonical entry IDs (host-generated for the add) and E carrying an exact-no-op outcome, every record naming resulting revision 42 – and every operation is reflected together in canonical reads

- [x] **S02 [OC01,OC03] [TI03,TI05,TI06] A wholly exact-no-op request does not fabricate a write**
  - **Given** collection revision 42 and personal entry E whose complete canonical payload and state already equal a proposed revision
  - **When** `memory_apply` submits only that exact unchanged revision at collection revision 42
  - **Then** it returns exactly one record, E's, carrying an exact-no-op outcome, E's canonical entry ID, and resulting revision 42, keeps collection and entry revisions at 42 and their current value, and performs no canonical, deletion-audit, or index write

- [x] **S03 [OC02,OC04] [TI01,TI02,TI06] One invalid operation rejects the whole change set with operation-level reasons**
  - **Given** a byte-for-byte snapshot of canonical memory, collection revision, deletion audit, and index rows
  - **When** a current-revision request combines a structurally valid add dispatched without required host provenance context, a merge that repeats a target, and a remove aimed at a wiki, KG, observation, or learning locator
  - **Then** every operation's record carries a rejected outcome with either its precise validation reason or a not-applied-because-change-set-rejected reason and no canonical entry ID, no record carries a changed or exact-no-op outcome, and every captured canonical/index/audit value remains byte-for-byte unchanged
  - **Proof**: `packages/dartclaw_core/test/memory/memory_file_service_test.dart#allows the exact byte limit and rejects repeated crossing appends without changing the file` – green – parity/regression

- [x] **S04 [OC02] [TI02,TI03] Concurrent callers cannot both win the same collection revision**
  - **Given** two valid change sets built from collection revision 51 and released concurrently against the shared workspace mutation authority
  - **When** one request commits first
  - **Then** exactly one commit advances the collection once, while the other returns a typed conflict with the current revision and has no canonical, index, or audit effect
  - **Proof**: `packages/dartclaw_core/test/memory/memory_file_service_test.dart#workspace write lock blocks append until maintenance releases it` – green – parity/regression

- [x] **S05 [OC03] [TI03,TI05,TI06] Post-commit index failure reports durable canonical success as degraded**
  - **Given** a valid current-revision change set and an injected derived-index failure after the canonical atomic replacement succeeds
  - **When** `memory_apply` commits the change set
  - **Then** its typed result exposes the new collection revision and one outcome-bearing record per correlation ID, reports canonical committed plus bounded index-reconciliation degradation facts and a recovery signal that is a typed failure state naming the current collection revision, and keeps the canonical change durable
  - **And** S05 neither stores nor clears health; story S08 consumes those facts, persists degraded health, and clears it only after complete validated reconciliation
  - **Proof**: `packages/dartclaw_storage/test/memory/memory_pruner_test.dart#index failure leaves source retryable and retry creates one archive index row` – green – parity/regression

- [x] **S06 [OC03,OC04] [TI03,TI04,TI05] Forgetting removes entry content everywhere and the host copies none of it into the audit**
  - **Given** active personal entry D contains the unique sentinel `REMOVE-ME-9f8c`, has indexed rows, and is referenced by no other entry
  - **When** a valid remove operation commits with D's entry revision and a nonblank reason that does not itself repeat the sentinel, while the host binds the audited actor/source from its own provenance
  - **Then** D and the sentinel are absent from active/archive canonical content, derived rows, tool output, deletion audit, and runtime audit/log output; the deletion audit retains only D's ID, time, the host-derived actor/source, and the caller's reason stored verbatim, because the host copies no entry content into the audit – a reason is its author's own text, not a host content-retention channel

- [x] **S07 [OC04] [TI06,TI07,TI08,TI09,TI10,TI11] The coherent tool contract is the only live and documented memory-write path**
  - **Given** endpoint-backed and direct-SDK provider modes, built-in jobs, producer prompts, tool discovery, policy allowlists, recipes, and current reference documentation
  - **When** DartClaw starts and each surface is inspected or exercised
  - **Then** `memory_apply` and `memory_observe` map exactly to persistent-memory write policy, `memory_search` and `memory_read` remain read-only, role-specific producers use the correct tool, threshold consolidation cannot dispatch, and no own-MCP `memory_save` tool, alias, callback, schema, policy identity, prompt, recipe, or current-document instruction remains
  - **Proof**: `packages/dartclaw_core/test/harness/claude_tool_mapping_test.dart` – green – parity/regression
  - **Proof**: `packages/dartclaw_core/test/harness/codex_approval_flow_test.dart#maps exact own-MCP approval identities and keeps unknown MCP calls generic` – green – parity/regression
  - **Proof**: `apps/dartclaw_cli/test/commands/service_wiring_local_path_bootstrap_test.dart` – green – parity/regression

- [x] **S08 [OC01] [TI01,TI03] Archive and un-archive are revisions that keep identity and searchability**
  - **Given** collection revision 60, active personal entry F with derived index rows, and archived personal entry G
  - **When** one `memory_apply` request at revision 60 revises F into the archived state and revises G back into the active state
  - **Then** both operations are accepted as ordinary revisions without introducing an operation kind, F and G keep their canonical entry IDs, the collection advances once to revision 61, and reconciliation keeps a derived row for the archived F so archived content stays searchable instead of being dropped the way a removal drops it

- [x] **S09 [OC01] [TI01,TI03] Moving an entry to another topic is a revision that keeps identity**
  - **Given** archived personal entry H under topic `travel` at collection revision 61
  - **When** one `memory_apply` request at revision 61 revises H into topic `logistics` while leaving it archived
  - **Then** the archived target is accepted, H keeps its canonical entry ID and its archived state, its canonical content moves to the `logistics` topic document, the collection advances once to revision 62, and its derived row is updated in place rather than removed

## Structural Criteria

- [x] One host-owned mutation authority performs validation, collection CAS, canonical staging/replacement, revision advancement, deletion auditing, and post-commit index reconciliation under the existing shared workspace lock; deletion-audit entries are canonical content committed within that same replacement, never a side file or a separate write.
- [x] S05 returns typed canonical/index reconciliation facts only; story S08 is the sole owner of persistent index-health state, recovery transitions, last reconciliation, and health clearing.
- [x] The MCP schema exposes no caller-selected user/store/role escape hatch and no caller-supplied actor/source field; the host binds the existing owner scope and derives the audited actor/source from its own provenance, and wiki/KG, observation, and learning write contracts remain unchanged.
- [x] Production Dart, tool discovery, provider maps, exports, prompts, allowlists, current architecture/reference docs, and user guides contain no legacy save contract; only explicit negative tests and immutable historical/upstream provenance may name it.
- [x] The change introduces no package, database, daemon, scheduler, approval framework, autonomous curation loop, QMD responsibility, or wiki/KG mutation path.

## Scope & Boundaries

### Work Areas

- Canonical personal-memory validation, mutation, revision, and deletion-audit authority
- Derived-index reconciliation and typed apply outcome facts for story S08
- MCP handlers, schemas, exports, discovery, and direct-SDK tools
- Claude/Codex canonical mappings, guard policy identity, and CLI/server wiring
- Memory-producing prompts/jobs and obsolete consolidation dispatch
- Component/security/wiring tests plus behavior-local tool, prompt, recipe, and reference documentation

### What We're NOT Doing

- Designing `memory_observe`, `memory_search`, or `memory_read` behavior – S04 owns those contracts; this story only consumes them for migration and policy parity.
- Building the explicit curation operator or prompt workflow – later plan stories consume this apply authority; 0.24 adds no autonomous curation.
- Mutating wiki, KG, raw observations, or bounded learnings through `memory_apply` – their existing guarded contracts remain separate.
- Changing QMD, adding database/hybrid/vector search, or broadening rebuild/recovery architecture – those remain later-story/milestone work.
- Persisting, clearing, or presenting index health – story S08 owns durable health/recovery and story S11 owns operator presentation; S05 reports only the facts produced by this apply attempt.
- Performing the residual cross-document governance audit, ADR lineage reconciliation, or roadmap/release handoff – S12 owns that final pass after all behavior stories land.
- Rewriting historical changelog entries or upstream 0.24 requirements that name the retired tool as migration provenance – current operational and instructional documentation must still converge.

## Architecture Decision

**Approach**: Reuse the prerequisite canonical corpus service as one host-owned personal-memory CAS authority: validate and stage the entire closed change set under the shared lock, atomically commit canonical Markdown/revision/audit once, then reconcile the derived index and report its outcome separately.
**Why this over alternatives**: Separate mutation tools, compatibility aliases, or index-first writes would fragment atomicity, policy identity, and source-of-truth semantics.

## Technical Overview

`memory_apply` receives one expected collection revision and a nonempty operation list. "Bounded" adds no operation-count constant: the bound is that the corpus resulting from the change set must still satisfy the existing 64 MiB canonical-source ceiling, checked before staging. The host binds owner/personal-memory scope and validates every operation against one locked snapshot before any sink is touched. A valid changed set is staged in memory and atomically replaces canonical state once; the deletion audit is itself a canonical document with its own role in the canonical inventory, so its entries are staged and committed inside that same atomic replacement rather than as a side file or a separate write, and crash atomicity follows from the existing marker/journal contract; the collection revision advances once regardless of changed-operation count. Exact no-ops remain explicit and do not create revisions. Derived-index reconciliation starts only after canonical success, so an index failure returns bounded degradation facts rather than rollback or generic success; story S08 converts those facts into persistent health and owns recovery. MCP, direct-SDK, provider-policy, prompt/job, and behavior-local documentation surfaces converge on the same four-tool memory vocabulary, while prerequisite observation/learning capture remains distinct.

## Code Patterns & External References

```text
# type | path#anchor | why needed (intent)
file | packages/dartclaw_core/lib/src/memory/memory_file_service.dart#MemoryFileService | Delegating writer under S02's corpus authority – bounded file handling to preserve, not a second lock/atomic-write seam to mutate through
file | packages/dartclaw_server/lib/src/memory_handlers.dart#createMemoryHandlers | Current handler composition and canonical/index outcome boundary to supersede
file | packages/dartclaw_server/lib/src/mcp/memory_tools.dart#MemorySaveTool | MCP schema/callback pattern and legacy surface to retire
file | packages/dartclaw_core/lib/src/harness/canonical_tool.dart#CanonicalTool | Stable provider-independent policy and audit taxonomy
file | packages/dartclaw_core/lib/src/harness/claude_code_harness.dart#_buildMemorySdkMcpServers | Direct-SDK schema path that must match endpoint-backed tools
file | apps/dartclaw_cli/lib/src/commands/wiring/harness_wiring.dart#HarnessWiring | Registration, exact own-MCP mapping, worker construction, and callback wiring
file | apps/dartclaw_cli/lib/src/commands/wiring/scheduling_wiring.dart#SchedulingWiring | Built-in producer policy and obsolete consolidation wiring
file | packages/dartclaw_server/lib/src/behavior/memory_consolidator.dart#MemoryConsolidator | Threshold-driven append-only curation path to remove completely
```

## Constraints & Gotchas

- **Settled operation shapes**: each operation has a unique caller correlation ID; add supplies complete topic/content and no canonical ID, revise supplies target ID + expected entry revision + complete replacement state including topic and active/archived state (which is what makes archive, un-archive, and re-topic revisions rather than distinct operation kinds), merge supplies one retained target + at least one distinct source with all entry revisions, complete replacement state, and a nonblank reason, and remove supplies target ID + entry revision + a nonblank reason. No operation accepts provenance fields: the host supplies complete provenance for every add, revise, merge, and audit retirement from its trusted origin kind plus caller/session context, so model input can never claim or forge attribution. A reason is capped at 1,024 characters and stored verbatim; the cap is a validation rule that rejects an over-cap reason, never a truncator or a sanitiser.
- **Settled snapshot semantics**: every target resolves against the pre-request snapshot; one canonical ID may occur in only one operation (including merge membership). Cross-operation dependencies and duplicate targets reject the whole request instead of introducing order-dependent behavior.
- **Settled identity/no-op semantics**: add always receives a host-generated changed ID – there is NO add-time dedup, so an add that exactly replays an earlier capture still becomes a new entry with its own identity, and the prune-time exact-replay dedup that later collapses such duplicate sets is owned by S10 rather than by this apply path; revise is no-op only when its normalized complete state is exactly unchanged; merge and active removal are changes. Merge retains the declared existing target ID and audits each removed source ID with the merge's verbatim reason and the host-derived actor/source without copying source-entry content. The unfiltered reason may independently quote that content. Missing targets and targets already removed are invalid, not idempotent no-ops; "inactive" here means REMOVED, never archived. Archived entries stay valid `revise` and `remove` targets, so archive, un-archive, and re-topic are ordinary revisions rather than new operation kinds.
- **Settled no-op revision semantics**: a wholly exact-no-op request succeeds without a canonical/index write or revision advance; a mixed valid request advances collection revision once and reports each operation's outcome separately.
- **Settled result contract**: one typed result carries request-level facts – canonical outcome, index outcome, and the resulting collection revision – plus exactly one typed record per operation, keyed by that operation's caller-supplied correlation ID and carrying its outcome, its canonical entry ID, and the resulting collection revision. There are no parallel changed/no-op ID lists and no separate result shapes: `changed`, `exact no-op`, and `rejected` are outcome values on the per-operation record. The recovery signal reported with index degradation is a typed failure state naming the current collection revision, and a stale-revision conflict is the same kind of typed failure state, so a caller always learns the revision to retry from. Story S09 reporting and story S11 presentation consume this record shape.
- **Settled audit visibility**: the deletion audit is a canonical document, but it is not model-facing – its role sits outside `memory_search`'s and `memory_read`'s role universe and is not an index source. Writing the audit therefore never makes removed content retrievable again: once a remove or merge-source retirement commits, no model-facing tool can return the retired entry or the audit record naming it, so the audit records forgetting rather than reopening it. Operator visibility flows through story S11's surfaces instead.
- **Critical – validate before every sink**: unknown kinds/fields, malformed IDs/revisions, missing host provenance context, invalid personal scope, duplicate/overlapping targets, resulting-corpus size violations against the existing 64 MiB canonical-source ceiling, and stale collection/entry revisions must be settled before canonical (deletion audit included) or index mutation.
- **Critical – canonical truth precedes derived state**: canonical write/revision failure is wholly rejected; only a failure after canonical commit may return committed-but-index-degraded, and canonical content must never roll back to match a failed index.
- **Avoid – generic MCP fallback**: exact DartClaw mutation tools retain persistent-write policy/audit identity on Claude and Codex; a renamed own-MCP tool may not become `mcp_call`, while unrelated third-party tools remain generic.
- **Removal inventory**: implementation must rescan every `memory_save`, `memorySave`, and `MemorySave` literal/symbol before completion; map each production/current-document hit to the appropriate new contract or delete it, preserving only explicit negative tests and immutable historical/upstream provenance.

## Implementation Plan

### Implementation Tasks

- [x] **TI01** The apply request contract is closed, bounded, and personal-memory-only
  - Follow `packages/dartclaw_server/lib/src/mcp/memory_tools.dart#MemoryApplyTool` and `packages/dartclaw_core/lib/src/memory/memory_apply_schema.dart#memoryApplyOperationSchema` for the closed schema shape, and reject unknown fields, cross-store locators, caller-selected scope, any caller-supplied provenance field, a blank or missing merge or remove reason, overlap, malformed revisions, missing host provenance context, and any change set whose resulting corpus would breach the existing 64 MiB canonical-source ceiling, all before staging or mutation. No operation-count constant is introduced; S10 owns the exact-limit and limit-plus-one proofs for that ceiling.
  - **Verify**: Focused table tests cover every operation's valid shape plus unknown kind/field, duplicate target, malformed ID/revision, caller-supplied provenance, content whose commit would breach the 64 MiB canonical-source ceiling (never an operation-count cap), and wiki/KG/observation/learning targets; a direct-SDK test proves dispatch without host provenance context fails closed; component cases prove an archived personal entry is an accepted revise and remove target while a missing or already-removed target is rejected.

- [x] **TI02** Invalid and stale change sets are side-effect free and actionable
  - Mutate exclusively through S02's corpus authority (`dev/bundle/docs/specs/0.24/s02-atomic-memory-corpus.md#architecture-decision`), which owns the lock/atomic-write discipline that `packages/dartclaw_core/lib/src/memory/memory_file_service.dart#MemoryFileService` delegates to – opening a second mutation path against that seam would breach the single-authority requirement; validation and collection/entry CAS must complete against one snapshot before the canonical sink (which carries the deletion audit) or the index sink.
  - **Verify**: Component failure-injection tests prove S03 and S04 by comparing canonical bytes, revision, deletion audit, and index rows before/after every rejection while asserting operation-level reasons and current-revision conflict data.

- [x] **TI03** Wholly valid change sets commit once with exact operation accounting
  - The prerequisite corpus authority must stage add/revise/merge/remove together, preserve the merge target identity, host-generate add identity, treat archive, un-archive, and re-topic as revisions that keep the target's canonical entry ID while keeping archived entries indexed instead of deleting their derived rows, advance changed entry revisions and collection revision exactly once, and return one typed record per caller-supplied correlation ID carrying that operation's outcome, canonical entry ID, and resulting collection revision.
  - **Verify**: Temp-workspace component tests prove scenarios S01, S02, S08, and S09 plus concurrent winner/loser behavior through canonical reads, exact revisions, exact result sets, derived-row fate for archived entries, and absence of intermediate/partial state.

- [x] **TI04** Retired personal entries leave no content-bearing residue
  - Remove and merge-source retirement use the prerequisite deletion-audit seam; the audit is a canonical document committed inside the same canonical transaction as the change, retaining only entry ID, time, the host-derived actor/source, and the operation's reason – the merge's own reason for a retired merge source – stored verbatim under a 1,024-character cap, while removing active/archive canonical content and derived rows. The privacy guarantee is precisely that the host never copies entry content into the audit; a model-authored reason is the model's own text and is not a host content-retention channel.
  - **Verify**: A sentinel-based component/security test proves S06 by scanning canonical files, index rows, tool result, deletion audit, and captured runtime audit/log output for the removed content, and companion cases prove an at-cap reason is stored byte-for-byte while an over-cap reason is rejected at validation.

- [x] **TI05** Canonical and derived-index outcomes remain independently truthful
  - Follow the source-of-truth boundary in `dev/adrs/002-file-based-storage.md#key-design-choices`; reconcile only after canonical success and return typed facts that distinguish canonical outcome, index outcome, failing stage, bounded reason, and resulting revision alongside the per-operation records, with the recovery signal expressed as a typed failure state naming the current collection revision, without persisting or clearing health in S05.
  - **Verify**: The fault matrix injects at three transitions – before canonical replacement (total rejection), at the deletion-audit write inside the canonical transaction (total rejection, because the audit commits with the change there is no durable-change-without-audit state to observe), and after canonical success (durable new revision, the full correlation-ID-keyed record set, and explicit degradation facts with no S05-owned health write); story S08 owns the later persistence/recovery integration proof.

- [x] **TI06** `memory_apply` is the single model-facing curated-memory mutation contract
  - Wire its strict schema and typed result through `packages/dartclaw_server/lib/src/memory_handlers.dart#createMemoryHandlers`, `packages/dartclaw_server/lib/src/mcp/memory_tools.dart`, MCP exports/discovery, and `packages/dartclaw_core/lib/src/harness/claude_code_harness.dart#_buildMemorySdkMcpServers` without a save alias.
  - **Verify**: MCP schema/compliance and direct-SDK tests exercise all operation shapes, the typed result's conflict, rejection, exact-no-op, applied, and index-degraded states together with its correlation-ID-keyed per-operation records, closed additional properties, and absence of `memory_save` discovery.

- [x] **TI07** Persistent-memory policy identity is exact across supported providers
  - Extend `packages/dartclaw_core/lib/src/harness/canonical_tool.dart#CanonicalTool` and `apps/dartclaw_cli/lib/src/commands/wiring/harness_wiring.dart#HarnessWiring` so apply/observe are writes, search/read are reads, exact own-MCP tools map semantically on Claude/Codex, and third-party calls remain generic.
  - **Verify**: Provider mapping/approval tests prove both endpoint and direct-SDK paths hit the intended canonical guard identity, preserve raw identity for audit, respect deny/allow policy, and never grant a write via `mcp_call`.

- [x] **TI08** Production memory producers use only their role-appropriate 0.24 write contract
  - Rescan journal, pre-compaction, self-improvement, knowledge-inbox, schedule, and other production callers: observations/learnings use S04's closed observe roles, curated personal writes use CAS apply with a current revision, and sourced wiki/KG knowledge is not copied into personal memory.
  - **Verify**: Producer and assembled-wiring tests prove each job/prompt's exact allowed tools and destination role, including that untrusted journal/inbox content cannot become prompt-authoritative personal memory without a valid apply.

- [x] **TI09** Threshold-driven append-only consolidation is absent
  - Retire `packages/dartclaw_server/lib/src/behavior/memory_consolidator.dart#MemoryConsolidator` plus exports, heartbeat/schedule dependencies, CLI construction, prompts, and dispatch-only tests; story S09 consumes this completed absence and proves that its explicit system action does not restore any automatic path.
  - **Verify**: Scheduling/heartbeat tests and a production-reference scan prove no size threshold can launch a consolidation turn and no orphan constructor/export/prompt remains.

- [x] **TI10** The legacy memory-save runtime and API surface is absent
  - Remove residual tool classes, callbacks, constants, schemas, provider maps, source labels/locators, status counters, rebuild/pruner assumptions, tests, and package-agent facts across `apps/` and `packages/`, adapting each live consumer to prerequisite canonical roles rather than string-renaming derived identity.
  - **Verify**: Analyzer, barrel/discovery/wiring suites, and a production scan find no `memory_save`, `memorySave`, or `MemorySave` contract while negative tests still prove an unregistered/third-party old spelling cannot gain own-MCP semantics.

- [x] **TI11** Behavior-local documentation teaches the coherent tool and producer contract
  - Update only documentation directly changed by S05 behavior: affected tool/API references, producer prompts and recipes, provider-policy rows, ADR-007/ADR-016, package guidance, and the current changelog entry must agree on observe/apply routing, CAS/current revision, personal-only mutation, exact outcomes, deletion privacy, and truthful provider limits.
  - **Verify**: Link/fitness checks plus a targeted scan of S05-owned surfaces find no live instruction, example, table, or policy row that advertises the old tool; every affected recipe names the correct role-specific write path. S12 owns the residual cross-document governance audit and release lineage.

- [x] **TI12** Release, package, and knowledge boundaries remain intact
  - Preserve core's SQLite-free boundary, storage/server/CLI ownership, existing lock/atomic-write primitives, and wiki/KG/QMD contracts; introduce no package, DB, daemon, scheduler, approval framework, or autonomous loop.
  - **Verify**: Architecture/fitness checks pass and the diff contains no new package/database/scheduler/approval surface or wiki/KG mutation reachable from `memory_apply`.

### Testing Strategy

- [TI01] Table-drive the pure operation/schema matrix, including malformed JSON-decoder number shapes, unknown fields, operation overlap, scope/locator rejection, and boundary-sized UTF-8 content.
- [TI02,TI03,TI04,TI05] Use per-test temp workspaces plus in-memory SQLite; capture canonical bytes/revisions/audit/index before calls, coordinate concurrent CAS calls with completers rather than delays, and inject failures immediately before canonical replacement and immediately after canonical success.
- [TI06,TI07] Exercise the MCP handler result rather than private validators, then cover Claude hook and Codex approval mapping through their existing protocol-adapter/wiring suites. Assert both allowed writes and denied/generic false positives.
- [TI08,TI09,TI10,TI11] Keep one assembled CLI wiring proof and focused producer tests; use repository scans only for absence/inventory, never as the sole proof of behavioral routing.

## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Tag semantics: see the AndThen FIS Mutability Contract. Spec authors leave this section empty._

### Run: 2026-08-12 00:27 UTC – design-change

#### DESIGN CHANGE

Clarify that provenance is required host context for the apply dispatch, not caller-supplied operation data. The trusted host rejects a direct-SDK write without an active turn context and binds complete provenance before invoking the mutation authority.

Old:
```text
  - **When** a current-revision request combines a structurally valid add with a merge that repeats a target, a revision missing required provenance, and a remove aimed at a wiki, KG, observation, or learning locator
```
New:
```text
  - **When** a current-revision request combines a structurally valid add dispatched without required host provenance context, a merge that repeats a target, and a remove aimed at a wiki, KG, observation, or learning locator
```

#### ADR

The FIS Architecture Decision already selects one host-owned personal-memory authority. Owner-ratified preflight resolution 24 further requires the host to derive audit provenance and forbids caller-supplied actor/source fields. This amendment resolves the contradictory scenario wording in favor of that existing trusted-host boundary; it creates no project-wide architecture change.

#### DECISION NOTE: apply-provenance-boundary

Decision-Key: apply-provenance-boundary
Altitude: fis-local
Affected surface: Constraints & Gotchas ("Settled operation shapes" and "Critical – validate before every sink"); Implementation Task TI01 (statement and Verify)
Decision: Provenance is required trusted host context for the apply dispatch, never an operation field. Add supplies topic/content, revise and merge supply replacement state, and the host binds complete provenance for every new revision and deletion audit.
Rationale: This makes the operation contract agree with its existing no-caller-provenance structural criterion and owner-ratified preflight resolution 24. Accepting model-authored provenance would make attribution forgeable.
Evidence: Direct-SDK dispatch now fails closed without an active turn context; handler wiring binds `MemoryCaptureContext` before `MemoryApplyService.apply`; closed-schema tests reject caller-supplied provenance fields.

Old:
```text
- **Settled operation shapes**: each operation has a unique caller correlation ID; add supplies complete topic/content/provenance and no canonical ID, revise supplies target ID + expected entry revision + complete replacement state including topic and active/archived state (which is what makes archive, un-archive, and re-topic revisions rather than distinct operation kinds), merge supplies one retained target + at least one distinct source with all entry revisions, complete replacement provenance, and a nonblank reason, and remove supplies target ID + entry revision + a nonblank reason. Neither shape accepts a caller-supplied actor or source: the host derives the audited actor/source from its own provenance – origin kind plus caller/session – so model input can never claim or forge them. A reason is capped at 1,024 characters and stored verbatim; the cap is a validation rule that rejects an over-cap reason, never a truncator or a sanitiser.
```
New:
```text
- **Settled operation shapes**: each operation has a unique caller correlation ID; add supplies complete topic/content and no canonical ID, revise supplies target ID + expected entry revision + complete replacement state including topic and active/archived state (which is what makes archive, un-archive, and re-topic revisions rather than distinct operation kinds), merge supplies one retained target + at least one distinct source with all entry revisions, complete replacement state, and a nonblank reason, and remove supplies target ID + entry revision + a nonblank reason. No operation accepts provenance fields: the host supplies complete provenance for every add, revise, merge, and audit retirement from its trusted origin kind plus caller/session context, so model input can never claim or forge attribution. A reason is capped at 1,024 characters and stored verbatim; the cap is a validation rule that rejects an over-cap reason, never a truncator or a sanitiser.
```

Old:
```text
- **Critical – validate before every sink**: unknown kinds/fields, malformed IDs/revisions, missing provenance, invalid personal scope, duplicate/overlapping targets, resulting-corpus size violations against the existing 64 MiB canonical-source ceiling, and stale collection/entry revisions must be settled before canonical (deletion audit included) or index mutation.
```
New:
```text
- **Critical – validate before every sink**: unknown kinds/fields, malformed IDs/revisions, missing host provenance context, invalid personal scope, duplicate/overlapping targets, resulting-corpus size violations against the existing 64 MiB canonical-source ceiling, and stale collection/entry revisions must be settled before canonical (deletion audit included) or index mutation.
```

Old:
```text
  - Follow `packages/dartclaw_server/lib/src/mcp/memory_tools.dart#MemorySaveTool` for strict schema shape, but enforce the operation assumptions and reject unknown fields, cross-store locators, caller-selected scope, any caller-supplied actor/source field, a blank or missing merge or remove reason, overlap, malformed revisions, missing provenance, and any change set whose resulting corpus would breach the existing 64 MiB canonical-source ceiling, all before staging or mutation. No operation-count constant is introduced; S10 owns the exact-limit and limit-plus-one proofs for that ceiling.
```
New:
```text
  - Follow `packages/dartclaw_server/lib/src/mcp/memory_tools.dart#MemoryApplyTool` and `packages/dartclaw_core/lib/src/memory/memory_apply_schema.dart#memoryApplyOperationSchema` for the closed schema shape, and reject unknown fields, cross-store locators, caller-selected scope, any caller-supplied provenance field, a blank or missing merge or remove reason, overlap, malformed revisions, missing host provenance context, and any change set whose resulting corpus would breach the existing 64 MiB canonical-source ceiling, all before staging or mutation. No operation-count constant is introduced; S10 owns the exact-limit and limit-plus-one proofs for that ceiling.
```

Old:
```text
  - **Verify**: Focused table tests cover every operation's valid shape plus unknown kind/field, duplicate target, malformed ID/revision, missing provenance, content whose commit would breach the 64 MiB canonical-source ceiling (never an operation-count cap), and wiki/KG/observation/learning targets, and prove an archived personal entry is an accepted revise and remove target while a missing or already-removed target is rejected.
```
New:
```text
  - **Verify**: Focused table tests cover every operation's valid shape plus unknown kind/field, duplicate target, malformed ID/revision, caller-supplied provenance, content whose commit would breach the 64 MiB canonical-source ceiling (never an operation-count cap), and wiki/KG/observation/learning targets; a direct-SDK test proves dispatch without host provenance context fails closed; component cases prove an archived personal entry is an accepted revise and remove target while a missing or already-removed target is rejected.
```

#### DECISION NOTE: deletion-audit-persistence

Decision-Key: deletion-audit-persistence
Altitude: fis-local
Affected surface: Technical Overview; Structural Criteria (mutation-authority bullet); Constraints & Gotchas ("Critical – validate before every sink"); Implementation Tasks TI02, TI04, and TI05 (fault matrix)
Decision: The deletion audit is a canonical document with its own role in the canonical inventory, and its entries are committed inside the SAME canonical transaction as the change they audit – never a side file, never a separate sink or write. TI05's fault matrix gains an audit-write transition proving no durable-change-without-audit state exists.
Rationale: Owner-ratified. An in-transaction canonical audit inherits crash atomicity from the existing marker/journal atomic-replacement contract, whereas a side file would need its own crash-consistency machinery – the speculative mechanism the leanness rule and standing directive D-B reject.
Evidence: Owner-ratified preflight 0.24 resolution 21; the prerequisite corpus authority already commits every canonical document through one lock-guarded atomic replacement, so an in-transaction audit introduces no new durability mechanism.

Old:
```text
A valid changed set is staged in memory and atomically replaces canonical state once; the collection revision advances once regardless of changed-operation count.
```
New:
```text
A valid changed set is staged in memory and atomically replaces canonical state once; the deletion audit is itself a canonical document with its own role in the canonical inventory, so its entries are staged and committed inside that same atomic replacement rather than as a side file or a separate write, and crash atomicity follows from the existing marker/journal contract; the collection revision advances once regardless of changed-operation count.
```

Old:
```text
One host-owned mutation authority performs validation, collection CAS, canonical staging/replacement, revision advancement, deletion auditing, and post-commit index reconciliation under the existing shared workspace lock.
```
New:
```text
One host-owned mutation authority performs validation, collection CAS, canonical staging/replacement, revision advancement, deletion auditing, and post-commit index reconciliation under the existing shared workspace lock; deletion-audit entries are canonical content committed within that same replacement, never a side file or a separate write.
```

Old:
```text
must be settled before canonical, audit, or index mutation.
```
New:
```text
must be settled before canonical (deletion audit included) or index mutation.
```

Old:
```text
validation and collection/entry CAS must complete against one snapshot before canonical, audit, or index sinks.
```
New:
```text
validation and collection/entry CAS must complete against one snapshot before the canonical sink (which carries the deletion audit) or the index sink.
```

Old:
```text
  - Remove and merge-source retirement use the prerequisite deletion-audit seam; retain only entry ID, time, actor/source, and reason while removing active/archive canonical content and derived rows.
```
New:
```text
  - Remove and merge-source retirement use the prerequisite deletion-audit seam; the audit is a canonical document committed inside the same canonical transaction as the change, retaining only entry ID, time, actor/source, and reason while removing active/archive canonical content and derived rows.
```

Old:
```text
  - **Verify**: Failure injection before canonical replacement proves total rejection, while injection after replacement proves S05's durable new revision, exact result IDs, and explicit degradation facts with no S05-owned health write; S08 owns the later persistence/recovery integration proof.
```
New:
```text
  - **Verify**: The fault matrix injects at three transitions – before canonical replacement (total rejection), at the deletion-audit write inside the canonical transaction (total rejection, because the audit commits with the change there is no durable-change-without-audit state to observe), and after canonical success (durable new revision, exact result IDs, and explicit degradation facts with no S05-owned health write); S08 owns the later persistence/recovery integration proof.
```

#### DECISION NOTE: archived-target-validity

Decision-Key: archived-target-validity
Altitude: fis-local
Affected surface: Constraints & Gotchas ("Settled identity/no-op semantics" and "Settled operation shapes"); Acceptance Scenarios (new S08 and S09 appended after S07); Implementation Tasks TI01 and TI03
Decision: Archived entries ARE valid `revise` and `remove` targets, including un-archive. Archive, un-archive, and re-topic are ordinary revisions carried by the complete replacement state, not new operation kinds, so the closed operation set stays add/revise/merge/remove. The former "Missing/inactive targets are invalid" wording is corrected: "inactive" means REMOVED, never archived. New scenarios S08 and S09 cover archive-via-revise, un-archive-via-revise, and re-topic-via-revise including derived-row fate – an archived entry keeps its derived row and stays searchable, unlike a removal.
Rationale: Owner-ratified per PRD FR2/FR3. Treating archive or re-topic as its own operation kind would widen the closed set for no behavioral gain, and treating an archived entry as an invalid target would make un-archiving impossible – the corpus would be a one-way door.
Evidence: Owner-ratified preflight 0.24 resolution 22; the revise shape already carries complete replacement state, which subsumes topic and archived/active state, and the existing pruner proof (`memory_pruner_test.dart#index failure leaves source retryable and retry creates one archive index row`) already assumes archived entries hold index rows.

Old:
```text
Missing/inactive targets are invalid, not idempotent no-ops.
```
New:
```text
Missing targets and targets already removed are invalid, not idempotent no-ops; "inactive" here means REMOVED, never archived. Archived entries stay valid `revise` and `remove` targets, so archive, un-archive, and re-topic are ordinary revisions rather than new operation kinds.
```

Old:
```text
revise supplies target ID + expected entry revision + complete replacement state,
```
New:
```text
revise supplies target ID + expected entry revision + complete replacement state including topic and active/archived state (which is what makes archive, un-archive, and re-topic revisions rather than distinct operation kinds),
```

Old:
```text
  - **Proof**: `apps/dartclaw_cli/test/commands/service_wiring_local_path_bootstrap_test.dart` – green – parity/regression
```
New:
```text
  - **Proof**: `apps/dartclaw_cli/test/commands/service_wiring_local_path_bootstrap_test.dart` – green – parity/regression

- [ ] **S08 [OC01] [TI01,TI03] Archive and un-archive are revisions that keep identity and searchability**
  - **Given** collection revision 60, active personal entry F with derived index rows, and archived personal entry G
  - **When** one `memory_apply` request at revision 60 revises F into the archived state and revises G back into the active state
  - **Then** both operations are accepted as ordinary revisions without introducing an operation kind, F and G keep their canonical entry IDs, the collection advances once to revision 61, and reconciliation keeps a derived row for the archived F so archived content stays searchable instead of being dropped the way a removal drops it

- [ ] **S09 [OC01] [TI01,TI03] Moving an entry to another topic is a revision that keeps identity**
  - **Given** archived personal entry H under topic `travel` at collection revision 61
  - **When** one `memory_apply` request at revision 61 revises H into topic `logistics` while leaving it archived
  - **Then** the archived target is accepted, H keeps its canonical entry ID and its archived state, its canonical content moves to the `logistics` topic document, the collection advances once to revision 62, and its derived row is updated in place rather than removed
```

Old:
```text
  - **Verify**: Focused table tests cover every operation's valid shape plus unknown kind/field, duplicate target, malformed ID/revision, missing provenance, oversized content, and wiki/KG/observation/learning targets.
```
New:
```text
  - **Verify**: Focused table tests cover every operation's valid shape plus unknown kind/field, duplicate target, malformed ID/revision, missing provenance, oversized content, and wiki/KG/observation/learning targets, and prove an archived personal entry is an accepted revise and remove target while a missing or already-removed target is rejected.
```

Old:
```text
  - The prerequisite corpus authority must stage add/revise/merge/remove together, preserve the merge target identity, host-generate add identity, advance changed entry revisions and collection revision exactly once, and report changed/no-op operation IDs and canonical entry IDs.
```
New:
```text
  - The prerequisite corpus authority must stage add/revise/merge/remove together, preserve the merge target identity, host-generate add identity, treat archive, un-archive, and re-topic as revisions that keep the target's canonical entry ID while keeping archived entries indexed instead of deleting their derived rows, advance changed entry revisions and collection revision exactly once, and report changed/no-op operation IDs and canonical entry IDs.
```

Old:
```text
  - **Verify**: Temp-workspace component tests prove S01, S02, and concurrent winner/loser behavior through canonical reads, exact revisions, exact result sets, and absence of intermediate/partial state.
```
New:
```text
  - **Verify**: Temp-workspace component tests prove S01, S02, S08, S09, and concurrent winner/loser behavior through canonical reads, exact revisions, exact result sets, derived-row fate for archived entries, and absence of intermediate/partial state.
```

#### DECISION NOTE: apply-result-contract

Decision-Key: apply-result-contract
Altitude: fis-local
Affected surface: Feature Overview and Goal (OC01); Acceptance Scenarios S01 (title and Then), S02, S03, and S05 (Then clauses); Constraints & Gotchas ("Settled no-op revision semantics" plus a new "Settled result contract" bullet); Implementation Tasks TI03, TI05, TI06
Decision: The apply result is stated once: one typed result carrying request-level facts (canonical outcome, index outcome, resulting collection revision) plus exactly one typed record per operation, keyed by the caller-supplied correlation ID and carrying {outcome, canonical entry id, resulting collection revision}. `changed`, `exact no-op`, and `rejected` are outcome values on that record, not separate result shapes, and there are no parallel changed/no-op ID lists. The "recovery signal" is a typed failure state naming the current collection revision – the same kind of state a stale-revision conflict returns. S09 reporting and S11 presentation consume this shape.
Rationale: Owner-ratified. The FIS previously described the same result three incompatible ways – "entry IDs", "changed operations", and "operation IDs" – which left an executor free to invent parallel ID lists that cannot express a rejected operation's reason or a per-operation revision. Correlation-ID keying is already settled in the operation shape, so keying the result the same way removes the ambiguity without adding surface.
Evidence: Owner-ratified preflight 0.24 resolution 23; the operation shape already mandates a unique caller correlation ID per operation, and the downstream S09/S11 consumers need a stable per-operation key rather than three overlapping list vocabularies.

Old:
```text
- [OC01] One compare-and-swap request applies a wholly valid mix of add, revise, merge, and remove operations atomically and reports the exact changed and exact-no-op entry IDs.
```
New:
```text
- [OC01] One compare-and-swap request applies a wholly valid mix of add, revise, merge, and remove operations atomically and reports one typed record per caller-supplied correlation ID carrying that operation's outcome, canonical entry ID, and resulting collection revision.
```

Old:
```text
A mixed valid personal-memory change set commits once with exact changed and no-op IDs
```
New:
```text
A mixed valid personal-memory change set commits once with exact per-operation outcomes
```

Old:
```text
  - **Then** one canonical commit advances the collection to revision 42, the response associates the host-generated add ID and A/B/C/D with changed operations, associates only E with an exact no-op, and every operation is reflected together in canonical reads
```
New:
```text
  - **Then** one canonical commit advances the collection to revision 42, the result returns one record per correlation ID – the add, A, B, C, and D each carrying a changed outcome with their canonical entry IDs (host-generated for the add) and E carrying an exact-no-op outcome, every record naming resulting revision 42 – and every operation is reflected together in canonical reads
```

Old:
```text
  - **Then** it returns no changed IDs and exactly E as no-op, keeps collection and entry revisions at 42 and their current value, and performs no canonical, deletion-audit, or index write
```
New:
```text
  - **Then** it returns exactly one record, E's, carrying an exact-no-op outcome, E's canonical entry ID, and resulting revision 42, keeps collection and entry revisions at 42 and their current value, and performs no canonical, deletion-audit, or index write
```

Old:
```text
  - **Then** every operation receives either its precise validation reason or a not-applied-because-change-set-rejected reason, changed and no-op ID lists are empty, and every captured canonical/index/audit value remains byte-for-byte unchanged
```
New:
```text
  - **Then** every operation's record carries a rejected outcome with either its precise validation reason or a not-applied-because-change-set-rejected reason and no canonical entry ID, no record carries a changed or exact-no-op outcome, and every captured canonical/index/audit value remains byte-for-byte unchanged
```

Old:
```text
  - **Then** its typed result exposes the new collection revision and exact changed/no-op IDs, reports canonical committed plus bounded index-reconciliation degradation facts and a recovery signal, and keeps the canonical change durable
```
New:
```text
  - **Then** its typed result exposes the new collection revision and one outcome-bearing record per correlation ID, reports canonical committed plus bounded index-reconciliation degradation facts and a recovery signal that is a typed failure state naming the current collection revision, and keeps the canonical change durable
```

Old:
```text
- **Settled no-op revision semantics**: a wholly exact-no-op request succeeds without a canonical/index write or revision advance; a mixed valid request advances collection revision once and reports changed/no-op operations separately.
```
New:
```text
- **Settled no-op revision semantics**: a wholly exact-no-op request succeeds without a canonical/index write or revision advance; a mixed valid request advances collection revision once and reports each operation's outcome separately.
- **Settled result contract**: one typed result carries request-level facts – canonical outcome, index outcome, and the resulting collection revision – plus exactly one typed record per operation, keyed by that operation's caller-supplied correlation ID and carrying its outcome, its canonical entry ID, and the resulting collection revision. There are no parallel changed/no-op ID lists and no separate result shapes: `changed`, `exact no-op`, and `rejected` are outcome values on the per-operation record. The recovery signal reported with index degradation is a typed failure state naming the current collection revision, and a stale-revision conflict is the same kind of typed failure state, so a caller always learns the revision to retry from. S09 reporting and S11 presentation consume this record shape.
```

Old:
```text
and report changed/no-op operation IDs and canonical entry IDs.
```
New:
```text
and return one typed record per caller-supplied correlation ID carrying that operation's outcome, canonical entry ID, and resulting collection revision.
```

Old:
```text
return typed facts that distinguish canonical outcome, index outcome, failing stage, bounded reason, recovery signal, and revision without persisting or clearing health in S05.
```
New:
```text
return typed facts that distinguish canonical outcome, index outcome, failing stage, bounded reason, and resulting revision alongside the per-operation records, with the recovery signal expressed as a typed failure state naming the current collection revision, without persisting or clearing health in S05.
```

Old:
```text
durable new revision, exact result IDs, and explicit degradation facts
```
New:
```text
durable new revision, the full correlation-ID-keyed record set, and explicit degradation facts
```

Old:
```text
typed conflict/rejection/no-op/applied/index-degraded results, closed additional properties, and absence of `memory_save` discovery.
```
New:
```text
the typed result's conflict, rejection, exact-no-op, applied, and index-degraded states together with its correlation-ID-keyed per-operation records, closed additional properties, and absence of `memory_save` discovery.
```

#### DECISION NOTE: merge-audit-fields

Decision-Key: merge-audit-fields
Altitude: fis-local
Affected surface: Constraints & Gotchas ("Settled operation shapes" and "Settled identity/no-op semantics"); Structural Criteria (MCP-schema escape-hatch bullet); Acceptance Scenario S06 (When); Implementation Tasks TI01 and TI04
Decision: The merge operation shape gains a `reason` field, nonblank like remove's, so every audited retirement (removed entry or retired merge source) carries a reason. Actor and source are NOT operation fields on any shape: the host derives the audited actor/source from its own provenance – origin kind plus caller/session. The remove shape therefore drops its caller-supplied actor/source, and the MCP schema exposes no actor/source field at all.
Rationale: Owner-ratified. Merge retires source entries exactly as remove retires a target, so the audit needed the same explanation field. Accepting actor/source from model input would let untrusted content author the identity in an audit record – a forgeable attribution in the one artifact that survives deletion. Host provenance is already available and cannot be spoofed by the caller.
Evidence: Owner-ratified preflight 0.24 resolution 24; the FIS already binds owner/personal scope host-side rather than accepting it from the caller, and the PRD constraint that model and tool content is untrusted makes caller-authored attribution unusable as audit evidence.

Old:
```text
merge supplies one retained target + at least one distinct source with all entry revisions and complete replacement provenance, and remove supplies target ID + entry revision + actor/source + nonblank reason.
```
New:
```text
merge supplies one retained target + at least one distinct source with all entry revisions, complete replacement provenance, and a nonblank reason, and remove supplies target ID + entry revision + a nonblank reason. Neither shape accepts a caller-supplied actor or source: the host derives the audited actor/source from its own provenance – origin kind plus caller/session – so model input can never claim or forge them.
```

Old:
```text
Merge retains the declared existing target ID and content-free-audits removed source IDs.
```
New:
```text
Merge retains the declared existing target ID and content-free-audits each removed source ID with the merge's own reason and the host-derived actor/source.
```

Old:
```text
The MCP schema exposes no caller-selected user/store/role escape hatch; the host binds the existing owner scope, and wiki/KG, observation, and learning write contracts remain unchanged.
```
New:
```text
The MCP schema exposes no caller-selected user/store/role escape hatch and no caller-supplied actor/source field; the host binds the existing owner scope and derives the audited actor/source from its own provenance, and wiki/KG, observation, and learning write contracts remain unchanged.
```

Old:
```text
  - **When** a valid remove operation commits with D's entry revision, actor/source, and nonblank reason
```
New:
```text
  - **When** a valid remove operation commits with D's entry revision and a nonblank reason while the host binds the audited actor/source from its own provenance
```

Old:
```text
reject unknown fields, cross-store locators, caller-selected scope, overlap, malformed revisions, missing provenance, and corpus limits before mutation.
```
New:
```text
reject unknown fields, cross-store locators, caller-selected scope, any caller-supplied actor/source field, a blank or missing merge or remove reason, overlap, malformed revisions, missing provenance, and corpus limits before mutation.
```

Old:
```text
retaining only entry ID, time, actor/source, and reason while removing active/archive canonical content and derived rows.
```
New:
```text
retaining only entry ID, time, the host-derived actor/source, and the operation's reason – the merge's own reason for a retired merge source – while removing active/archive canonical content and derived rows.
```

#### DECISION NOTE: apply-operation-bound

Decision-Key: apply-operation-bound
Altitude: fis-local
Affected surface: Technical Overview; Constraints & Gotchas ("Critical – validate before every sink"); Implementation Task TI01 (statement and Verify)
Decision: "Bounded" introduces NO new operation-count constant. The bound on an apply request is that the corpus resulting from the change set must still satisfy the existing 64 MiB canonical-source ceiling, validated before staging. S10 owns the exact-limit and limit-plus-one proofs for that ceiling; S05 only enforces it.
Rationale: Owner-ratified. A separate operation-count constant would be an invented, unrequested config knob that guards nothing the byte ceiling does not already guard – the resource that actually matters is the resulting corpus size, not the number of operations that produced it.
Evidence: Owner-ratified preflight 0.24 resolution 25; the 64 MiB canonical-source ceiling already exists and is owned by S10, so S05 needs no second limit and no new constant to be bounded.

Old:
```text
`memory_apply` receives one expected collection revision and a bounded nonempty operation list.
```
New:
```text
`memory_apply` receives one expected collection revision and a nonempty operation list. "Bounded" adds no operation-count constant: the bound is that the corpus resulting from the change set must still satisfy the existing 64 MiB canonical-source ceiling, checked before staging.
```

Old:
```text
size/bounds violations
```
New:
```text
resulting-corpus size violations against the existing 64 MiB canonical-source ceiling
```

Old:
```text
and corpus limits before mutation.
```
New:
```text
and any change set whose resulting corpus would breach the existing 64 MiB canonical-source ceiling, all before staging or mutation. No operation-count constant is introduced; S10 owns the exact-limit and limit-plus-one proofs for that ceiling.
```

Old:
```text
oversized content
```
New:
```text
content whose commit would breach the 64 MiB canonical-source ceiling (never an operation-count cap)
```

#### DECISION NOTE: remove-reason-content-rule

Decision-Key: remove-reason-content-rule
Altitude: fis-local
Affected surface: Feature Overview and Goal (OC03); Constraints & Gotchas ("Settled operation shapes" and "Settled identity/no-op semantics"); Acceptance Scenario S06 (When and Then); Implementation Task TI04 (statement and Verify)
Decision: A `reason` is capped at 1,024 characters and stored verbatim – the cap rejects an over-cap reason at validation and never truncates or sanitises. The privacy guarantee is scoped precisely: the HOST never copies entry content into the deletion audit. A model-authored reason is the model's own text, so it is not a host content-retention channel, and the sentinel proof holds because the host copies nothing, not because reasons are filtered.
Rationale: Owner-ratified. An unscoped "content-free audit" claim is unprovable once the caller supplies free text, and enforcing it would mean scanning or rewriting the caller's reason – a filter that would silently corrupt the one field explaining why an entry was destroyed. Stating the guarantee as a host-behavior rule keeps it both true and testable, and the character cap keeps the audit bounded without touching its content.
Evidence: Owner-ratified preflight 0.24 resolution 26; scenario S06 proves absence of the entry's own sentinel from the audit, which a host-copies-nothing rule satisfies exactly, while a literal content-free-text rule would be falsified by any caller who quotes the entry in its reason.

Old:
```text
Merge retains the declared existing target ID and content-free-audits each removed source ID with the merge's own reason and the host-derived actor/source.
```
New:
```text
Merge retains the declared existing target ID and audits each removed source ID with the merge's verbatim reason and the host-derived actor/source without copying source-entry content. The unfiltered reason may independently quote that content.
```

Old:
```text
- [OC03] Callers can distinguish canonical commit success from derived-index degradation, and forgetting removes content while retaining only content-free audit metadata.
```
New:
```text
- [OC03] Callers can distinguish canonical commit success from derived-index degradation, and forgetting removes content while the audit retains only host-derived metadata plus the caller's own verbatim reason – the host never copies entry content into the audit.
```

Old:
```text
Neither shape accepts a caller-supplied actor or source: the host derives the audited actor/source from its own provenance – origin kind plus caller/session – so model input can never claim or forge them.
```
New:
```text
Neither shape accepts a caller-supplied actor or source: the host derives the audited actor/source from its own provenance – origin kind plus caller/session – so model input can never claim or forge them. A reason is capped at 1,024 characters and stored verbatim; the cap is a validation rule that rejects an over-cap reason, never a truncator or a sanitiser.
```

Old:
```text
  - **When** a valid remove operation commits with D's entry revision and a nonblank reason while the host binds the audited actor/source from its own provenance
```
New:
```text
  - **When** a valid remove operation commits with D's entry revision and a nonblank reason that does not itself repeat the sentinel, while the host binds the audited actor/source from its own provenance
```

Old:
```text
; the deletion audit retains only D's ID, time, actor/source, and reason
```
New:
```text
; the deletion audit retains only D's ID, time, the host-derived actor/source, and the caller's reason stored verbatim, because the host copies no entry content into the audit – a reason is its author's own text, not a host content-retention channel
```

Old:
```text
retaining only entry ID, time, the host-derived actor/source, and the operation's reason – the merge's own reason for a retired merge source – while removing active/archive canonical content and derived rows.
```
New:
```text
retaining only entry ID, time, the host-derived actor/source, and the operation's reason – the merge's own reason for a retired merge source – stored verbatim under a 1,024-character cap, while removing active/archive canonical content and derived rows. The privacy guarantee is precisely that the host never copies entry content into the audit; a model-authored reason is the model's own text and is not a host content-retention channel.
```

Old:
```text
  - **Verify**: A sentinel-based component/security test proves S06 by scanning canonical files, index rows, tool result, deletion audit, and captured runtime audit/log output for the removed content.
```
New:
```text
  - **Verify**: A sentinel-based component/security test proves S06 by scanning canonical files, index rows, tool result, deletion audit, and captured runtime audit/log output for the removed content, and companion cases prove an at-cap reason is stored byte-for-byte while an over-cap reason is rejected at validation.
```

#### DECISION NOTE: dedup-prune-audit

Decision-Key: dedup-prune-audit
Altitude: fis-local
Affected surface: Constraints & Gotchas ("Settled identity/no-op semantics")
Decision: S05-side consumption of the ratified cross-story dedup decision: there is NO add-time dedup in the apply path. The settled "add always receives a host-generated changed ID" is scoped explicitly – an add that exactly replays an earlier capture still becomes a new entry with its own identity, and this apply path never evaluates duplicates. Prune-time exact-replay dedup, which later collapses such duplicate sets, is owned by S10.
Rationale: Owner-ratified. Without the explicit scoping, S05's identity rule and S10's exact-replay dedup read as a contradiction, and an executor could add duplicate detection to the apply path – reintroducing exactly the order-dependent, content-comparing behavior the closed operation set exists to prevent. Naming S10 as the owner keeps the two stories consistent without either duplicating the mechanism.
Evidence: Owner-ratified preflight 0.24 resolution 35 (apply-side clause: "NO add-time dedup – S05's settled 'add always receives a host-generated changed ID' governs"), which also routes prune-time removals through the same content-free deletion-audit contract this FIS settles.

Old:
```text
add always receives a host-generated changed ID;
```
New:
```text
add always receives a host-generated changed ID – there is NO add-time dedup, so an add that exactly replays an earlier capture still becomes a new entry with its own identity, and the prune-time exact-replay dedup that later collapses such duplicate sets is owned by S10 rather than by this apply path;
```

#### DECISION NOTE: audit-not-model-readable

Decision-Key: audit-not-model-readable
Altitude: fis-local
Affected surface: Constraints & Gotchas ("Settled audit visibility")
Decision: The deletion audit is a canonical document but is not model-facing: its role is outside `memory_search`'s and `memory_read`'s role universe and is not an index source, so writing the audit never makes removed content retrievable again – after a remove or merge-source retirement commits, no model-facing tool returns the retired entry or the audit record naming it.
Rationale: Owner-ratified 2026-08-11 as a consequence of the ratified audit-as-canonical-document decision rather than a new design choice: returning deletion audits to a model would hand back exactly the content the user asked to forget, defeating OC03's forget guarantee – the same reason the audit is not an index source. Operator visibility flows through story S11's surfaces instead.
Evidence: Owner-ratified preflight 0.24 resolution 43 ("Not model-readable" clause); this FIS's OC03 host-copies-nothing privacy scope and S06 sentinel proof; `dev/bundle/docs/specs/0.24/s04-observation-and-retrieval-tools.md` retrieval role universe for `memory_search`/`memory_read`.
