# FIS: SQLite and PostgreSQL Vector Projections

**Plan**: dev/bundle/docs/specs/0.26/phase-b/plan.json
**Story-ID**: S02

_Authored against public `3396754b6501` on `feat/0.26`; commands and `packages/...` paths run from
`../dartclaw-public/`._

## Feature Overview and Goal

**Intent**: Persist the two owner-scoped derived vector corpora on either supported database backend, with atomic
mutation, finite cosine ranking and schema refusal that cannot modify or reset authoritative data.

**Expected Outcomes**:

- [OC01] SQLite keeps memory and conversation vectors in a separate `vectors.db` as little-endian float32 blobs and
  ranks matching current vectors in Dart, independent of lexical `search.db` publication.
- [OC02] PostgreSQL keeps the two vector corpora in the existing application namespace and pool, using an
  administrator-installed pgvector extension without making lexical-only deployments depend on it.
- [OC03] Both stores implement the exact S01 `VectorIndex` contract with owner/corpus isolation, deterministic
  enumeration and atomic retire, upsert, delete and complete-owner replacement.
- [OC04] Existing schema gates recognize exact vector projection objects, bootstrap only a wholly absent optional
  projection and refuse partial/incompatible state with derived-only recovery guidance.

## Pinned Downstream API

S04 and S05 consume this exact core-owned surface; no second vector port or driver-facing abstraction is added:

```dart
final class VectorTable {
  static final memoryChunks = VectorTable(/* memory_vectors */);
  static final conversationChunks = VectorTable(/* conversation_vectors */);
}

final class SqliteVectorIndex implements VectorIndex {
  new(DatabaseBackend backend, {required VectorTable table});
}

final class PostgresVectorIndex implements VectorIndex {
  new(DatabaseBackend backend, {required VectorTable table});
}

abstract final class SqliteSchemaGate {
  static Future<void> prepareVectors(
    DatabaseBackend backend, {
    required String storeName,
  });
}

abstract final class PostgresSchemaGate {
  static Future<void> preflightVectorExtension(
    DatabaseBackend backend, {
    required String databaseIdentity,
  });

  static Future<void> prepareVectorProjection(
    DatabaseBackend backend, {
    required String databaseIdentity,
  });
}
```

`VectorTable.memoryChunks` and `.conversationChunks` select the fixed `memory_vectors` and `conversation_vectors`
tables. The validated descriptor exposes no caller-selected SQL identifier. Both indexes implement S01's exact
`search`, `list`, `upsert(retire:)`, `delete` and `replaceAll` signatures.

For hybrid PostgreSQL startup, S05 must call `preflightVectorExtension`, then the existing
`PostgresSchemaGate.prepare`, then `prepareVectorProjection`. Lexical-only startup calls neither vector method.
`prepareVectorProjection` first validates the current authoritative schema, so it cannot turn an absent or invalid
authoritative namespace into a vector-only store.

## Required Context

- `docs/specs/0.26/phase-b/plan.json#sharedDecisions` – exact S01 port signatures, derived vector lifetime, package
  ownership, database behavior and final-verification ownership.
- `docs/specs/0.26/phase-b/s01-search-contracts-and-canonical-chunk-identities.md#pinned-contract-surface` – accepted
  `VectorIndex`, `VectorIdentity`, `VectorRecord` and `VectorMatch` invariants this story implements unchanged.
- `docs/specs/0.26/phase-b/prd.md#fr3-incremental-projection-and-recovery` – stable identities, reusable vectors,
  stale retirement and empty-corpus replacement.
- `docs/specs/0.26/phase-b/prd.md#fr4-backend-vector-storage-and-compatibility` – backend storage, extension preflight,
  current-object validation, transactional setup and refusal requirements.
- `docs/specs/0.26/phase-b/implementation-context.md#database-and-schema-seams` – landed database boundary and current
  schema ownership.
- `../dartclaw-public/dev/adrs/050-native-hybrid-search.md#decision` – derived/rebuildable vectors, local default and
  direct cosine scan at prototype scale.
- `../dartclaw-public/dev/adrs/056-package-topology-consolidation.md#amendment-2026-08-22--the-tier-order-replaces-the-per-edge-tables`
  – concrete database implementations remain in core.

## Deeper Context

- `../dartclaw-public/packages/dartclaw_core/lib/src/storage/schema_identity.dart#SchemaIdentity` – required SQLite
  object manifests and bootstrap statements.
- `../dartclaw-public/packages/dartclaw_core/lib/src/storage/sqlite_schema_gate.dart#SqliteSchemaGate` – marker,
  empty/current/incompatible classification and transactional bootstrap idiom.
