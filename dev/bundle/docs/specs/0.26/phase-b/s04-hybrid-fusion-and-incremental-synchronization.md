# FIS: Hybrid Fusion and Incremental Synchronization

**Plan**: dev/bundle/docs/specs/0.26/phase-b/plan.json
**Story-ID**: S04

_Authored against public `3396754b6501` on `feat/0.26`; commands and `packages/...` paths run from
`../dartclaw-public/`. S01 is the accepted prerequisite contract._

## Feature Overview and Goal

**Intent**: Make semantic retrieval useful without letting optional vector work weaken the current lexical source,
owner boundary or canonical memory and conversation identities.

**Expected Outcomes**:

- [OC01] Memory and conversation searches independently return current owner-scoped results fused from keyword and
  semantic candidates, while an unavailable vector path retains the existing lexical behavior.
- [OC02] Incremental updates and full rebuilds reuse matching vectors, retire obsolete content and never publish a
  delayed embedding for source text that changed or disappeared while it was computed.
- [OC03] Opted-in callers can inspect constituent ranks, fixed weighted contributions, degradation and each corpus's
  current unembedded count without changing ordinary search result shapes.

## Pinned Consumer API

S05 wires these exact public surfaces; S06 and S08 consume their diagnostics and counts without another ranker or
inventory implementation:

```dart
final class HybridSearch {
  new({
    required FullTextIndex lexicalIndex,
    required VectorIndex vectorIndex,
    required EmbeddingProvider embeddingProvider,
    required String sourceLayer,
  });

  Future<List<SearchResult>> search(
    String query, {
    required String userId,
    int limit = 20,
    SearchDiagnosticsSink? diagnostics,
  });

  Future<int> missingCount({required String userId});
}

final class VectorSynchronizationResult {
  new({
    required this.embeddedCount,
    required this.reusedCount,
    required this.retiredCount,
    required this.unembeddedCount,
    Iterable<MemorySearchDegradation> degradations = const [],
  }) : degradations = List.unmodifiable(degradations);

  final int embeddedCount;
  final int reusedCount;
  final int retiredCount;
  final int unembeddedCount;
  final List<MemorySearchDegradation> degradations;
}

final class VectorSynchronizer {
  new({
    required FullTextIndex lexicalIndex,
    required VectorIndex vectorIndex,
    required EmbeddingProvider embeddingProvider,
    required String sourceLayer,
  });

  Future<VectorSynchronizationResult> synchronize(
    Iterable<String> documentIds, {
    required String userId,
  });

  Future<VectorSynchronizationResult> rebuild({required String userId});

  Future<int> missingCount({required String userId});
}

final class HybridSearchBackend implements SearchBackend {
  new({
    required HybridSearch search,
    required MemorySearchResult Function(SearchResult result) toMemoryResult,
  });
}
```

`sourceLayer` accepts only `memory` or `conversation`. Counts are non-negative and collections are immutable.
`HybridSearchBackend` applies the existing memory-layer selector, obtains degradation through an internal diagnostic
sink, maps solely through `toMemoryResult`, returns `null` from `resolve`, and keeps `indexAfterWrite` a no-op. S05
injects `MemoryIndexProjection.toSearchResult`; conversation search keeps its existing service-level mapping. A
successful fusion returns best-first results by descending positive weighted `fusedScore`, but stores
`SearchResult.score = -fusedScore` for the existing lower-is-better `ComposedSearchBackend`. Diagnostic ranks,
contributions and `fusedScore` remain positive. Pure lexical fallback returns the lexical results with their original
scores and order. Neither `HybridSearchBackend` nor either canonical mapper negates or otherwise rewrites the score.

## Required Context

- `docs/specs/0.26/phase-b/s01-search-contracts-and-canonical-chunk-identities.md#pinned-contract-surface` – exact
  `SearchResult`, vector, embedding and diagnostics ports this story must consume unchanged.
- `docs/specs/0.26/phase-b/plan.json#sharedDecisions` – package boundary, source authentication, synchronization
  ownership, fixed ranking and diagnostics decisions shared with S05/S06/S08.
- `docs/specs/0.26/phase-b/prd.md#fr1-hybrid-retrieval-for-two-corpora` – independent owner/corpus ranking, stable
  identity, empty-query behavior and lexical degradation.
- `docs/specs/0.26/phase-b/prd.md#fr3-incremental-projection-and-recovery` – content/fingerprint reuse, stale
  retirement, delayed-result safety, complete rebuild and per-corpus missing counts.
- `docs/specs/0.26/phase-b/prd.md#fr4-backend-vector-storage-and-compatibility` – owner isolation and atomic vector
  mutation semantics supplied by S02's injected implementations.
