# FIS: Search Contracts and Canonical Chunk Identities

**Plan**: dev/bundle/docs/specs/0.26/phase-b/plan.json
**Story-ID**: S01

_Authored against public `3396754b6501` on `feat/0.26`; commands and `packages/...` paths run from
`../dartclaw-public/`._

## Feature Overview and Goal

**Intent**: Give lexical, vector, embedding and fusion implementations one owner-scoped identity contract so hybrid
search can be built in parallel without creating a second memory mapper or losing canonical provenance.

**Expected Outcomes**:

- [OC01] Memory and conversation chunks have stable `(documentId, chunkIndex)` identities across lexical results,
  vector projection and rebuild, independent of backend row IDs or matching text.
- [OC02] Backend and provider implementations share validated, owner-scoped ports for current-fingerprint vector
  search, atomic mutation, reconciliation enumeration and query/batch embedding.
- [OC03] Canonical memory text is split deterministically by headings and paragraphs without splitting fenced code,
  while existing corpus membership, document IDs, metadata, timestamps and source order remain intact.
- [OC04] An opted-in caller can inspect content-free keyword/vector ranks, weighted contributions, fused scores,
  source layer, unembedded count and structured degradation causes without changing normal result payloads.

## Pinned Contract Surface

These signatures are fixed inputs to S02, S03 and S04:

```dart
final class VectorIdentity {
  new({required this.documentId, required this.chunkIndex});

  final String documentId;
  final int chunkIndex;
}

final class VectorRecord {
  new({
    required this.documentId,
    required this.chunkIndex,
    required this.contentHash,
    required this.modelFingerprint,
    required List<double> vector,
  });

  final String documentId;
  final int chunkIndex;
  final String contentHash;
  final String modelFingerprint;
  final List<double> vector;
}

final class VectorMatch {
  new({
    required this.documentId,
    required this.chunkIndex,
    required this.contentHash,
    required this.score,
  });

  final String documentId;
  final int chunkIndex;
  final String contentHash;
  final double score;
}

abstract interface class VectorIndex {
  Future<List<VectorMatch>> search(
    List<double> queryVector, {
    required String userId,
    required String modelFingerprint,
    int limit = 20,
  });

  Future<List<VectorRecord>> list({required String userId});

  Future<void> upsert(
    Iterable<VectorRecord> records, {
    required String userId,
    Set<VectorIdentity> retire = const {},
  });

  Future<void> delete(Iterable<VectorIdentity> identities, {required String userId});

  Future<void> replaceAll(Iterable<VectorRecord> records, {required String userId});
}

abstract interface class EmbeddingProvider {
  String get modelFingerprint;

  Future<List<double>> embedQuery(String query);

  Future<List<List<double>>> embedDocuments(List<String> documents);

  Future<void> dispose();
}

final class SearchRankEvidence {
  new({
    required this.documentId,
    required this.chunkIndex,
    required this.keywordRank,
    required this.vectorRank,
    required this.keywordContribution,
    required this.vectorContribution,
    required this.fusedScore,
    required this.sourceLayer,
  });

  final String documentId;
  final int chunkIndex;
  final int? keywordRank;
  final int? vectorRank;
  final double keywordContribution;
  final double vectorContribution;
  final double fusedScore;
  final String sourceLayer;
}

final class SearchDiagnostics {
  new({
    required Iterable<SearchRankEvidence> candidates,
    this.unembeddedCount = 0,
    Iterable<MemorySearchDegradation> degradations = const [],
  });

  final List<SearchRankEvidence> candidates;
  final int unembeddedCount;
  final List<MemorySearchDegradation> degradations;
}

typedef SearchDiagnosticsSink = void Function(SearchDiagnostics diagnostics);
```

`VectorIdentity` has `documentId` and zero-based `chunkIndex`. `VectorRecord` has those fields plus `contentHash`,
`modelFingerprint` and an immutable, non-empty finite `List<double> vector`. `VectorMatch` has the same identity and
`contentHash` plus a finite backend-native `score`. Identity and record are value types. `SearchResult` gains a
required, non-negative `chunkIndex`.

`SearchRankEvidence` has `documentId`, `chunkIndex`, nullable one-based `keywordRank` and `vectorRank`,
`keywordContribution`, `vectorContribution`, `fusedScore`, and non-empty `sourceLayer`. An absent rank has zero
contribution; at least one rank is present; all contributions and scores are finite and non-negative; `fusedScore`
is their sum. `SearchDiagnostics` has immutable `candidates`, non-negative `unembeddedCount`, and immutable
`List<MemorySearchDegradation> degradations`. `SearchDiagnosticsSink` is
`void Function(SearchDiagnostics diagnostics)`. The memory and conversation adapters inject the exact
`sourceLayer` values `memory` and `conversation`; an omitted sink requests no diagnostic result.