- `../dartclaw-public/packages/dartclaw_core/lib/src/storage/postgres_schema_gate.dart#PostgresSchemaGate` – existing
  authoritative PostgreSQL manifest, validation and empty-namespace bootstrap.
- `../dartclaw-public/packages/dartclaw_core/lib/src/storage/postgres_backend.dart#PostgresBackend.open` – pooled
  connections whose `search_path` contains only the quoted application namespace.
- `.agent_temp/0.26-execution/pgvector-environment.md` – prepared PostgreSQL16/pgvector0.8.6 environment and final
  runtime-role proof inputs.

## Acceptance Scenarios

- **S01 [OC01,OC03] [TI02] SQLite round-trips float32 vectors and ranks in Dart**
  - **Given** memory and conversation records with finite vectors, repeated document IDs under different owners,
    different fingerprints and different dimensions
  - **When** each `SqliteVectorIndex` persists, lists and searches its selected corpus
  - **Then** `vectors.db` stores little-endian float32 blobs plus explicit dimensions; list reconstructs immutable
    finite records in document/ordinal order; search considers only the requested owner, corpus, exact fingerprint and
    equal dimension before computing cosine; results have finite similarity scores ordered by score then stable identity

- **S02 [OC02,OC03] [TI03] PostgreSQL uses pgvector through the existing namespace-scoped pool**
  - **Given** administrator-provisioned pgvector in `public`, an application namespace with both vector tables and
    records spanning owners, corpora, fingerprints and dimensions
  - **When** `PostgresVectorIndex` lists or ranks records through `PostgresBackend`
  - **Then** values round-trip through `public.vector`; candidates are filtered by owner, exact fingerprint and
    `public.vector_dims` before `OPERATOR(public.<=>)` distance; no record crosses owner/corpus scope; finite similarity
    ordering and identity tie-breaks agree with SQLite within float32 tolerance

- **S03 [OC03] [TI02,TI03] Every mutation is atomic and owner-scoped**
  - **Given** existing records for the target owner and another owner in the same selected corpus
  - **When** `upsert` applies retirements and last-record-wins replacements, `delete` receives exact identities, or
    `replaceAll` receives the complete target-owner projection
  - **Then** each call commits all its deletes/inserts or none; only `(userId, documentId, chunkIndex)` rows in that
    index's fixed corpus change; an empty replacement clears that owner's corpus; another owner and the other corpus
    remain byte-for-byte unchanged

- **S04 [OC03] [TI02,TI03] Invalid queries and corrupt stored values never become matches**
  - **Given** empty/non-finite query vectors, blank fingerprints, non-positive limits, dimension mismatch, zero-norm
    vectors or a corrupt stored representation
  - **When** either implementation validates or searches
  - **Then** S01-invalid arguments throw `ArgumentError` before database work; dimension/fingerprint mismatches and
    zero-norm candidates are excluded before distance; a zero-norm query returns no matches; corrupt persisted vector
    data fails with content-free derived-store recovery guidance rather than a non-finite `VectorMatch`

- **S05 [OC01,OC04] [TI01] SQLite vector schema is separate and exact**
  - **Given** a missing, current, partially present or incompatible `vectors.db`
  - **When** `SqliteSchemaGate.prepareVectors` inspects `SchemaIdentity.vectors`
  - **Then** an empty store transactionally creates both corpus tables and the current marker; current state is
    unchanged; partial/incompatible state is refused with instructions to reset/rebuild only `vectors.db`; the lexical
    `search.db` and authoritative store are never opened or changed

- **S06 [OC02,OC04] [TI01] PostgreSQL preflights extension before authoritative bootstrap**
  - **Given** hybrid startup against a fresh or current application namespace where pgvector is absent, installed
    outside `public`, inaccessible to the runtime role, or correctly administrator-provisioned in `public`
  - **When** `preflightVectorExtension` runs before the existing authoritative preparation
  - **Then** it performs read-only catalog/cast/operator checks and refuses every unusable state with safe guidance
    that an administrator must install `CREATE EXTENSION vector WITH SCHEMA public`; it never installs the extension,
    creates application tables, requests superuser access or exposes a DSN/credential

- **S07 [OC02,OC04] [TI01] PostgreSQL optional projection bootstrap cannot repair authoritative data**
  - **Given** a validated current authoritative namespace whose two vector tables are both absent, both exact, only
    partly present, or structurally incompatible
  - **When** `prepareVectorProjection` runs after successful extension preflight
  - **Then** it transactionally creates both tables only when wholly absent, accepts both only when exact, and refuses
    all partial/incompatible states with vector-projection reset/rebuild guidance; rollback removes every table from a
    failed bootstrap and no authoritative table, row or schema marker is migrated, dropped or rewritten

