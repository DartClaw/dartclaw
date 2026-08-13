# Feature Implementation Specification: Search and Citation Convergence

**Plan**: dev/bundle/docs/specs/0.24/plan.json
**Story-ID**: S07

## Feature Overview and Goal

**Intent**: Let users trust that every memory search and citation names the same canonical source regardless of caller, selected backend, index lifecycle, or partial retrieval failure.

**Expected Outcomes**:

- [OC01] MCP, Knowledge Hub, and Context Research accept the same natural-language query contract and return bounded results without exposing backend syntax.
- [OC02] Every retrieved personal-memory or wiki item carries an unambiguous role and stable locator that resolves to the canonical source within the host-bound user scope.
- [OC03] Wiki synthesis keeps its precedence and native provenance while each request traverses and composes wiki content exactly once, ranks every scan-admitted candidate before returning its best 50, and reports degraded layers explicitly.
- [OC04] Live mutation, migration, pruning, and full rebuild produce equivalent derived identity so search and citations survive index replacement.

## Required Context

- `dev/bundle/docs/specs/0.24/plan.json#stories.6` – exact S07 scope, P3/W6 placement, S05 dependency, risk, notes, and asset provenance.
- `dev/bundle/docs/specs/0.24/plan.json#sharedDecisions.0` – canonical corpus contract shared with every retrieval and index lifecycle.
- `dev/bundle/docs/specs/0.24/plan.json#sharedDecisions.3` – stable locator and backend-owned natural-language query contract.
- `dev/bundle/docs/specs/0.24/plan.json#sharedDecisions.5` – best-50-after-ranking output ceiling, plus the fixed scan budgets that story S10 introduces later and this story must not pre-empt.
- `dev/bundle/docs/specs/0.24/plan.json#sharedDecisions.7` – 0.24/0.25 release boundary and no-new-infrastructure decision.
- `dev/bundle/docs/specs/0.24/plan.json#bindingConstraints.0` – FR1 file-canonical authority constraint.
- `dev/bundle/docs/specs/0.24/plan.json#bindingConstraints.4` – FR5 natural-language/backend-encoding constraint.
- `dev/bundle/docs/specs/0.24/plan.json#bindingConstraints.6` – FR8 no-new-package/database/daemon/scheduler constraint.
- `dev/bundle/docs/specs/0.24/plan.json#bindingConstraints.7` – FR8 wiki/KG write-boundary constraint.
- `dev/bundle/docs/specs/0.24/plan.json#bindingConstraints.8` – settled host-trust and resource-threat constraint.
- `dev/bundle/docs/specs/0.24/prd.md#fr5-retrieval-citation-and-index-integrity` – caller/backend query boundary, result identity, wiki precedence, degradation, user scope, and live/rebuild parity contract.
- `dev/bundle/docs/specs/0.24/prd.md#fr8-simplification-and-release-boundaries` – duplicate wiki composition removal, QMD timing, and no-new-infrastructure boundary.
- `dev/bundle/docs/specs/0.24/prd.md#architecture-review-coverage` – concrete caller encoding, generic locator, duplicate wiki scan, and identity-drift defects this story closes.
- `dev/bundle/docs/specs/0.24/prd.md#constraints` – single-owner runtime, file-canonical storage, package boundary, QMD transition, and trusted-host threat model.
- `dev/bundle/docs/specs/0.24/s04-observation-and-retrieval-tools.md#technical-overview` – prerequisite raw-query, owner-scoped result, canonical read, and role/locator contract; extend it rather than inventing another result model.
- `dev/bundle/docs/specs/0.24/s05-atomic-memory-apply.md#technical-overview` – prerequisite canonical-commit/index-outcome ordering and the retired generic `memory_save` identity.
- `dev/adrs/029-temporal-knowledge-graph-durable-knowledge-loop.md#decision` – wiki synthesis outranks raw personal memory and retains source provenance independent of selected search backend.
- `dev/adrs/042-context-research-synthesis-and-citation-model.md#decision` – shared citation packet, resolver, unattributed fallback, and degraded-layer semantics.
- `dev/adrs/050-native-hybrid-search.md#decision` – QMD remains transitional; native hybrid/vector semantics and a new search package belong to 0.25.