- `docs/specs/0.26/phase-b/prd.md#fr5-retrieval-diagnostics-and-turn-provenance` – opt-in constituent evidence and
  compact ordinary output; trace persistence remains outside this story.
- `docs/specs/0.26/phase-b/prd.md#fr6-native-distribution-and-failure-handling` – authorized search-package edge and
  provider-failure boundary; provider lifecycle and platform proof remain with S03 and final verification.
- `docs/specs/0.26/phase-b/prd.md#fr7-sealed-retrieval-evaluation` – frozen candidate and ranking semantics that the
  later held-out runner must exercise without retuning.
- `docs/specs/0.26/phase-b/selected-settings.json#rrfK` – frozen k, weights, cosine cutoff and candidate limit.
- `docs/specs/0.26/phase-b/implementation-context.md#constraints-for-hybrid-injection-across-both-corpora` – current
  memory post-commit, conversation queue, rebuild and source-health boundaries S05 must retain.
- `../dartclaw-public/dev/state/PRODUCT.md#proportionality` – prototype scale and one-authority constraints exclude
  a scheduler, persistence queue, global vector store or parallel content authority.
- `../dartclaw-public/dev/adrs/050-native-hybrid-search.md#decision` – accepted injected-port package, weighted RRF
  and derived/rebuildable vector posture.
- `../dartclaw-public/dev/adrs/056-package-topology-consolidation.md#decision` – current dependency tiers that keep
  search independent from core, runtime and concrete drivers.

## Deeper Context

- `docs/specs/0.26/phase-b/calibration-summary.md#rrf-candidates` – calibration evidence behind the frozen cutoff
  and vector-favoring weight pair; it is not a tuning input during implementation.
- `../dartclaw-public/dev/architecture/data-model.md#derived-memory-index-document` – canonical memory projection and
  rebuild authority that hybrid search must not duplicate.
- `../dartclaw-public/dev/architecture/data-model.md#derived-conversation-index-row` – persisted message identity,
  metadata and lifecycle retained by the conversation service.
- `../dartclaw-public/dev/guidelines/TESTING-STRATEGY.md#applying-this-strategy-to-new-features` – pure logic tests with
  real collaborators and fakes only at injected external ports.

## Acceptance Scenarios

- **S01 [OC01,OC03] [TI01] Fixed weighted RRF fuses current keyword and authenticated vector candidates**
  - **Given** keyword-only, vector-only and shared `(documentId, chunkIndex)` candidates for one user and corpus
  - **When** `HybridSearch.search` queries both constituents
  - **Then** each constituent contributes at most 20 best-first candidates; vector scores below 0.20 are excluded;
    remaining candidates use `0.25 / (60 + keywordRank)` plus `0.75 / (60 + vectorRank)` with one-based ranks; final
    results preserve current lexical text, metadata, timestamp and ordinal, deduplicate by identity and take the
    requested limit by descending fused score, then ascending present-before-absent keyword rank, vector rank,
    document ID and ordinal; each successful result score is the negative of its positive fused score while diagnostic
    contributions and fused score retain their positive values

- **S02 [OC01,OC03] [TI01] Empty or unavailable semantic input preserves the appropriate lexical outcome**
  - **Given** an empty query, or a non-empty query whose provider throws or yields no valid finite query vector, or
    whose vector index fails
  - **When** hybrid search runs
  - **Then** an empty query returns no results and performs no constituent or embedding work; every other case returns
    the lexical candidates with their existing scores and order, without negation or a fabricated vector rank, and
    reports the typed vector degradation only when a diagnostic sink was supplied; failure of the initial lexical
    search still propagates to the existing memory health or conversation-service boundary instead of returning
    vector-only results

- **S03 [OC01,OC02,OC03] [TI01] Stale vector storage cannot surface deleted or superseded text**
  - **Given** vector deletion failed, or a vector match names a missing chunk, wrong current hash or prior fingerprint
  - **When** a query returns that stored match after the lexical source changed
  - **Then** hybrid search fetches the current owner-scoped lexical document and excludes the match before fusion;
    diagnostics report the omitted stale count without source text or vectors, even when the stale identity would
    otherwise rank first

- **S04 [OC02,OC03] [TI02] Incremental synchronization reuses current vectors and atomically retires obsolete ones**
  - **Given** affected document IDs cover unchanged chunks, changed hashes, removed ordinals, deleted documents and a
    new model fingerprint
  - **When** `VectorSynchronizer.synchronize` reads their current lexical documents
  - **Then** matching identity/hash/fingerprint records cause zero embedding calls; missing current chunks are embedded
    in source order; stale identities retire in the same `VectorIndex.upsert` call that publishes authenticated new
    records; provider failure still retires authenticated stale identities and reports current unembedded count