- **S08 [OC02,OC04] [TI01] Lexical-only PostgreSQL remains extension-independent**
  - **Given** a PostgreSQL deployment configured without hybrid retrieval and without pgvector
  - **When** the existing `PostgresSchemaGate.prepare` and validation paths run
  - **Then** authoritative and lexical schema preparation succeeds without querying pgvector or requiring vector
    tables; entirely absent vector tables remain an allowed optional projection

## Structural Criteria

- **SC01** `SchemaIdentity.vectors` owns exactly `memory_vectors` and `conversation_vectors`, their required columns,
  composite owner/document/ordinal identity, ordinary lookup indexes and SQLite bootstrap/drop statements. It does not
  add vector objects to `SchemaIdentity.search` or the authoritative marker epoch.
- **SC02** PostgreSQL's vector manifest is generated in `PostgresSchemaGate` from the same fixed vector identity while
  requiring `embedding` to be `public.vector`; its optional status does not weaken validation of existing
  authoritative/lexical objects.
- **SC03** SQLite encodes each component as IEEE754 float32 little-endian and validates decoded byte count and finite
  values. PostgreSQL sends only validated vector literals through parameterized `CAST(? AS public.vector)` and reads
  vectors through a qualified textual representation; neither interpolates record/query data into SQL.
- **SC04** Because every PostgreSQL pool connection sets `search_path` to only the quoted application namespace, all
  extension-owned references use `public.vector`, `public.vector_dims` and `OPERATOR(public.<=>)` explicitly. The
  application vector table names remain unqualified and therefore namespace-local.
- **SC05** Direct scans are bounded by owner/corpus and matching fingerprint/dimension. No ANN index, dimension config,
  migration framework, extension installer or second database adapter is introduced.

## Scope & Boundaries

### Work Areas

- Core SQLite/PostgreSQL `VectorIndex` implementations, fixed vector-table descriptor and core barrel exports.
- `SchemaIdentity.vectors`, SQLite vector preparation and PostgreSQL extension/projection gates.
- Shared backend contract tests, SQLite schema/store tests and PostgreSQL schema/store live proof surface.

### What We're NOT Doing

- Embedding providers, native artifacts, vector generation or model lifecycle – S03 owns these.
- Synchronization, content-hash reuse decisions, late-result authentication, hybrid fusion or unembedded counts – S04
  owns these using the stores here.
- Runtime opening of `vectors.db`, startup ordering, configuration or backend composition – S05 consumes the pinned API.
- Automatic pgvector installation, superuser credentials, authoritative migrations/resets or ANN infrastructure.
- Wiki, knowledge-graph, task search, lexical `search.db` publication or changes to canonical corpus membership.

## Architecture Decision

**Approach**: Implement two small core adapters over the shared S01 port and one fixed corpus descriptor. Give the
separate SQLite derived file its own required-object identity. Keep PostgreSQL authoritative validation unchanged and
add explicit read-only extension preflight plus optional projection preparation.

**Why this over alternatives**: A vector-specific portable database API would duplicate the existing backend;
putting driver code in `dartclaw_search` would invert the accepted package graph. Folding vectors into `search.db`
would discard reusable embeddings during lexical republish, while folding optional PostgreSQL tables into the base
manifest would make lexical-only deployments require pgvector.

## Code Patterns & External References

```text
# type | path#anchor | why needed
file | packages/dartclaw_core/lib/src/search/sqlite_fts_index.dart#SqliteFtsTable | fixed descriptor and atomic adapter idiom
file | packages/dartclaw_core/lib/src/search/postgres_fts_index.dart#PostgresFtsTable | PostgreSQL descriptor and parameterized-query idiom
file | packages/dartclaw_core/lib/src/storage/schema_identity.dart#SchemaIdentity | separate SQLite vector manifest authority
file | packages/dartclaw_core/lib/src/storage/sqlite_schema_gate.dart#SqliteSchemaGate.prepareSearch | classification and transactional derived-store preparation
file | packages/dartclaw_core/lib/src/storage/postgres_schema_gate.dart#PostgresSchemaGate | required-object inspection and refusal authority
file | packages/dartclaw_core/lib/src/storage/postgres_backend.dart#PostgresBackend.open | application-only search_path constraint
test | packages/dartclaw_core/test/search/postgres_fts_index_live_test.dart | integration tag and disposable-namespace convention
test | packages/dartclaw_core/test/storage/postgres_live_support.dart#withPostgresBackend | real pool/runtime-role test boundary
```

## Constraints & Gotchas

- S01 is the sole vector contract authority. Implement the exact signatures and invariants in its pinned block; do not
  add corpus, backend, dimension or lifecycle parameters to `VectorIndex`.