## Deeper Context

- `dev/bundle/docs/specs/0.24/memory-architecture-recommendations.md#fix-in-024` – reviewed minimal fixes for natural-language search, stable identity, live/rebuild parity, and one wiki traversal.
- `dev/bundle/docs/specs/0.24/memory-architecture-recommendations.md#architecture-fitness-functions-and-tests` – query, citation, wiki-ownership, and rebuild proof expectations.
- `dev/architecture/system-architecture.md#memory--search` – current FTS5/QMD composition and file-to-derived-index flow.
- `dev/architecture/system-architecture.md#context-research-synthesis` – current three-layer retrieval and citation assembly flow.
- `dev/architecture/data-model.md#memory-chunk-search-index` – current generic source/category row shape that must gain canonical identity without becoming authoritative.

## Acceptance Scenarios

- [x] **S01 [OC01] [TI02,TI03] Ordinary punctuation reaches each selected backend unchanged and has one cross-caller result-set contract**
  - **Given** owner memory containing `C++`, `project "Falcon"`, `AND`, `status?`, a hyphenated phrase, and Swedish text, plus matching and nonmatching wiki pages
  - **When** `memory_search`, Knowledge Hub, and Context Research search for `project "Falcon" AND status?` through FTS5 and through QMD's documented fallback path
  - **Then** each caller passes the same trimmed natural-language text to its selected retrievers, only FTS5/QMD/wiki adapters encode their own syntax, and callers expose the same qualifying canonical set subject only to documented ranking and limits
  - **Proof**: `packages/dartclaw_server/test/memory_handlers_test.dart#onSearch handles FTS5 operator chars safely` – green – parity/regression for punctuation safety at the MCP boundary

- [x] **S02 [OC02] [TI01,TI03,TI05] Same-text sources remain distinct and each role-discriminated locator resolves only through its canonical owner**
  - **Given** two personal entries with identical text but UUIDs `e907c4e7-0c55-43c0-95cd-ebf41c4f6721` and `64d29b95-1b87-42b0-b56c-afaa8e97d32e`, plus `wiki/falcon.md` with the same text
  - **When** any retrieval caller returns and resolves all three matches
  - **Then** the personal results retain separate `memory` layer references, canonical entry locators, roles, provenance, entry IDs, and revisions; the wiki result retains layer `wiki`, role `wiki`, locator `wiki/falcon.md`, and native provenance without personal-entry fields
  - **And** the resolver reads the canonical corpus or native wiki source to prove current identity/existence; neither derived chunk IDs nor `memory_save`, `archive`, `MEMORY.md`, or a result-set membership check are valid locator evidence
  - **Proof**: `packages/dartclaw_server/test/mcp/context_research_tool_test.dart#CXR-05 mixed valid and fabricated citations retain only resolvable source refs` – green – parity/regression for filtering unresolved references

- [x] **S03 [OC02] [TI01,TI03] Production search remains host-bound to the single owner even when content or caller hints name another user**
  - **Given** otherwise matching derived rows for `owner` and `other`, and a Context Research `scope` hint containing `other`
  - **When** MCP, Knowledge Hub, and Context Research search in the production single-user runtime
  - **Then** only `owner` results are returned, no model/UI payload can select `userId`, and the scope hint changes neither persistence scope nor locator resolution
  - **Proof**: `packages/dartclaw_storage/test/storage/memory_service_test.dart#search returns only chunks for the specified userId` – green – parity/regression for the underlying user filter