## Required Context

- `docs/specs/0.26/phase-b/plan.json#sharedDecisions` – package ownership, one projection/synchronization owner,
  diagnostics, and final-verification ownership shared by dependent stories.
- `docs/specs/0.26/phase-b/prd.md#fr1-hybrid-retrieval-for-two-corpora` – owner/corpus isolation, identity-led
  fusion, empty-query behavior, finite-vector validation and lexical fallback.
- `docs/specs/0.26/phase-b/prd.md#fr3-incremental-projection-and-recovery` – canonical membership, deterministic
  heading/fence-safe chunks, content hashes, fingerprints, recovery counts and stale-vector retirement.
- `docs/specs/0.26/phase-b/prd.md#fr6-native-distribution-and-failure-handling` – the authorized package boundary,
  one binary shape and bounded native lifecycle obligations deferred to provider/final verification.
- `docs/specs/0.26/phase-b/implementation-context.md#retrieval-contracts-and-composition` – landed ports, mapper,
  corpus adapters and composition seams at the Phase A checkpoint.
- `../dartclaw-public/dev/state/PRODUCT.md#proportionality` – prototype scale and the bans on duplicate storage
  authority, speculative machinery and distributed execution.
- `../dartclaw-public/dev/adrs/050-native-hybrid-search.md#decision` – accepted `dartclaw_search`, injected concrete
  indexes/providers, single chunking owner and derived/rebuildable posture.
- `../dartclaw-public/dev/adrs/056-package-topology-consolidation.md#amendment-2026-08-22--the-tier-order-replaces-the-per-edge-tables`
  – current tier authority and package-count ceiling that require an explicit amendment.

## Deeper Context

- `../dartclaw-public/dev/guidelines/DART-EFFECTIVE-GUIDELINES.md#design-api-design` – exported value types,
  interface shape, constructor validation and dartdoc conventions.
- `../dartclaw-public/dev/guidelines/DART-PACKAGE-GUIDELINES.md#package-structure` – the lean package scaffold and
  explicit barrel-export rules.
- `../dartclaw-public/dev/guidelines/TESTING-STRATEGY.md#public-api-contracts` – shared contract tests for ports with
  multiple implementations and barrel smoke coverage.
- `../dartclaw-public/dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md#testing-unit-integration-e2e` – the fast-tier and
  run-one-test commands this story must keep accurate.

## Acceptance Scenarios

- **S01 [OC01,OC02] [TI01] Vector ports require owner scope and complete reconciliation identity**
  - **Given** equal document IDs and ordinals can exist under different owners and model fingerprints
  - **When** a concrete implementation supplies `list`, current-fingerprint `search`, `upsert(retire:)`, `delete`,
    and `replaceAll`
  - **Then** every operation requires `userId`; search also requires `modelFingerprint`; mutations accept their whole
    atomic batch in one call; enumeration exposes identity/hash/fingerprint. S02 must run this contract against both
    concrete stores to prove isolation, atomicity, fingerprint/dimension filtering and stale-record retirement

- **S02 [OC02] [TI01] Invalid vector values fail before storage or ranking**
  - **Given** an empty vector, a NaN/infinite component, an empty identity/hash/fingerprint, a negative ordinal, an
    invalid limit, or a query dimension different from a candidate record
  - **When** the responsible value constructor or `VectorIndex` operation receives it
  - **Then** it throws `ArgumentError`; a dimension-mismatched stored candidate is excluded rather than compared

- **S03 [OC02] [TI01] Query and batch embedding have distinct result contracts**
  - **Given** one query and an ordered document batch, including an empty batch
  - **When** an `EmbeddingProvider` embeds them
  - **Then** the interface and dartdoc require query embedding through `embedQuery`; batch output preserves input
    count/order and is empty for empty input; every output is finite, non-empty and one dimension for the fingerprint.
    S03 must run this contract against each concrete provider and prove disposal at its owned lifecycle boundary

- **S04 [OC01] [TI02] Lexical hits retain persisted zero-based chunk ordinals on both corpora**
  - **Given** memory and conversation documents each containing repeated equal chunk text at different positions
  - **When** either lexical implementation stores, searches, lists or fetches the documents
  - **Then** `SearchResult.chunkIndex` identifies the original position independent of row ID/text; fetch restores
    chunk order; upsert/rebuild reproduces the same ordinals on SQLite and PostgreSQL