- **S05 [OC02,OC03] [TI02] Full rebuild authenticates the complete lexical corpus and retains reusable vectors**
  - **Given** a current lexical corpus and a separately retained vector store containing reusable, stale and
    wrong-fingerprint records, including an empty lexical corpus
  - **When** `VectorSynchronizer.rebuild` enumerates all current lexical documents
  - **Then** it embeds only chunks lacking an exact identity/hash/fingerprint record, rechecks the complete lexical
    identity/hash inventory after delayed work, and atomically `replaceAll`s only current authenticated records; an
    empty corpus clears vectors, while incomplete or changed source authentication publishes nothing

- **S06 [OC01,OC03] [TI01,TI02] Diagnostics and memory adaptation remain opt-in and corpus-specific**
  - **Given** independent memory and conversation instances with different missing counts and the canonical memory
    conversion function
  - **When** callers use `missingCount`, request search diagnostics, or query through `HybridSearchBackend`
  - **Then** each instance reports only its own current chunks; evidence uses the exact `memory` or `conversation`
    layer and nullable constituent ranks; an omitted sink receives no diagnostic callback and does not alter
    `SearchResult`; the adapter returns mapped `MemorySearchOutcome` results and degradations without another memory
    mapper or a second score negation

## Structural Criteria

- **SC01** S04 production code lives in `dartclaw_search`, depends on `dartclaw_kernel` plus `crypto` only, and imports
  neither core nor concrete SQLite/PostgreSQL/provider code.
- **SC02** RRF k=60, keyword weight 0.25, vector weight 0.75, cosine cutoff 0.20 and per-constituent candidate limit 20
  are internal constants with no constructor/configuration override.
- **SC03** One package-private current-corpus inventory owns UTF-8 SHA-256 chunk hashing, fingerprint eligibility,
  lexical authentication and missing-count calculation for both `HybridSearch` and `VectorSynchronizer`.
- **SC04** Existing `MemoryIndexProjection`, `ConversationSearchService` and `ConversationIndexer` remain the sole
  mapper/service/lifecycle owners; S04 adds no transcript reader, mutation queue, persistence layer or global store.

## Scope & Boundaries

### Work Areas

- `dartclaw_search` hybrid fusion and diagnostic surface.
- `dartclaw_search` current lexical inventory, hashing and vector synchronization.
- Kernel-only `HybridSearchBackend` adapter and package barrel exports.
- Focused pure tests using injected lexical, vector and embedding ports.

### What We're NOT Doing

- Concrete SQLite/PostgreSQL vector storage or schema work – S02 supplies injected `VectorIndex` implementations.
- Native/HTTP provider implementation, model lifecycle or artifact handling – S03 supplies injected providers.
- Runtime lifecycle attachment, configuration and shutdown wiring – S05 composes these surfaces at the current owners.
- Runtime status payload – S05 exposes the counts; turn-trace persistence and operator inspection/CLI output – S06
  consumes diagnostics and counts.
- Held-out/live backend/platform evaluation or ranking changes – S08 and the final combined A+B gate execute the
  frozen settings; this story does not open held-out data.

## Architecture Decision

**Approach**: Keep fusion and source-derived vector reconciliation as stateless, corpus-neutral services over S01's
kernel ports, with a small kernel-only memory adapter receiving the canonical mapper by injection.
**Why this over alternatives**: Reading the current lexical index makes it the authentication authority for both
publication and retrieval; implicit mutation hooks or a second corpus mapper would lose lifecycle context and create
competing ownership.

## Technical Overview

Each corpus receives its own `FullTextIndex`, `VectorIndex`, `HybridSearch` and `VectorSynchronizer` instances under
the same owner ID. Fusion obtains lexical candidates first, embeds the query, authenticates vector candidates by
fetching current lexical documents and hashes, then emits deterministic RRF results in descending positive fusion
order with the negative fused score stored on each result for lower-is-better composition. Synchronization derives
the desired vector set from current lexical documents, reuses exact records, embeds the delta and re-authenticates
before one atomic vector mutation. The two public missing-count methods delegate to the same private inventory logic.

## Code Patterns & External References

```text
# type | path#anchor | why needed
file | ../dartclaw-public/packages/dartclaw_kernel/lib/src/full_text_index.dart#FullTextIndex | current lexical source and owner-scoped enumeration/fetch contract
file | ../dartclaw-public/packages/dartclaw_core/lib/src/search/fts5_search_backend.dart#Fts5SearchBackend | thin SearchBackend adaptation and layer-filter behavior
file | ../dartclaw-public/packages/dartclaw_core/lib/src/memory/memory_index_projection.dart#MemoryIndexProjection.toSearchResult | sole canonical memory conversion injected by S05
file | ../dartclaw-public/packages/dartclaw_core/lib/src/search/conversation_search_service.dart#ConversationSearchService.search | existing conversation query boundary and result mapping
file | ../dartclaw-public/packages/dartclaw_core/lib/src/search/conversation_indexer.dart#ConversationIndexer | serialized lifecycle owner used by S05
file | docs/specs/0.26/phase-b/s01-search-contracts-and-canonical-chunk-identities.md#Pinned Contract Surface | prerequisite vector and diagnostic signatures
```