- [x] **S04 [OC03] [TI01,TI04] One request returns wiki synthesis once, ahead of same-topic personal memory, with native provenance intact**
  - **Given** more than 50 matching wiki and personal-memory candidates, a highest-precedence source-backed `llm-authored` wiki page at the last path the traversal in force admits, and an instrumented selected backend that can also observe the wiki file
  - **When** `memory_search` with its `limit` pinned to 50, Knowledge Hub, or Context Research performs one request
  - **Then** exactly one request-level owner traverses/composes wiki, ranks every candidate the traversal in force admits with the final comparator, and returns the best 50 for that pinned limit without stopping at the first 50 matches
  - **And** the late native wiki-path result occupies one slot ahead of raw personal memory, the source-backed provenance and untrusted-synthesis label survive, and no recursive second scan or QMD copy consumes another result/quota slot
  - **And** the QMD copy collapses into that wiki slot through path-normalized identity LOOKUP of its path against the already-admitted native row – the sanctioned mechanism – while a QMD hit matching no canonical or native row is returned with its native uncited locator and no canonical locator is manufactured from its path or text
  - **Proof**: `packages/dartclaw_storage/test/search/wiki_search_source_test.dart#source-backed llm-authored wiki result is labeled untrusted but still outranks raw memory` – green – parity/regression for precedence and provenance labeling
  - **Proof**: `packages/dartclaw_storage/test/search/qmd_search_backend_test.dart#wiki and QMD copies of the same page occupy one result slot` – green – parity/regression for duplicate suppression at its current backend-internal home; TI04 moves wiki composition out of `QmdSearchBackend`, so this proof relocates to the request composition seam's test with its assertions intact

- [x] **S05 [OC03] [TI02,TI03,TI04] A failed retrieval constituent remains visible while healthy constituents still return canonical results**
  - **Given** matching canonical sources and one injected failure at a time in QMD, FTS5 memory, wiki, KG, or inbox retrieval
  - **When** the applicable MCP, Knowledge Hub, or Context Research request completes
  - **Then** surviving results keep their roles, locators, ordering, and provenance; the exact failed constituent appears once in `degradedLayers` or the Hub equivalent; and a QMD-to-FTS5 fallback remains visibly `qmd`-degraded rather than looking fully healthy
  - **Proof**: `packages/dartclaw_server/test/mcp/context_research_tool_test.dart#S07 TI03 TI06 failed KG layer is reported while wiki and memory still synthesize` – green – parity/regression for partial-layer survival. The `S07 TI03 TI06` prefix is part of the existing test name, carried over from an earlier milestone's numbering; it does not refer to this FIS's scenario or task IDs
  - **Proof**: `packages/dartclaw_server/test/knowledge/knowledge_hub_service_test.dart#S06 isolates a failed KG query and keeps surviving layer results` – green – parity/regression for Hub failure isolation. The `S06` prefix is part of the existing test name from an earlier milestone's numbering, not this FIS's scenario S06

- [x] **S06 [OC02,OC04] [TI01,TI05,TI06] Live, migrated, pruned, archived, and rebuilt rows preserve one source identity**
  - **Given** a canonical personal entry with Unicode/CRLF Markdown, provenance, topic, UUID, revision, and owner scope
  - **When** it is indexed live, revised, migrated, pruned into archive, and reconstructed by a full rebuild
  - **Then** every phase uses the same normalization/chunking projection and yields the equivalent role, locator, provenance, user scope, entry identity/revision, and chunk boundaries for that canonical state
  - **And** search plus citation resolution reopen the same entry UUID after rebuild and after active-to-archive movement; derived row IDs and ranking scores may differ but source identity may not
  - **Proof**: `packages/dartclaw_server/test/memory_handlers_test.dart#onSave CRLF text produces the same exact rows live and after rebuild` – green – parity/regression for shared normalization and chunking
  - **Proof**: `apps/dartclaw_cli/test/commands/rebuild_index_command_test.dart#rebuild uses the live Markdown normalization and chunk boundaries` – green – parity/regression for live/rebuild row projection