- **S05 [OC03] [TI03] Headings guide deterministic chunks and fenced code stays whole**
  - **Given** canonical memory Markdown with CRLF, nested ATX headings, long prose, repeated paragraphs, backtick and
    tilde fenced blocks, and an indivisible fenced block over the normal chunk target
  - **When** `MemoryIndexProjection.document` maps the same content incrementally or during rebuild
  - **Then** outputs are byte-for-byte identical and source ordered; heading context accompanies subordinate prose;
    prose splits at block/line/word boundaries; no fence content is split or lost; an oversized fence remains one
    lexical chunk for later explicit embedding failure

- **S06 [OC04] [TI01] Diagnostics expose fusion evidence only when requested**
  - **Given** keyword-only, vector-only and shared candidates plus a structured lexical/vector degradation
  - **When** the owning corpus adapter reports diagnostics through a supplied sink
  - **Then** each candidate carries stable identity, nullable constituent ranks, zero for absent contributions,
    weighted contributions summing to its fused score and the owning source layer; counts and degradation causes are
    retained without source text, vectors or credentials; omitting the sink leaves normal result shapes unchanged

## Structural Criteria

- **SC01** `dartclaw_kernel` owns and explicitly exports the vector, embedding and diagnostic contracts; it gains no
  provider, database, hashing algorithm, model dimension, configuration knob, initialization or store lifecycle.
- **SC02** Both `memory_chunks` and `conversation_chunks` required manifests, bootstrap SQL, inserts and result reads
  persist `chunk_index`; no window/correlated-query ordinal reconstruction is used.
- **SC03** Existing memory roles/membership, document IDs, metadata, timestamps, result mapping and ordering remain
  unchanged except for deterministic chunk contents and the added ordinal.
- **SC04** `dartclaw_search` is a T1 workspace package depending only on `dartclaw_kernel` plus justified external
  packages; no dependency on core, runtime or concrete drivers exists. The workspace count is explicitly 13.
- **SC05** Standard fast-tier commands name `dartclaw_search`; full workspace testing discovers it through the root
  workspace list and the existing `test_workspace.sh` enumeration.

## Scope & Boundaries

### Work Areas

- Kernel lexical, vector, embedding and diagnostic contracts and public barrel.
- SQLite/PostgreSQL lexical descriptors, result mapping and required schema manifests.
- Canonical memory chunking at `MemoryIndexProjection.document`.
- `dartclaw_search` package scaffold and workspace test discovery.
- ADR-050/ADR-056 topology and package-count amendments plus architecture gates.

### What We're NOT Doing

- Concrete SQLite/PostgreSQL vector stores – S02 implements them against `VectorIndex`.
- Native or HTTP embedding providers, native artifacts and lifecycle probes – S03 owns them.
- Vector synchronization, fusion, hybrid adapters, ranking constants or runtime wiring – S04 and S05 own them.
- Configuration, operator UI/docs, turn provenance, evaluation and release/platform proof – later Phase B stories and
  the final combined A+B verification own them.
- Any change to wiki/KG/task search, canonical corpus membership or ordinary memory/conversation locators.

## Architecture Decision

**Approach**: Put corpus-neutral contracts in the dependency-free kernel, keep the single canonical memory mapper in
core, persist lexical ordinals in both current schema authorities, and place composition/provider code in a new T1
`dartclaw_search` package. Amend ADR-050/056 and the count gate explicitly.
**Why this over alternatives**: Reconstruction from row order/text is unstable across republish and duplicates;
putting drivers or a second mapper in `dartclaw_search` would violate one authority per concern and the accepted DAG.

## Code Patterns & External References

```text
# type | path#anchor | why needed
file | ../dartclaw-public/packages/dartclaw_kernel/lib/src/full_text_index.dart#SearchResult | lexical contract and constructor idiom
file | ../dartclaw-public/packages/dartclaw_core/lib/src/search/sqlite_fts_index.dart#SqliteFtsIndex | descriptor-driven SQLite reads/writes
file | ../dartclaw-public/packages/dartclaw_core/lib/src/search/postgres_fts_index.dart#PostgresFtsIndex | matching PostgreSQL reads/writes
file | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/schema_identity.dart#SchemaIdentity | SQLite required-object authority
file | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/postgres_schema_gate.dart#PostgresSchemaGate | PostgreSQL required-object authority
file | ../dartclaw-public/packages/dartclaw_core/lib/src/memory/memory_index_projection.dart#MemoryIndexProjection | single canonical mapper
file | ../dartclaw-public/dev/package_tiers.txt | dependency-direction authority
file | ../dartclaw-public/dev/tools/arch_check.dart#_workspacePackageCeiling | package-count and LOC gate
file | ../dartclaw-public/dev/tools/test_workspace.sh | dynamic full-workspace test discovery
```