- `upsert` is last-record-wins by `VectorIdentity`; it applies the deduplicated retire set and replacement set in the
  same transaction. `list` orders by document ID then ordinal. Search orders descending similarity, then document ID
  and ordinal, and applies `limit` last.
- Store vectors as float32 on both paths for comparable behavior. Cosine scores may be negative but must be finite.
  A finite all-zero vector is valid under S01's constructor contract but has no cosine direction, so searches exclude
  zero-norm candidates and a zero-norm query returns empty.
- PostgreSQL dimension filtering must occur before distance evaluation, including at the execution-plan level. Use a
  materialized filtered candidate relation or an equivalently proven guarded expression; a syntactic `WHERE` beside
  an unsafe distance expression is insufficient because the optimizer may reorder evaluation.
- `prepareVectorProjection` calls `validateCurrent` before inspecting/creating vector objects. Its recovery action may
  name only the derived vector tables; it must never recommend resetting authoritative data. SQLite guidance may name
  only `vectors.db`.
- Extension refusal text states the public-schema installation requirement and an administrator action. Diagnostics
  contain only the supplied safe `databaseIdentity`, missing capability/object names and recovery steps.
- The prepared real server uses `pgvector/pgvector:0.8.6-pg16-bookworm`; tests authenticate the runtime role from
  `.agent_temp/0.26-execution/pgvector-runtime.env` and do not depend on admin credentials during store operations.

## Implementation Plan

### Implementation Tasks

- **TI01** Existing schema authorities own optional vector compatibility
  - Add `SchemaIdentity.vectors` with both fixed tables and derived-only drops; implement SQLite empty/current/refusal
    handling. Add PostgreSQL read-only public-extension preflight and a separate exact optional-projection manifest that
    validates authoritative state first, bootstraps both tables atomically only when wholly absent and never changes
    the behavior of the existing base `prepare` path.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_schema_gate_vectors_test.dart packages/dartclaw_core/test/storage/postgres_schema_gate_vectors_test.dart` – fake/backend-focused tests prove SQLite classification and isolation, public-qualified extension checks, lexical-only independence, authoritative-first validation, exact/absent/partial projection classification, rollback and content-free recovery text
  - **SATISFIES**: S05, S06, S07, S08, SC01, SC02, SC04

- **TI02** SQLite implements the complete vector-store contract
  - Add/export `VectorTable` and `SqliteVectorIndex`; encode/decode validated float32 blobs and implement deterministic
    owner-scoped list/ranking plus atomic last-wins retire/upsert/delete/replace. Run the shared `VectorIndex` contract
    against both fixed corpora and distinct owners, with injected failures proving rollback.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/search/sqlite_vector_index_test.dart` – round-trip tolerance, isolation, stable ranking/ties, fingerprint/dimension/zero-norm exclusion, validation, stale retirement, empty replacement and every mutation rollback pass against in-memory SQLite
  - **SATISFIES**: S01, S03, S04, SC03, SC05

- **TI03** PostgreSQL implements the same contract with explicitly qualified pgvector
  - Add/export `PostgresVectorIndex` over the same fixed descriptor. Use validated parameterized vector literals,
    public-qualified type/function/operator references and filter materialization before distance; keep all mutations in
    one backend transaction and reuse the TI02 shared contract cases.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/search/postgres_vector_index_test.dart && dart analyze --fatal-infos packages/dartclaw_core` – SQL-shape/backend-double tests prove qualification, parameters, pre-distance filtering, transactions and S01 signature conformance without requiring a live server
  - **SATISFIES**: S02, S03, S04, SC03, SC04, SC05

### Testing Strategy

- TI01–TI03 are the focused default proof for implementation and standard story completion. They use real SQLite plus
  PostgreSQL backend doubles so ordinary development does not depend on a server.
- The real prepared pgvector contract is intentionally declared for the final combined A+B owner and is not run by
  this story: `set -a; source ../dartclaw-private/.agent_temp/0.26-execution/pgvector-runtime.env; set +a; dart test
  --reporter=failures-only packages/dartclaw_core/test/search/postgres_vector_index_live_test.dart
  packages/dartclaw_core/test/storage/postgres_schema_gate_vector_live_test.dart`. It must prove runtime-role preflight,
  fresh/current/partial behavior, rollback, both corpus contracts, mixed dimensions/fingerprints, `public` qualification
  under application-only `search_path`, and cross-backend score/rank agreement.
- Full workspace/fitness, broad PostgreSQL, native/platform, held-out and release checks remain with S09's one combined
  A+B verification campaign.

## Implementation Observations

_No observations recorded yet._