- [x] **S07 [OC01,OC02] [TI02,TI03,TI05] Empty queries and invalid locators fail explicitly without syntax leakage or substitute identity**
  - **Given** a submitted empty/whitespace search, a missing UUID, a role/locator mismatch, and generic locators `memory_save`, `archive`, and `MEMORY.md`
  - **When** MCP, Knowledge Hub, Context Research, or the shared resolver handles the value
  - **Then** a submitted blank search returns the documented empty/no-sources outcome without invoking a backend, invalid locators return explicit unresolved/not-found state, and no caller substitutes a whole file, derived row, first match, or healthy-zero result
  - **And** an omitted Knowledge Hub query remains its existing bounded browse operation and is not treated as a submitted search
  - **Proof**: `packages/dartclaw_server/test/memory_handlers_test.dart#onSearch returns empty message for empty query` – green – parity/regression for the current empty-query boundary
  - **Proof**: `packages/dartclaw_server/test/mcp/context_research_tool_test.dart#S02 TI04 fabricated citation is flagged unattributed and resolver is reusable` – green – parity/regression for unresolved citation handling. The `S02 TI04` prefix is part of the existing test name from an earlier milestone's numbering, not this FIS's scenario S02 or task TI04

## Structural Criteria

- [x] Canonical Markdown remains authoritative; search rows, backend responses, result sets, and resolver caches are derived evidence only.
- [x] QMD gains no canonical-memory schema, locator parser, corpus rule, or new responsibility; native hybrid search and QMD deprecation/removal remain ADR-050/0.25 work.
- [x] No new package, database, daemon, scheduler, approval framework, or speculative provider/search abstraction is introduced.
- [x] Locator resolution proves current identity/existence only and never upgrades a cited statement into semantic truth.
- [x] Existing wiki/KG write policy and native source ownership remain unchanged.
- [x] The 50-result ceiling is output top-K only: every candidate the traversal in force admits reaches the final comparator, so filesystem order cannot exclude a later higher-ranked wiki result. Story S07 adds no admission ceiling of its own – story S10 later introduces the 1,000-file/64 MiB ceilings, and this criterion must hold unchanged once they are in force.

## Scope & Boundaries

### Work Areas

- Story S04's canonical derived-row and role/locator/provenance result values plus the `SearchBackend` contract
- FTS5, QMD fallback, and wiki query/ranking adapters, including removal of the optional `WikiSearchSource` that `Fts5SearchBackend` and `QmdSearchBackend` each embed and compose today
- MCP memory handlers, Context Research, Knowledge Hub, and citation-source resolution
- Live apply/observe, legacy migration, pruning, and offline rebuild index projection callers
- Shared storage/server/CLI contract and lifecycle fixtures

### What We're NOT Doing

- Native hybrid/vector search, embeddings, a new search package, or QMD schema/deprecation work – ADR-050 assigns these to 0.25.
- Fresh-sibling rebuild validation/swap, index-health persistence, deleted/corrupt startup recovery, or status clearing – story S08 owns recovery mechanics; this story owns source-identity parity consumed by them.
- New archive/wiki/topic/observation byte, file-count, or aggregate processing limits, including the traversal admission ceilings – story S10 owns resource boundaries.
- New dashboard design, status/count presentation, recovery UX, or final documentation convergence – stories S11/S12 own those surfaces.
- Wiki/KG mutation, synthesis policy, or autonomous stewardship – existing knowledge writers remain unchanged and richer policy stays in 0.27.

## Architecture Decision

**Approach**: Reuse story S04's canonical search result as the only derived identity, keep natural-language encoding inside each FTS5/QMD/wiki adapter, and give each top-level retrieval request exactly one composition owner that invokes personal-memory and wiki retrieval once before final ranking and citation assembly.
**Why this over alternatives**: Caller sanitization, result-local resolvers, duplicate recursive scans, or QMD-specific identity would recreate the drift this story removes and add transitional architecture.

## Technical Overview

The host binds `owner`, validates query/limit, and passes the same trimmed natural-language string to role-specific retrievers. FTS5 owns literal `MATCH` encoding; QMD owns only its existing request/fallback protocol; wiki owns its term matching. Each recursive retriever ranks every candidate its traversal admits; the request composition seam merges them once, applies the final comparator, selects the output top-K, keeps wiki precedence/provenance, and carries per-constituent degradation to MCP, Hub, and Context Research. The output ceiling never stops scanning at the first 50 matches. Story S07 introduces no admission ceiling – story S10 later adds the 1,000-file/64 MiB ceilings, and this composition is unchanged by them because it ranks whatever the traversal in force admitted.