## Constraints & Gotchas

- Persist ordinals as non-negative integers populated from `document.chunks.indexed`; select them into every
  `SearchResult` and order `fetch` by document plus ordinal. Backend row IDs remain private tie-breakers only.
- `VectorIndex.search` rejects empty/non-finite queries, empty fingerprint and non-positive limit before backend work;
  it filters exact fingerprint and equal dimensions before scoring. Stored records never infer dimensions from config.
- `upsert` is last-record-wins by `VectorIdentity` and atomically applies `retire`; `delete` addresses exact identities;
  `replaceAll` replaces the complete owner corpus; `list` is deterministic by document ID then ordinal.
- Segment raw normalized Markdown before formatting cleanup. ATX headings start section context; blank-line prose blocks
  may split at line then word boundaries to the existing 500-character target. Backtick/tilde fenced blocks are
  indivisible, including an unclosed final fence. Preserve their content and allow that block to exceed the target.
- Adding `chunk_index` changes the exact schema. SQLite search storage is derived and rebuilds through its existing
  gate; PostgreSQL uses its existing fresh-bootstrap/exact-current refusal. Do not add an additive repair or migration.
- Constructors defensively freeze caller-owned lists/maps. Public contracts receive proportional dartdoc and explicit
  barrel `show` exports; internal helpers receive comments only for hidden invariants.
- TI01 proves validated value objects, method shape and test-double conformance only. S02 owns shared contract tests
  against both vector stores; S03 owns provider behavior and disposal tests; S04 owns diagnostic opt-in/fusion proof.

## Implementation Plan

### Implementation Tasks

- **TI01** Kernel exposes the pinned validated search contracts
  - Add the exact surface above beside `FullTextIndex`, with value semantics, invariant tests, explicit exports and no
    lifecycle/config implementation; all existing `SearchResult` constructors supply the real ordinal or zero where
    the source is inherently unchunked.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_kernel/test/vector_search_contract_test.dart packages/dartclaw_kernel/test/full_text_index_test.dart` – constructors reject every invalid identity/vector/rank/count case, freeze collections, value equality holds, diagnostics encode absent ranks, and the two port signatures compile through test implementations
  - **SATISFIES**: S01, S02, S03, S06, SC01, SC03

- **TI02** Lexical stores publish persisted chunk identity on both corpora
  - Extend the descriptor/schema authorities and both `FullTextIndex` implementations with `chunk_index`; update
    direct `SearchResult` producers without changing their existing locator, metadata, timestamp or ordering meaning.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/search/sqlite_fts_index_test.dart packages/dartclaw_core/test/storage/sqlite_schema_gate_search_test.dart && dart analyze --fatal-infos packages/dartclaw_core` – SQLite proves repeated-text ordinals, fetch order, both corpus schemas and atomic republish; PostgreSQL proof surfaces compile for the same live contract, whose execution is deferred to final A+B verification
  - **SATISFIES**: S04, SC02, SC03

- **TI03** Canonical memory projection emits deterministic heading/fence-safe chunks
  - Keep chunking private to `MemoryIndexProjection.document`; test raw literals rather than fixtures produced by the
    mapper, including incremental/rebuild equality, both fence markers, repeated text and the oversized-fence rule.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/memory/memory_index_projection_test.dart` – all S05 clauses hold while the existing four-role membership and canonical result-mapping assertions remain green
  - **SATISFIES**: S05, SC03

- **TI04** `dartclaw_search` is an authorized, tested workspace member
  - Create the lean package scaffold at version `0.25.2`, depending only on `dartclaw_kernel`; place it on T1, add it
    to the root workspace, LOC/count gates and explicit fast tier, while full testing continues to enumerate workspace
    members dynamically. Amend ADR-050/056 with the final T1 edge and count 13.
  - **Verify**: `cmd: dart pub workspace list | rg -q 'packages/dartclaw_search' && dart run dev/tools/arch_check.dart && dart test --reporter=failures-only dev/fitness/test/dependency_direction_test.dart && rg -q 'packages/dartclaw_search' dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md && rg -q '13 packages under' dev/adrs/056-package-topology-consolidation.md` – workspace discovery, strict dependency direction, package count, fast tier and explicit ADR amendment agree
  - **SATISFIES**: SC04, SC05

### Testing Strategy

- TI01 uses pure contract tests. TI02/TI03 use existing storage/mapper suites with adversarial raw inputs. PostgreSQL
  live, full workspace/fitness, native/platform, held-out and release checks are intentionally executed once by the
  final combined A+B owner; this story only compiles the live proof surfaces.

## Implementation Observations

_No observations recorded yet._