## Constraints & Gotchas

- SHA-256 covers the exact UTF-8 bytes of one `SearchDocument.chunks[chunkIndex]`; metadata and timestamps do not
  enter the content hash. Identity remains `(userId, corpus instance, documentId, chunkIndex)`.
- `missingCount` enumerates current lexical chunks and counts those without an exact current identity, content hash
  and provider fingerprint. If vector enumeration is unavailable, every authenticated current chunk is missing.
- A vector candidate is eligible only when its score is at least 0.20 and a current owner-scoped lexical fetch has the
  same identity/hash. Vector-store deletion is never trusted as source authentication.
- Incremental synchronization receives only affected document IDs after the caller's lexical mutation. It fetches
  current documents itself, so the same method handles upsert, changed chunk count and deletion. S05 owns ordering and
  queue attachment; S04 creates no background work.
- Full reconciliation reads reusable records from S02's retained corpus-specific vector store. On SQLite that is the
  separate `vectors.db`, which survives atomic `search.db` republication; S04 owns neither path nor publication.
- Delayed incremental work re-fetches all affected IDs; rebuild repeats the complete ordered identity/hash inventory.
  Any mismatch refuses that publication rather than retrying or merging snapshots.
- Provider failures are converted to `MemorySearchDegradation(layer: sourceLayer, reason: 'embeddingFailure')` and
  leave current chunks missing. Query vector-store failure uses `vectorSearchFailure`; rejected stored matches use
  `staleVector` with `omittedCount`; failure to fetch current documents rejects all vector candidates and uses
  `vectorAuthenticationFailure`; a changed pre-publication inventory uses `sourceChanged`. Do not expose exception
  text, source content or vectors through diagnostics.
- Search validates non-empty `userId`, positive `limit` and `sourceLayer`; it never accepts ranking knobs. Keyword
  candidates keep backend order, and lexical failure remains owned by the existing caller boundary. Negate only a
  successful positive fused score when constructing `SearchResult`; never negate diagnostic evidence, pure lexical
  fallback, the canonical mapper or the `HybridSearchBackend` adapter.

## Implementation Plan

### Implementation Tasks

- **TI01** Hybrid queries return authenticated deterministic fusion through the existing memory boundary
  - Implement the pinned `HybridSearch` and `HybridSearchBackend` surfaces using S01 contracts and the injected
    canonical converter; keep diagnostics opt-in and all ranking settings internal constants.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_search/test/hybrid_search_test.dart` – pure port-backed cases prove every S01–S03 and S06 clause, including descending positive fusion order with negative result scores, positive diagnostic evidence, unchanged lexical fallback scores/order, stale-hit rejection, layer selection, single-pass injected mapping and absent-sink behavior
  - **SATISFIES**: S01, S02, S03, S06, SC01, SC02, SC04

- **TI02** Vector state reconciles to authenticated current lexical chunks without redundant embedding
  - Implement the pinned synchronizer/result and one shared private inventory/hash path used by both public
    `missingCount` methods; incremental and rebuild publication must use the atomic S01 vector calls.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_search/test/vector_synchronizer_test.dart && dart analyze --fatal-infos packages/dartclaw_search && dart run dev/tools/arch_check.dart` – pure race/failure fixtures prove every S04–S06 synchronization/count clause, exact reuse and retirement, empty rebuild, no late publication, public API compilation and the kernel-only dependency edge
  - **SATISFIES**: S04, S05, S06, SC01, SC03, SC04

### Testing Strategy

- Use deterministic in-memory port implementations that record only observable embedding and atomic vector calls.
  Write source documents directly so tests exercise inventory/hash logic rather than generating expectations through
  the code under test. No native model, database, held-out fixture, timer, network or runtime wiring belongs here.

## Implementation Observations

### Run: 2026-09-10 08:42 UTC – observations

#### DRIFT

- Review R-01 reconciles the diagnostic contract with empty-query no-work and inspection completeness requirements: `SearchDiagnostics.unembeddedCount` is `int?`, defaults to `null`, and validates non-negative values when present. Null means the count was not computed or could not be computed; it must not be coerced to zero. Hybrid fallback results and degradations remain available. Inspection returns its existing 503 response when the count is null, so successful HTTP diagnostics retain an integer count. `VectorSynchronizationResult.unembeddedCount` remains a required integer. See `../0.26-mixed-review-2026-09-10.md` for review and verification evidence.