Canonical index projection supplies role, locator, provenance, scope, and applicable entry metadata before storage. Search consumers never derive identity from chunk IDs, file labels, scores, or QMD paths; a normalized QMD path may only LOOK UP an already-canonical or native row, never mint a locator, and an unmatched QMD hit keeps its native uncited locator. The citation resolver reopens canonical entries in every canonical role – learnings included – through the corpus authority, and native wiki/KG/inbox sources through their own owners, independently of the current result set; failure leaves the reference unresolved/unattributed. The same projection feeds every live and rebuild writer.

## Code Patterns & External References

```text
# type | path#anchor | why needed (intent)
file | packages/dartclaw_config/lib/src/search_backend.dart#SearchBackend | Current backend boundary and user-scope seam; preserve until the planned 0.25 ownership move
file | packages/dartclaw_storage/lib/src/storage/memory_service.dart#MemoryService.indexRows | Existing shared live/rebuild normalization and chunking projection to evolve with canonical identity
file | packages/dartclaw_storage/lib/src/search/fts5_search_backend.dart#Fts5SearchBackend.search | Move lexical escaping here and preserve BM25 ordering; also the embedded optional `WikiSearchSource` composition to remove
file | packages/dartclaw_storage/lib/src/search/qmd_search_backend.dart#QmdSearchBackend.search | Preserve selected-backend/fallback behavior without adding locator semantics; also the embedded optional `WikiSearchSource` composition and its backend-internal wiki/QMD path dedupe to remove
file | packages/dartclaw_storage/lib/src/search/wiki_search_source.dart#WikiSearchSource.search | Native wiki path, provenance label, and ranking source
file | packages/dartclaw_server/lib/src/memory_handlers.dart#createMemoryHandlers | MCP search caller currently performing FTS-specific encoding
file | packages/dartclaw_server/lib/src/mcp/context_research_tool.dart#ContextResearchTool._retrieve | Current duplicate wiki traversal, layer degradation, candidate dedupe, and resolver assembly
file | packages/dartclaw_server/lib/src/knowledge/knowledge_hub_service.dart#KnowledgeHubService.search | Hub caller currently bypassing the configured backend for personal memory
file | packages/dartclaw_server/lib/src/mcp/citation_packet.dart#CitationSourceResolver | Shared existence resolver consumed by packets and UI attribution
file | apps/dartclaw_cli/lib/src/commands/rebuild_index_command.dart#RebuildIndexCommand.run | Offline full-rebuild caller that must consume the shared canonical projection
```

## Constraints & Gotchas

- **Backend-only encoding**: callers may trim and reject blank input but must not quote, strip, rewrite, expand, or interpret natural-language tokens; each role-specific backend owns its complete encoding.
- **Identity is role plus locator**: every canonical role – learnings included, since 0.24 makes learnings canonical rather than a native file source – uses canonical entry locators (stable entry UUIDs); wiki locators are normalized workspace-relative native paths, and KG locators remain fact IDs. File labels, categories, source strings, offsets, chunk IDs, scores, and `learnings.md`-style file or heading anchors are not identity.
- **Output count, stated once**: the returned count is `min(requested-or-surface-default, 50)`, selected only AFTER ranking every admitted candidate. `memory_search` defaults to 5 per request and clamps any supplied `limit` to `maxMemorySearchResults` (50); Knowledge Hub derives its bound from page size, and Context Research from its candidate limit. "Best 50" everywhere in this FIS names that hard output ceiling – never a guaranteed page size and never a scan cutoff.
- **Wiki provenance and precedence**: source-backed wiki synthesis stays ahead of same-topic raw personal memory but keeps its native provenance/trust label; rank every admitted candidate before selecting the output top-K so a late path cannot lose that precedence; precedence never promotes wiki into personal memory.
- **Single-owner scope**: model/UI inputs do not accept `userId`; production binds `owner` through every personal index query and resolver. Context Research `scope` remains a synthesis hint, not an authorization or tenancy selector.
- **Degradation is additive**: use existing layer wire names (`memory`, `wiki`, `kg`, `inbox`) and `qmd` for selected-QMD fallback; deduplicate labels without erasing surviving results or persistent index-health state owned by story S08.
- **QMD boundary**: consume S04's canonical result projection and existing FTS fallback. Path-normalized identity LOOKUP of a QMD hit against existing canonical/native rows is SANCTIONED and belongs to the request composition seam rather than to QMD – it is what recognizes a QMD hit as a copy of an already-indexed page. What stays BANNED is MANUFACTURING a locator from QMD path/text: a hit matching no existing row is returned with its native, uncited locator and never a synthesized canonical one, and an uncited result is never presented as a resolved citation.
- **Settled constraint – blank search**: an explicitly submitted empty/whitespace query produces an empty/no-sources response without backend work; Knowledge Hub's omitted-query browse remains distinct and bounded.

## Implementation Plan

### Implementation Tasks

- [x] **TI01** Derived rows and search results retain canonical role, locator, provenance, and owner identity
  - Extend story S04's result/projection seam at `packages/dartclaw_storage/lib/src/storage/memory_service.dart#MemoryService.indexRows`; personal rows carry canonical entry identity/revision while wiki keeps native fields, with no authoritative state added to `search.db`.
  - **Verify**: Scenarios S02, S03, and S06 pass; focused value/schema tests reject generic or role-mismatched locators, and architecture checks confirm canonical Markdown remains authoritative and that Structural Criterion 3 holds in full – no new package, database, daemon, scheduler, approval framework, or speculative provider/search abstraction.

- [x] **TI02** Every retrieval adapter accepts natural language and reports its own degraded outcome
  - Move all FTS5 encoding out of callers into `Fts5SearchBackend.search`; preserve QMD's existing request/fallback and wiki term handling while returning additive degradation metadata through the shared search outcome.
  - **Verify**: Scenarios S01, S05, and S07 pass through the shared punctuation/empty/failure matrix, including visible `qmd` fallback and no caller-specific sanitizer; a QMD surface scan finds no new canonical field, locator parser, or corpus rule.

- [x] **TI03** MCP, Knowledge Hub, and Context Research expose one owner-scoped search contract
  - Route the three production consumers through story S04's typed result/outcome seam, inject `owner`, preserve per-surface bounds, and map role/locator/provenance without deriving identity from source labels.
  - **Verify**: Scenarios S01–S03, S05, and S07 pass at handler/service level; captured calls prove identical raw queries and owner scope while returned canonical membership agrees across consumers.

- [x] **TI04** Wiki synthesis is composed once per request with precedence, provenance, and output top-K intact
  - Give each request one composition site around the selected personal backend plus `WikiSearchSource`. Remove wiki composition from every place that performs it today: the embedded optional `WikiSearchSource` in `Fts5SearchBackend.search`, the embedded optional `WikiSearchSource` and its backend-internal wiki/QMD path dedupe in `QmdSearchBackend.search`, and the backend-plus-direct recursive duplication in `ContextResearchTool._retrieve`. Wiki traversal, wiki/QMD duplicate collapse, and the final comparator then all live in that one request seam.
  - Rank every candidate the traversal in force admits before selecting the output top-K, and keep QMD copies from occupying a second slot. Story S10 later supplies the admission ceilings; story S07 supplies none.
  - Relocate the wiki/QMD duplicate-suppression proof with the behavior it proves: it is bound to `qmd_search_backend_test.dart` because the dedupe is backend-internal today, and it moves to the request composition seam's test with its assertions intact rather than being deleted. The `WikiSearchSource` unit proof stays where it is – that source is unchanged, only its callers move.
  - **Verify**: Scenarios S04 and S05 pass with an instrumented wiki source proving one traversal per request across all three callers and both backends, full ranking of every admitted candidate, inclusion of a highest-ranked late-path wiki result in the output top-K, native provenance, duplicate suppression from its relocated home, and surviving personal results on wiki failure; a backend surface scan finds no remaining `WikiSearchSource` reference in `Fts5SearchBackend` or `QmdSearchBackend`; no wiki/KG write contract changes.

- [x] **TI05** Citation resolution reopens canonical sources independently of retrieved candidates
  - Evolve `CitationSourceResolver` composition so canonical entry UUIDs from every canonical role – learnings included – resolve through the S01–S05 corpus authority and wiki/KG/inbox locators through their native owners; result membership alone never resolves a citation.
  - **Verify**: Scenarios S02, S06, and S07 pass through Context Research and Knowledge Hub attribution, including active/archive personal entries, native wiki paths, missing sources, layer mismatches, and the explicit existence-not-semantic-truth invariant.

- [x] **TI06** Every index lifecycle uses one canonical normalization, chunking, and identity projection
  - Make live apply/observe, story S03's migration, pruning, and `RebuildIndexCommand.run` consume TI01's projection for the complete supported canonical union; story S08 may change rebuild transport/health but not row identity.
  - **Verify**: Scenario S06 passes by comparing complete logical rows after each lifecycle and full rebuild while allowing only derived row IDs/scores to differ; existing rebuild, pruner, migration, and canonical mutation suites remain green.

### Testing Strategy

- [TI01,TI02,TI03] Use one table-driven contract corpus across the MCP handler, Hub service, Context Research, real in-memory FTS5, and QMD/wiki fakes. Capture raw query and host scope before adapter encoding; compare canonical membership rather than engine-specific score order.
- [TI04,TI05] Inject counting/throwing retrievers and real temp-workspace canonical files. Assert exact traversal count across both backends and all three callers, late-path high-rank retention after output top-K selection, per-layer degradation, role/locator resolver dispatch, and unattributed behavior without using result membership as the resolver fixture.
- [TI06] Build one fixed canonical lifecycle fixture through live mutation, story S03's migration, pruning/archive, and CLI-equivalent full projection; compare role, locator, provenance, entry metadata, owner scope, normalized text, and chunk ordinal while ignoring disposable SQLite IDs/rank.

## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Tag semantics: see the AndThen FIS mutability contract. Spec authors leave this section empty._

#### DECISION NOTE: qmd-identity-lookup-sanction

Decision-Key: qmd-identity-lookup-sanction
Altitude: fis-local
Affected surface: Technical Overview (derived-identity sentence, 2nd paragraph); Constraints & Gotchas ("QMD boundary" bullet); Acceptance Scenario S04 (second **And** bullet)
Decision: Path-normalized identity LOOKUP of a QMD hit against existing canonical/native rows is explicitly SANCTIONED and lives in the request composition seam (TI04), not inside QMD – it is the mechanism that recognizes a QMD hit as a copy of an already-indexed page. What remains BANNED is MANUFACTURING a canonical locator from QMD path or text: a QMD hit that matches no existing row is returned with its native, uncited locator rather than being dropped or given a synthesized canonical one, and an uncited result is never presented as a resolved citation.
Rationale: Scenario S04 requires a QMD copy of a wiki page to collapse into the wiki slot, which is impossible without the lookup, while the FIS's "cannot escape as a cited result" wording banned the lookup and the uncited passthrough alike – a self-contradiction against its own duplicate-suppression proof. The owner ratified the lookup/manufacture split as the settled boundary.
Evidence: Scenario S04 proof `packages/dartclaw_storage/test/search/qmd_search_backend_test.dart#wiki and QMD copies of the same page occupy one result slot` requires cross-source identity matching; Structural Criterion 2 ("QMD gains no ... locator parser") stays satisfied because the lookup is owned by the composition seam named in TI04, not by QMD.

Old:
```
Search consumers never derive identity from chunk IDs, file labels, scores, or QMD paths.
```
New:
```
Search consumers never derive identity from chunk IDs, file labels, scores, or QMD paths; a normalized QMD path may only LOOK UP an already-canonical or native row, never mint a locator, and an unmatched QMD hit keeps its native uncited locator.
```

Old:
```
- **QMD boundary**: consume S04's canonical result projection and existing FTS fallback; never manufacture a locator from QMD path/text. A result that cannot satisfy canonical locator validation cannot escape as a cited result.
```
New:
```
- **QMD boundary**: consume S04's canonical result projection and existing FTS fallback. Path-normalized identity LOOKUP of a QMD hit against existing canonical/native rows is SANCTIONED and belongs to the request composition seam rather than to QMD – it is what recognizes a QMD hit as a copy of an already-indexed page. What stays BANNED is MANUFACTURING a locator from QMD path/text: a hit matching no existing row is returned with its native, uncited locator and never a synthesized canonical one, and an uncited result is never presented as a resolved citation.
```

Old:
```
  - **And** the late native wiki-path result occupies one slot ahead of raw personal memory, the source-backed provenance and untrusted-synthesis label survive, and no recursive second scan or QMD copy consumes another result/quota slot
```
New:
```
  - **And** the late native wiki-path result occupies one slot ahead of raw personal memory, the source-backed provenance and untrusted-synthesis label survive, and no recursive second scan or QMD copy consumes another result/quota slot
  - **And** the QMD copy collapses into that wiki slot through path-normalized identity LOOKUP of its path against the already-admitted native row – the sanctioned mechanism – while a QMD hit matching no canonical or native row is returned with its native uncited locator and no canonical locator is manufactured from its path or text
```

#### DECISION NOTE: learnings-canonical-role

Decision-Key: learnings-canonical-role
Altitude: fis-local
Affected surface: Constraints & Gotchas ("Identity is role plus locator" bullet); Technical Overview (citation-resolver sentence, 2nd paragraph); Implementation Tasks TI05 (resolver-composition step)
Decision: Runtime learnings are a CANONICAL ROLE in the 0.24 memory model, so a retrieved learning carries the ordinary canonical entry locator (stable entry UUID) and resolves through the canonical corpus authority – never a `learnings.md` file path, heading anchor, or native-source owner. Only wiki, KG, and inbox remain native-identity sources in S07; every canonical role, learnings included, is addressed by canonical entry locator.
Rationale: The cross-cutting 0.24 decision supersedes the earlier "learnings retain their native format and identity" premise, which S01 replaced with stable identity, validation, revision, and fingerprint participation. S07 never named learnings at all: its identity contract enumerated only personal-memory/wiki/KG and its resolver dispatch only personal UUIDs vs wiki/KG/inbox, leaving learnings unassigned and inviting a file-level locator implementation that the ratified model forbids.
Evidence: A full-text search of this FIS for "learn" returns no hit, so no explicit native-identity claim existed to delete – the correction is enumerative, closing the gap in the three surfaces that partition canonical-locator sources from native-identity sources.

Old:
```
- **Identity is role plus locator**: personal-memory locators are canonical entry UUIDs, wiki locators are normalized workspace-relative native paths, and KG locators remain fact IDs. File labels, categories, source strings, offsets, chunk IDs, and scores are not identity.
```
New:
```
- **Identity is role plus locator**: every canonical role – learnings included, since 0.24 makes learnings canonical rather than a native file source – uses canonical entry locators (stable entry UUIDs); wiki locators are normalized workspace-relative native paths, and KG locators remain fact IDs. File labels, categories, source strings, offsets, chunk IDs, scores, and `learnings.md`-style file or heading anchors are not identity.
```

Old:
```
The citation resolver reopens canonical personal entries and native wiki/KG/inbox sources independently of the current result set; failure leaves the reference unresolved/unattributed.
```
New:
```
The citation resolver reopens canonical entries in every canonical role – learnings included – through the corpus authority, and native wiki/KG/inbox sources through their own owners, independently of the current result set; failure leaves the reference unresolved/unattributed.
```

Old:
```
  - Evolve `CitationSourceResolver` composition so personal UUIDs resolve through the S01–S05 corpus authority and wiki/KG/inbox locators through their native owners; result membership alone never resolves a citation.
```
New:
```
  - Evolve `CitationSourceResolver` composition so canonical entry UUIDs from every canonical role – learnings included – resolve through the S01–S05 corpus authority and wiki/KG/inbox locators through their native owners; result membership alone never resolves a citation.
```
