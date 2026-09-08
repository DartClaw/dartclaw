# FIS: FullTextIndex Abstraction and FTS5 Implementation

**Plan**: dev/bundle/docs/specs/0.26/plan.json
**Story-ID**: S03

_Refreshed 2026-09-02 against released 0.25 (public HEAD `daf5125a`), after the 2026-07-30 authoring and the 2026-08-14 refresh against 0.24. Version labels: 0.26 is this milestone (the PRD title still carries its pre-renumber label), released 0.25 is the compatibility baseline, 0.27 is the Chat consumer. Every file this story touches survived 0.25 under a new package: `dartclaw_storage` was absorbed into `dartclaw_core`, `dartclaw_models`/`dartclaw_config` into `dartclaw_kernel`, `dartclaw_server` became `dartclaw_runtime`; the `memory_chunks` DDL is byte-identical 0.24 → 0.25 → HEAD. Two 0.25 facts the earlier refresh could not know now bind: the `error` canonical role exists and stays outside the searchable role set, and `dartclaw rebuild-index` is a Windows release-gate consumer (`dev/tools/build_windows.ps1` matches its `Rebuilt index:` line). Code references (`packages/...`, `apps/...`) are paths inside `../dartclaw-public/`._

## Feature Overview and Goal

**Intent**: Memory-document lexical search is hard-coupled to FTS5 SQL inside `MemoryService`, so a PostgreSQL backend cannot search memory without re-implementing every query – this story lands the one corpus-agnostic `FullTextIndex` port and its SQLite implementation, without weakening the `user_id` boundary that stops one user reading, overwriting, or deleting another user's indexed content, and without changing what the SQLite default stores, ranks, or prints.

**Expected Outcomes**:

- [OC01] SQLite memory search, Knowledge Hub recency listing, incremental projection, and `dartclaw rebuild-index` behave and print exactly as at released 0.25 while every `search.db` statement is issued by the SQLite index implementation through S01's `DatabaseBackend`.
- [OC02] Every index operation is scoped by a required `userId`: the same document id under two users names two documents, and neither user can read, overwrite, or delete the other's.
- [OC03] The port and its data shapes live in `dartclaw_kernel`, reachable by story S09's `PostgresFtsIndex`, story S11's contract suite, story S13's conversation instance, and Phase B's `dartclaw_search` without a storage edge.
- [OC04] Canonical memory identity survives the round trip as metadata – `role`, `provenance`, `entry_id`, `entry_revision`, with the locator as the document id – reconstructing an equal `MemorySearchResult` under the canonical-role invariant, and the `error` role is never projected.


## Required Context

- `docs/specs/0.26/plan.json#sharedDecisions` – decision "FullTextIndex contract: corpus-agnostic, tenancy-carrying, two instances" is this story's contract (port in `dartclaw_kernel`, `user_id` on every operation, canonical identity as metadata with the memory-side mapper enforcing the invariant – owner 2026-08-14, `error` outside the searchable set, reconciler onto the seam, health stays the JSON file); decision "DatabaseBackend seam shape and placement under the 0.25 topology" places `SqliteFtsIndex` in `dartclaw_core`, pins the LOC ceilings, the 1500/1300-line file caps, and explicit barrel `show` clauses.
- `docs/specs/0.26/prd.md#fr3-full-text-index-abstraction-with-tenancy` – the acceptance criteria this story seeds: `user_id` required on search, upsert, delete; corpus-agnostic contract with reserved memory metadata keys and the `entry_revision` string↔`int` round trip; FTS5 behavior reproduced with zero user-visible change; same-identifier isolation; rebuild flows unchanged; KG facts never copied in. **NOTICED**: the FR text still says "0.24's canonical memory identity"; read as released 0.25 (columns unchanged). The PRD amendment is owner-owned.
- `docs/specs/0.26/s01-databasebackend-seam-and-sqlite-backend.md#technical-overview` – the seam this story consumes verbatim: positional `?` SQL, canonical scalars, `transaction()` with `NestedTransactionError` on nested calls (#3), `Future<int>` affected rows (#5), no DDL in constructors (#7), and the shared-connection constraint under `## Constraints & Gotchas`.
- `docs/specs/0.26/s02-sqlite-schema-bootstrap-and-compatibility-gate.md#technical-overview` – `SqliteSchemaGate.prepareSearch(backend, storeName:, rebuild:)` is the only way a `search.db` gets its schema after this story; the required search manifest (11 `memory_chunks` columns, `memory_chunks_fts`, three triggers) is the table this story writes without change; `populate(tx)` is the in-transaction shape story S06 wires with the constructor pinned under `## Technical Overview` below.
- `../dartclaw-public/dev/adrs/045-pluggable-database-backend.md#fts-abstraction` – the sketch this port realizes and the rule that the `user_id` filter *is* the isolation mechanism; `#024-memory-preservation-constraint-2026-08-12` – natural-language search input, stable entry identity/revision/provenance, source-resolvable locators, health evidence, and the stopped-runtime rebuild contract must all survive.
- `../dartclaw-public/dev/adrs/056-package-topology-consolidation.md#amendment-2026-08-21--storage-absorption-landed` – `dartclaw_core` carries `sqlite3` and the former storage package; `dartclaw_kernel` depends on nothing, which is what lets Phase B reach the port without a storage edge (`dev/package_tiers.txt`: T0 kernel, T1 core; no exception mechanism).
- `../dartclaw-public/dev/state/LEARNINGS.md#storage--data-model` – "Durable knowledge graph facts belong in `tasks.db`, not `search.db`" (why KG stays out of the index); "FTS5 MATCH has special operators" (why query encoding is the implementation's job, not the caller's). `#package-architecture` – curation writes go through `MemoryApplyService.apply` (the `memory_architecture` fitness scanner); a public name may not be redeclared across packages.
- `docs/specs/0.26/launch-context.md#live-storage-baseline` – the current memory-search schema, file-backed health evidence, package topology, and wiring baseline that supersede the temporary re-plan audit.


## Deeper Context

- `docs/specs/0.26/hybrid-search-prd-brief.md#dependencies--planning-checks` – Phase B composes the memory instance with `VectorIndex` and must reach the contracts without a storage edge; the chunker becomes the single chunking owner, which is why documents carry chunks.
- `docs/research/dart-native-hybrid-search/research.md#51-package-placement` – the `dartclaw_search` placement the port must stay reachable from.
- `../dartclaw-public/dev/architecture/data-model.md#derived-memory-index-row` – the derived-row description TI07 updates; `MEMORY.audit.md` is never indexed.
- `../dartclaw-public/dev/guidelines/TESTING-STRATEGY.md#test-layers` – Layer 2 against real in-memory SQLite, no mocks; `#data-integrity` – persisted search behavior is proven on the real engine.
- `../dartclaw-public/dev/state/LEARNINGS.md#tooling--verification` – `dart test` runs suites as isolates in one process (never touch `Directory.current`).


## Acceptance Scenarios

- **S01 [OC01,OC04] [TI02,TI03,TI04] Memory search through the port is behavior-identical**
  - **Given** an S02-prepared in-memory `search.db` holding, for `userId: 'owner'`, a canonical topic entry with text `Dart is a client-optimized language`, `role: topic`, `provenance: turn:1`, locator/`entry_id` `<uuid>`, `entry_revision: 7`, category `general`
  - **When** `Fts5SearchBackend.search('Dart')` runs for `owner`
  - **Then** it returns that entry with the same text, source (`== locator`), category, a negative value from the FTS5 `rank` column (bm25 by default) and best-first ordering as at 0.25, and the reconstructed `MemorySearchResult` equals the pre-refactor one on all nine fields with `entryRevision == 7` as an `int`
  - **Proof**: `packages/dartclaw_core/test/search/search_backend_test.dart#Fts5SearchBackend` – green – parity/regression (every assertion stays; only construction and seeding move onto the prepared store and the port)

- **S02 [OC04] [TI02] Canonical identity is required, not decorative**
  - **Given** an indexed document whose metadata carries a canonical `role` (`topic`, `archive`, `observation`, or `learning`) but no `entry_id`/`entry_revision`, and a second whose `entry_revision` is the malformed string `seven`
  - **When** the memory mapper reconstructs a `MemorySearchResult` from each
  - **Then** both raise `StateError` – the same failure the shipped 0.25 mapper raises for missing identity – never a result with dropped identity or a silent `0`; a native (non-canonical) role without entry identity remains valid

- **S03 [OC04] [TI02] The error role is never projected**
  - **Given** a canonical corpus with one topic entry, one learning, and two `error` records
  - **When** the memory mapper projects the corpus into search documents
  - **Then** exactly the topic and learning documents exist, every projected `role` is in `{topic, archive, observation, learning}`, and audit records likewise produce nothing

- **S04 [OC02] [TI03] Read isolation is mandatory**
  - **Given** `owner` and `other` each upsert a document with id `shared-id` whose chunks contain `secret`, with distinct text and metadata
  - **When** `search('secret', userId: 'owner')`, `listRecent(userId: 'owner')`, `fetch(['shared-id'], userId: 'owner')`, and `count(userId: 'owner')` run
  - **Then** each returns only owner's document (count `1`), and every port signature requires `userId` rather than defaulting it

- **S05 [OC02] [TI03] Same-id upsert and delete cannot cross the user boundary**
  - **Given** `other` holds id `shared-id` with text `other draft`
  - **When** `owner` upserts `shared-id` with text `owner final`, then upserts it again with new text, then `delete(['shared-id'], userId: 'owner')` runs, then `delete(['missing'], userId: 'owner')` runs
  - **Then** after each upsert owner's search returns exactly owner's latest text and metadata while other's `other draft` is unchanged; after the delete owner's document is absent, other's remains searchable, and deleting a missing id completes as a no-op

- **S06 [OC01,OC02] [TI03] Replacement is atomic, per user, and retires prior ids in the same operation**
  - **Given** owner and other each have documents, including stale owner ids `a` and `b`
  - **When** `upsert([doc c], userId: 'owner', retire: {'a'})` runs, then `replaceAll([], userId: 'owner')` runs, and separately an upsert whose second document has an empty chunk list runs
  - **Then** after the first call owner holds `b` and `c` only; after `replaceAll` owner holds nothing while other's corpus is unchanged; the rejected upsert throws `ArgumentError` and leaves owner's corpus exactly as before it (no partial write)

- **S07 [OC01] [TI05,TI06] Rebuild output, health, and membership stay unchanged**
  - **Given** a canonical corpus projecting three chunks at collection revision `R` and a `search.db` holding stale owner rows
  - **When** `dartclaw rebuild-index` runs
  - **Then** it prints the shipped 0.25 line `Rebuilt index: 3 entries at collection revision R; health=healthy` (re-confirmed verbatim at HEAD), a subsequent owner search returns only the three fresh chunks, `.dartclaw-memory-index.json` reads `healthy` at the corpus revision and fingerprint, and the reconciler issued no store operation outside `FullTextIndex` and `DatabaseBackend`
  - **Proof**: `apps/dartclaw_cli/test/commands/rebuild_index_command_test.dart#rebuilds the index from a canonical corpus` – green – parity/regression

- **S08 [OC01] [TI06] Reconciliation transitions and evidence are preserved on the seam**
  - **Given** the reconciler's fault-injection hook at each of its seven transitions, an interrupted `rebuilding` evidence file, and a current healthy target
  - **When** batched reconciliation runs through the seam-backed store opener
  - **Then** every pre-existing assertion holds unchanged: a fault at any transition preserves the prior target bytes and converges on retry, the fast path proves exact chunk parity and calls `authenticateComplete`, an authenticated empty corpus is healthy with exactly zero stored chunks, and interrupted evidence reopens as degraded
  - **Proof**: `packages/dartclaw_core/test/storage/index_reconciler_test.dart#batched current fast path proves exact rows and complete canonical authentication` – green – parity/regression (the whole file is bound by TI06's Verify)

- **S09 [OC01,OC02] [TI03] FTS5 operator characters follow the existing degradation path**
  - **Given** documents indexed for two users
  - **When** one user searches `test & "special" <chars>` and, separately, a query that encodes to nothing (`AND OR`)
  - **Then** the natural-language query is encoded exactly as the shipped `encodeNaturalLanguageQuery` does (quoted terms, FTS5 keywords and operator characters stripped), the second returns an empty list without touching the store, and neither returns another user's document or surfaces an unhandled asynchronous error


## Structural Criteria

- **SC01** `FullTextIndex`, `SearchDocument`, and `SearchResult` are declared in `packages/dartclaw_kernel/lib/src/full_text_index.dart` and exported from the kernel barrel under one explicit `show` clause; `SqliteFtsIndex` and `MemoryIndexProjection` are `show`-exported from the core barrel; no new workspace dependency edge exists and the fitness suite (`dependency_direction`, `package_cycles`, `no_second_implementation`, `src_import_hygiene`, `barrel_show_clauses`, `memory_architecture`, `max_file_loc`, `max_test_file_loc`) stays green.
- **SC02** `MemoryService` and `MemoryIndexRow` no longer exist; no production file outside `sqlite_fts_index.dart` contains FTS5 SQL (`MATCH`, direct `bm25()` calls, the FTS5 `rank` column (bm25 by default), `memory_chunks_fts`), and neither `index_reconciler.dart` nor `sqlite_fts_index.dart` imports `package:sqlite3`, so the repo-wide `package:sqlite3` importer census recorded by story S01 falls from 18 to 16 (`memory_service.dart` deleted, `index_reconciler.dart` no longer imports).
- **SC03** Story S02 remains the sole owner of `search.db` DDL: no `CREATE`, `ALTER`, `DROP`, or `PRAGMA table_info` for `memory_chunks` exists in the files this story adds, and the stored byte shape of every `memory_chunks` column is unchanged (`entry_revision` stored as an integer, `created_at` as ISO8601 text, `locator` non-null).
- **SC04** The port is corpus-agnostic: `full_text_index.dart` names no memory vocabulary (`role`, `provenance`, `entry_id`, `entry_revision`, `locator`, `MemorySearchResult`), and only the memory mapper knows it.
- **SC05** `IndexHealthStore` is untouched and remains the JSON file `<workspaceDir>/.dartclaw-memory-index.json`; no health or manifest table is added to any store.
- **SC06** The affected suites, workspace analysis, `arch_check` (LOC ceilings, 12-package ceiling), and `git diff --check` are green; no lib file exceeds 1500 lines and no test file 1300.


## Scope & Boundaries

### Work Areas

- Port: `packages/dartclaw_kernel/lib/src/full_text_index.dart` (`FullTextIndex`, `SearchDocument`, `SearchResult`) and its `show` export from `packages/dartclaw_kernel/lib/dartclaw_kernel.dart` (TI01)
- Memory mapper: `packages/dartclaw_core/lib/src/memory/memory_index_projection.dart` (`MemoryIndexProjection` – corpus → documents, chunking, result reconstruction), replacing the static projection half of `packages/dartclaw_core/lib/src/storage/memory_service.dart`, which is deleted with `MemoryIndexRow` (TI02)
- SQLite implementation: `packages/dartclaw_core/lib/src/search/sqlite_fts_index.dart` (`SqliteFtsIndex` over S01's `DatabaseBackend`, table-parameterized for story S13, with the `memory_chunks` descriptor) (TI03)
- Memory consumers that move onto the port: `packages/dartclaw_core/lib/src/search/{fts5_search_backend,search_backend_factory}.dart`, `packages/dartclaw_core/lib/src/memory/memory_pruner.dart`, and in `dartclaw_runtime`: `memory_handlers.dart`, `knowledge/knowledge_hub_service.dart`, `web/pages/knowledge_hub_page.dart`, the `MemoryService` plumbing in `server_deps.dart`, `server.dart`, `web/web_routes.dart`, `web/system_pages.dart`, `runtime/{harness_wiring,scheduling_wiring,service_wiring_builder}.dart` (TI04)
- Composition root: `packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart` – index construction over `SqliteBackend(searchDb)`, the in-memory fallback prepared through the S02 gate, the post-commit projection, `_canonicalRowBatches` (TI05)
- Reconciler and CLI: `packages/dartclaw_core/lib/src/storage/index_reconciler.dart` (store opener seam, sqlite3-free) and `apps/dartclaw_cli/lib/src/commands/rebuild_index_command.dart` (TI06)
- Architecture docs: `dev/architecture/data-model.md` § Derived Memory Index Row and its two later `MemoryIndexRow`/`MemoryService` mentions, `dev/architecture/system-architecture.md` component table (TI07)
- Tests: new `packages/dartclaw_core/test/search/sqlite_fts_index_test.dart` and `packages/dartclaw_core/test/memory/memory_index_projection_test.dart`; construction/seeding updates to `memory_service_test.dart` (renamed with its surviving projection cases), `search_backend_test.dart`, `index_reconciler_test.dart`, `memory_pruner_test.dart`, `rebuild_index_command_test.dart`, and the `dartclaw_runtime` suites that construct `MemoryService` (TI03–TI06)

### What We're NOT Doing

_(`S<NN>` outside `## Acceptance Scenarios` names a plan story; inside it, a scenario ID.)_

- Schema epochs, bootstrap, compatibility, or any DDL – story S02 owns them; this story consumes `SqliteSchemaGate.prepareSearch` and the S02 fixtures and adds no schema code.
- PostgreSQL FTS, `PostgresFtsIndex`, or PostgreSQL publication of a rebuilt index – story S09 implements the port and supplies the PostgreSQL store opener; the reconciler's sibling-file publication stays SQLite-shaped here.
- Wiring the S02 gate ahead of the reconciler in `StorageWiring.wire()`, retiring `SearchDbFactory`/`Database searchDb` exposure, or closing connections through the seam – story S06; the one gate call this story adds in the runtime (the in-memory fallback, TI05) is a transitional carry S06 absorbs.
- A `VectorIndex`, embeddings, hybrid retrieval, or a chunk-level identity beyond ordered chunks – Phase B; the port's document-with-chunks shape is what its chunker will fill.
- Indexing KG facts, wiki pages, tasks, or conversation messages – KG facts stay authoritative in `kg_facts` (LEARNINGS), wiki stays live-read through `WikiSearchSource`, story S13 instantiates the port a second time for conversations.
- Changing `SearchBackend`, `ComposedSearchBackend`, health gating, QMD behavior, or the Windows release gate's `Rebuilt index:` line – only the FTS5 leg beneath them moves.


## Architecture Decision

**Approach**: One generic lexical-document port in the kernel (T0) – documents with ordered chunks, opaque flat metadata, a source timestamp, and `userId` on every operation – implemented by a table-parameterized `SqliteFtsIndex` in core (T1) over S01's `DatabaseBackend`, with the memory vocabulary, chunking, and canonical-role invariant owned by a memory-side mapper in core. See ADR: `../dartclaw-public/dev/adrs/045-pluggable-database-backend.md` (§ FTS Abstraction); topology: `../dartclaw-public/dev/adrs/056-package-topology-consolidation.md`.
**Why this over alternatives**: a port in core would force `dartclaw_search` and every later consumer to take a storage edge for a contract, and the tier order has no exception mechanism; a flat one-row-per-document port would either change what SQLite stores (today one entry is several `memory_chunks` rows) or need a prefix-delete hack to retire an entry's rows, whereas documents-with-chunks maps 1:1 onto the shipped rows and onto Phase B's chunker.


## Technical Overview

Pinned port contract (consumed verbatim by stories S09, S11, S13 and Phase B – changing it later is a plan-level event):

1. **Shapes** – `SearchDocument(id, chunks, metadata, timestamp)`: `id` non-empty; `chunks` a non-empty ordered `List<String>`; `metadata` an opaque flat `Map<String, String>` persisted and returned verbatim; `timestamp` the document's source time (UTC). `SearchResult(id, chunk, metadata, timestamp, score)`: one hit per matching chunk carrying its document's id, metadata, timestamp, and the backend-native score (SQLite: FTS5 `bm25()`, negative, lower is better). `userId` is never metadata. Both types are immutable value classes in the kernel.
2. **Identity** – `(userId, id)` names one document and all its stored chunks. Upserting an id replaces every chunk and the metadata of that key for that user only; deleting it removes them; a missing key is a silent no-op.
3. **Operations** – all `Future`-returning, all with `required String userId`: `search(String naturalLanguageQuery, {userId, int limit = 20})` best-first by score; `listRecent({userId, int limit = 20})` ordered by `timestamp` descending then most-recently-stored first, score `0`; `fetch(Iterable<String> ids, {userId})` returns the stored documents that exist, chunks in stored order; `count({userId, Map<String, String> metadata = const {}})` counts stored chunks, optionally restricted to documents whose metadata equals every given key (the only structured use of metadata – it serves the dashboard's per-role counter); `upsert(Iterable<SearchDocument> documents, {userId, Set<String> retire = const {}})` atomically removes `retire` and the documents' own ids, then stores the documents (last-wins on duplicate ids within one call); `delete(Iterable<String> ids, {userId})`; `replaceAll(Iterable<SearchDocument> documents, {userId})` atomically clears that user's corpus and stores the documents; `verifyIntegrity()` throws when the backend's own consistency check fails (SQLite: `PRAGMA integrity_check` and the FTS5 `integrity-check` command). Mutations validate every document first and write nothing on `ArgumentError`.
4. **Query language** – `search` takes natural language; each implementation owns its encoding. `SqliteFtsIndex` keeps the shipped `encodeNaturalLanguageQuery` algorithm (double quotes dropped, `AND`/`OR`/`NOT`/`NEAR` and `*^:+-()` removed, each remaining word double-quoted) and returns an empty list without a query when nothing survives. Story S09's PostgreSQL implementation encodes to `tsquery`.
5. **Atomicity** – `SqliteFtsIndex` issues each mutation inside `backend.transaction()` (S01 #3). For story S02's in-transaction `populate(tx)` the implementation exposes `SqliteFtsIndex.withinTransaction(tx, table:)`, whose mutations write directly and rely on the enclosing transaction, because a nested `transaction()` rejects with `NestedTransactionError`. Story S06 uses that constructor when it wires the gate's derived rebuild.
6. **Table descriptor** – `SqliteFtsIndex(backend, table:)` takes a `SqliteFtsTable` (base table, FTS5 table, id/text/timestamp/user columns, and the ordered metadata keys stored as named columns). `SqliteFtsTable.memoryChunks` maps onto the S02 manifest with no change: `locator` is the id column, `text` the chunk, `created_at` the timestamp, `user_id` the user, and metadata keys `source`, `category`, `role`, `provenance`, `entry_id`, `entry_revision` onto the columns of the same name; the base-table rowid and the `created_at DESC, id DESC` order stay the recency tiebreak. Story S13 adds a `conversation_chunks` descriptor.
7. **Memory vocabulary** (owned by `MemoryIndexProjection`, never by the port) – document `id` = the entry locator (canonical: the entry UUID, so `source == locator == entry_id`; native rows lacking entry identity: their source label); metadata `source` and `role` and `provenance` always present (defaults `memory`/`unknown` as today), `category` and `entry_id` and `entry_revision` present only when known; `entry_revision` serialized with `toString()` and parsed with `int.parse`, a malformed value being `StateError`; canonical role (`topic`, `archive`, `observation`, `learning`) ⇒ `entry_id` and `entry_revision` present, else `StateError`, exactly as `MemorySearchResult.canonical` and the shipped row mapper enforce; `error` and `audit` records project nothing. `documents(corpus)` reproduces `canonicalIndexRows` (same Markdown normalization, paragraph split, undated-entry sentinel, per-role locator/provenance/category/revision rules); `chunkCount(documents)` is what `rebuild-index` prints as `entries`.


## Code Patterns & External References

```
# type | path#anchor                                                                                                | why needed (intent)
file   | ../dartclaw-public/packages/dartclaw_kernel/lib/src/search_backend.dart#SearchBackend                       | Sibling kernel port – file placement, dartdoc density, barrel export shape to match
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/memory_service.dart#MemoryService                  | Every FTS5 statement, the NL encoder, the row mapper, canonicalIndexRows, and the transactional replace patterns to carry into SqliteFtsIndex and MemoryIndexProjection before deleting the file
file   | ../dartclaw-public/packages/dartclaw_kernel/lib/src/models.dart#MemorySearchResult                          | The nine-field result and the canonical factory's invariant the mapper reproduces
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/memory/canonical_memory.dart#MemoryRole                    | The role enum including error and audit – the searchable subset is the four canonical roles
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/index_reconciler.dart#CanonicalIndexReconciler     | Sibling-file rebuild, seven transitions, health protocol – preserve exactly; only the store open/close and every store operation move onto the seam
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/search/fts5_search_backend.dart#Fts5SearchBackend          | Thin SearchBackend leg that now forwards natural language to the port
file   | ../dartclaw-public/packages/dartclaw_runtime/lib/src/memory_handlers.dart#createMemoryHandlers               | Incremental projection inside reconcileCanonical: replace records, validate, record health – same order on the port
file   | ../dartclaw-public/packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart#StorageWiring.wire          | Steps 6–13 of the open order: reconciler, search.db open, in-memory fallback, createSearchBackend, registerPostCommitProjection
file   | ../dartclaw-public/packages/dartclaw_runtime/lib/src/runtime/scheduling_wiring.dart#SchedulingWiring.wire     | Construction site (:437) of MemoryStatusService (declared in packages/dartclaw_runtime/lib/src/memory/memory_status_service.dart) – the raw searchIndexCounter SELECT on searchDb (:441-444) that becomes count(userId: 'owner', metadata: {'role': role})
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/memory/memory_pruner.dart#MemoryPruner                      | afterCommit projection writes (replaceMemoryRows / replaceMemoryRecords) that become replaceAll / upsert with retire
file   | ../dartclaw-public/apps/dartclaw_cli/lib/src/commands/rebuild_index_command.dart#RebuildIndexCommand         | The verbatim output line and the JSON keys to keep; the row stream becomes a document stream
file   | ../dartclaw-public/packages/dartclaw_core/test/search/search_backend_contract.dart#searchBackendContractTests | Existing contract behavior to keep unchanged
file   | docs/specs/0.26/s02-sqlite-schema-bootstrap-and-compatibility-gate.md#work-areas                              | schema_fixtures.dart, failing_database_backend.dart, and the gate API tests bootstrap through
```


## Constraints & Gotchas

- **Critical**: `userId` is an isolation boundary, not a convenience default – every port operation requires it and every production call site passes `'owner'` explicitly, including the dashboard counter that today runs an unscoped `COUNT(*)` (every production row is `owner`, so the scoped count is identical).
- **Critical**: a fresh `search.db` no longer gets its schema from a constructor. After this story the only DDL owner is `SqliteSchemaGate.prepareSearch`; the reconciler's fresh sibling and the runtime's in-memory fallback both go through it, and every test that used `MemoryService(db)` to create the schema bootstraps through the gate (or the S02 fixtures) over `SqliteBackend(sqlite3.openInMemory())` instead. Do not add a local `CREATE IF NOT EXISTS` to "help".
- **Constraint**: between this story and story S06 the shared `sqlite3` `Database` for `search.db` has one seam user (`SqliteFtsIndex` over `SqliteBackend(_searchDb)`) and raw co-users only through `Database searchDb` exposure that S06 retires; wiring keeps calling `_searchDb.close()` and never `SqliteBackend.close()` (S01 ownership rule).
- **Constraint**: S02's gate, reached through the reconciler's default opener, may adopt an unmarked released-0.25 `search.db` on the fast path (marker table only, no data change) until S06 orders the gate first; this is the gate's contract, not a reconciler write.
- **Constraint**: `BEGIN IMMEDIATE` is not preserved as a literal – atomicity comes from S01's `transaction()`; the process is single-writer, so no observable difference exists.
- **Avoid**: enumerating "independent sources" – `replaceMemoryRows`' carve-out for non-memory sources has no production writer at 0.25 (`rg 'memory_save' packages apps` matches only `memory_service.dart` itself), so `replaceAll` clears the user's corpus and the carve-out and its test retire with `MemoryService`.
- **Constraint**: the per-user replace and the reconciler's populate hold S01's serialization slot for the awaited body; keep chunk batches as they are streamed today (one manifest path per batch) and never await unrelated work inside a mutation.
- **Constraint**: barrel hygiene and uniqueness are gates – explicit `show` on every new export, the core barrel must not re-export the kernel barrel, and `FullTextIndex`, `SearchDocument`, `SearchResult`, `SqliteFtsIndex`, `SqliteFtsTable`, `MemoryIndexProjection` are verified unique at HEAD.
- **Constraint**: LOC gates. Measured 2026-09-02: `dartclaw_core` 26269 of 27740, `dartclaw_kernel` 18428 of 19920 lib lines; this story deletes a 495-line file and adds roughly its size back across three, so no ceiling is expected to move; if one does, the protocol is a recorded rebaseline in `dev/tools/arch_check.dart#_libLocCeilings` with a CHANGELOG note in the same change.
- **Constraint**: comments are rationale-only; the port's dartdoc states the contract (identity, atomicity, ordering, metadata opacity), never call-site narration or the history of this refactor.
- **Constraint**: `user_id` is a real tenancy key, not a placeholder – the agent-workspace milestone after 0.26 populates it per persona workspace and context-engine mode per read client. -- Workaround: none; the wiring passes the caller's identity through and no site pins the single owner as a constant (the owner's id is the one value it has today, threaded as a value, not hardcoded in the port or the FTS5 implementation).


## Implementation Plan

### Implementation Tasks

- **TI01** The `FullTextIndex` port and its shapes exist in `dartclaw_kernel` and are barrel-exported under one `show` clause
  - `packages/dartclaw_kernel/lib/src/full_text_index.dart` declares `SearchDocument`, `SearchResult`, and `abstract interface class FullTextIndex` with exactly the Technical Overview #1–#3 shapes and signatures (`userId` required everywhere, `limit` default `20`); constructors validate non-empty `id` and `chunks`. Follow `search_backend.dart#SearchBackend` for placement and dartdoc shape. The file names no memory vocabulary.
  - **Verify**: `cmd: rg -qU "full_text_index\.dart'\s*show[^;]*\bFullTextIndex\b" packages/dartclaw_kernel/lib/dartclaw_kernel.dart && rg -qU "full_text_index\.dart'\s*show[^;]*\bSearchDocument\b" packages/dartclaw_kernel/lib/dartclaw_kernel.dart && rg -qU "full_text_index\.dart'\s*show[^;]*\bSearchResult\b" packages/dartclaw_kernel/lib/dartclaw_kernel.dart && ! rg -qi "role|provenance|entry_id|entry_revision|locator|MemorySearchResult" packages/dartclaw_kernel/lib/src/full_text_index.dart && ! rg -q "String userId = " packages/dartclaw_kernel/lib/src/full_text_index.dart && dart analyze --fatal-infos packages/dartclaw_kernel` – the three types are exported under one `show`, no memory vocabulary and no `userId` default exist in the port, and the kernel analyzes clean
  - **SATISFIES**: S04, SC01, SC04

- **TI02** `MemoryIndexProjection` owns the memory vocabulary, chunking, and result reconstruction; `MemoryService` and `MemoryIndexRow` are gone
  - `packages/dartclaw_core/lib/src/memory/memory_index_projection.dart` provides `documents(CanonicalMemoryCorpus)`, a per-entry `document(...)` used by the pruner's legacy path, `toSearchResult(SearchResult)`, and `chunkCount(...)` per Technical Overview #7, reproducing `memory_service.dart#canonicalIndexRows`, `indexRows`, and `_searchResult` exactly; `memory_service.dart` is deleted, the barrel export line replaced by `export 'src/memory/memory_index_projection.dart' show MemoryIndexProjection;`, and the surviving `index rows` cases of `memory_service_test.dart` move to the new mapper test. Depends on TI01.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/memory/memory_index_projection_test.dart --plain-name "memory index projection" && ! rg -q "class (MemoryService|MemoryIndexRow)\b" packages apps` – a canonical corpus with topic, archive, observation, learning, error, and audit records projects only the four searchable roles with locator ids, `source == id`, per-role provenance/category/revision, the undated sentinel timestamp, Markdown normalization and paragraph chunking equal to the former `canonicalIndexRows` rows (scenario S03); reconstruction round-trips all nine `MemorySearchResult` fields with `entryRevision` as `int`, and a canonical role missing identity or carrying `entry_revision: 'seven'` throws `StateError` while a native role without identity does not (scenario S02); `! rg -q "class (MemoryService|MemoryIndexRow)\b" packages apps` exits 0
  - **SATISFIES**: S01, S02, S03, SC02, SC04

- **TI03** `SqliteFtsIndex` implements the port over `DatabaseBackend` against the S02-prepared store with keyed tenancy and unchanged FTS5 behavior
  - `packages/dartclaw_core/lib/src/search/sqlite_fts_index.dart` declares `SqliteFtsTable` (with `memoryChunks`), `SqliteFtsIndex(backend, table:)`, and `SqliteFtsIndex.withinTransaction(tx, table:)` per Technical Overview #3–#6; all SQL uses positional `?` through S01's `execute`/`query`/`transaction`; the read side keeps `COALESCE(locator, source)` as the id so no pre-0.24 row surfaces a null id; exported as `show SqliteFtsIndex, SqliteFtsTable`. Depends on TI01; consumes stories S01 and S02 as-is.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/search/sqlite_fts_index_test.dart --plain-name "SqliteFtsIndex" && ! rg -q "package:sqlite3" packages/dartclaw_core/lib/src/search/sqlite_fts_index.dart` – against a gate-prepared in-memory store: scenarios S04, S05, S06, S09 pass verbatim (read/overwrite/delete isolation with the same id under two users, `retire` and `replaceAll` per-user atomicity, `ArgumentError` with no partial write, encoder parity including the empty-encoding short circuit); `search` scores are negative and best-first; `listRecent` follows `created_at DESC` then rowid; `fetch` returns chunks in stored order; `count` with `{'role': 'topic'}` counts only that role's chunks; `verifyIntegrity` throws after the FTS5 shadow table is corrupted; a `withinTransaction` index writes inside an open `transaction()` without `NestedTransactionError` and its writes roll back with the body; and `! rg -q "package:sqlite3" packages/dartclaw_core/lib/src/search/sqlite_fts_index.dart` exits 0
  - **SATISFIES**: S01, S04, S05, S06, S09, SC02, SC03

- **TI04** Every memory consumer reaches the index through the port with explicit user scope
  - `Fts5SearchBackend(index:)` forwards natural language; `createSearchBackend(index:)`; `KnowledgeHubService.memory` is a `FullTextIndex` mapped through `MemoryIndexProjection.toSearchResult`; `createMemoryHandlers(memoryIndex:)` runs `reconcileCanonical` as `upsert(docs, userId:, retire: priorRecordIds)` → `indexAfterWrite` → `fetch`/`count` parity check → health, inside the same error boundary; `MemoryPruner(memoryIndex:)` writes `replaceAll`/`upsert` in its `afterCommit` callbacks; `MemoryStatusService.searchIndexCounter` uses `count(userId: 'owner', metadata: {'role': role})`; the `MemoryService` fields and getters in `server_deps.dart`, `server.dart`, `web_routes.dart`, `system_pages.dart`, `knowledge_hub_page.dart`, `harness_wiring.dart`, `scheduling_wiring.dart`, `service_wiring_builder.dart` carry the port type. Depends on TI02 and TI03.
  - **Verify**: `cmd: ! rg -q "MemoryService|MemoryIndexRow|encodeNaturalLanguageQuery" packages apps --glob '*.dart' --glob '!**/memory_index_projection*' && ! rg -q "searchDb\.select|FROM memory_chunks" packages/dartclaw_runtime/lib apps --glob '!**/test/**' --glob '!**/*_test.dart' && dart test --reporter=failures-only packages/dartclaw_core/test/search packages/dartclaw_core/test/memory/memory_pruner_test.dart packages/dartclaw_runtime/test/memory_handlers_test.dart packages/dartclaw_runtime/test/knowledge/knowledge_hub_service_test.dart packages/dartclaw_runtime/test/memory/memory_status_service_test.dart packages/dartclaw_runtime/test/api/memory_prune_test.dart` – no consumer names the retired types or runs raw SQL against `search.db`, and the search, pruner, handler, hub, status, and prune suites pass with unchanged assertions (scenario S01)
  - **SATISFIES**: S01, SC02

- **TI05** The composition root constructs the memory index over the seam and projects commits through it
  - In `storage_wiring.dart#StorageWiring.wire`: after the `search.db` open, wrap `_searchDb` in `SqliteBackend`, construct `SqliteFtsIndex(backend, table: SqliteFtsTable.memoryChunks)`, expose it as `FullTextIndex get memoryIndex` (the `MemoryService get memory` getter and the `DROP TABLE memory_chunks_fts` hack retire); when `_searchUnavailable`, prepare the in-memory store through `SqliteSchemaGate.prepareSearch` so the degraded path keeps its existing shape (the transitional gate reference story S06 absorbs); the post-commit projection writes `replaceAll` (complete) or `upsert(retire:)` (incremental), then `indexAfterWrite`, then `fetch`/`count` parity, then health, in the same order and error boundary; `_canonicalRowBatches` yields `List<SearchDocument>`; `dispose()` still closes `_searchDb` directly. Depends on TI03 and TI04.
  - **Verify**: `cmd: rg -q "SqliteFtsTable\.memoryChunks" packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart && ! rg -q "DROP TABLE memory_chunks_fts|MemoryService" packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart && ! rg -qi "backend\.close\(\)" packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart && dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/storage_wiring_memory_preflight_test.dart packages/dartclaw_runtime/test/mcp/memory_tools_test.dart packages/dartclaw_runtime/test/memory/memory_apply_service_test.dart` – wiring constructs the memory descriptor over the seam, no retired type or hack remains, wiring never closes the backend, and the preflight, memory-tool, and apply suites pass with unchanged assertions (scenario S07's write-through half)
  - **SATISFIES**: S07, SC05

- **TI06** Canonical index reconciliation and `rebuild-index` run on the seam with transitions, evidence, and output unchanged
  - `index_reconciler.dart` takes an injected store opener (`Future<(FullTextIndex, DatabaseBackend)> Function(String path)`, default: `openSearchDb` → `SqliteBackend` → `SqliteSchemaGate.prepareSearch(backend, storeName:)` → `SqliteFtsIndex` over `memoryChunks`) in place of `SearchDbFactory`; batches are `Stream<List<SearchDocument>>`; populate is `replaceAll(const [])` then per batch `upsert(docs, retire: ids)`; validation is `verifyIntegrity()`, per-batch `fetch` equality (id, chunks, metadata, timestamp), and a final `count == chunkCount`; the fast path performs the same reads; the seven `IndexReconcileTransition`s, sibling/backup/swap file mechanics, `replaceFile`, and every `IndexHealthStore` call keep their order. `rebuild_index_command.dart` streams `MemoryIndexProjection.documents(selection.corpus)` and prints the unchanged line. Depends on TI02, TI03.
  - **Verify**: `cmd: ! rg -q "package:sqlite3|SearchDbFactory|MemoryService" packages/dartclaw_core/lib/src/storage/index_reconciler.dart && dart test --reporter=failures-only packages/dartclaw_core/test/storage/index_reconciler_test.dart apps/dartclaw_cli/test/commands/rebuild_index_command_test.dart` – the reconciler imports no driver and no raw open helper, and both suites pass with every pre-existing assertion unchanged, including `Rebuilt index: 3 entries at collection revision 2` and the exact-zero-rows empty corpus (scenarios S07, S08)
  - **SATISFIES**: S07, S08, SC02, SC05

- **TI07** Architecture docs describe the port, the mapper, and the SQLite implementation
  - `dev/architecture/data-model.md` § Derived Memory Index Row describes `SearchDocument` (locator id, chunks, metadata keys, timestamp) projected by `MemoryIndexProjection` into `memory_chunks` through `SqliteFtsIndex`, with the searchable-role sentence gaining "never `error`"; its later `MemoryIndexRow`/`MemoryService` mentions and `dev/architecture/system-architecture.md`'s component-table row and startup-order line name the new types; bump each file's "Current through" marker. Public-repo doc edit executed in-milestone; no story IDs in the docs.
  - **Verify**: `cmd: ! rg -q "MemoryIndexRow|MemoryService\b" dev/architecture/data-model.md dev/architecture/system-architecture.md && rg -q "SqliteFtsIndex" dev/architecture/data-model.md && rg -q "FullTextIndex" dev/architecture/system-architecture.md` – no retired name survives in either doc and both name the new seam
  - **SATISFIES**: SC02

- **TI08** Zero-behavior-change and structural gates hold workspace-wide
  - Depends on TI01–TI07. If `arch_check` reports a crossed ceiling, apply the rebaseline protocol (ceiling change in `dev/tools/arch_check.dart#_libLocCeilings` plus a CHANGELOG note) in this same change.
  - **Verify**: `cmd: dart analyze --fatal-infos && test "$(rg -l "import 'package:sqlite3" packages apps --glob '!**/test/**' --glob '!**/*_test.dart' | wc -l | tr -d ' ')" = 16 && test "$(rg -l "MATCH|bm25\(|memory_chunks_fts" packages apps --glob '*.dart' --glob '!**/test/**' --glob '!**/*_test.dart' | sort)" = "$(printf '%s\n' packages/dartclaw_core/lib/src/search/sqlite_fts_index.dart packages/dartclaw_core/lib/src/storage/schema_identity.dart)" && ! rg -q "MATCH|bm25\(" packages/dartclaw_core/lib/src/storage/schema_identity.dart && bash dev/tools/test_workspace.sh && dart run dev/tools/arch_check.dart && bash dev/tools/fitness/run_all.sh && git diff --check` – analysis clean; the importer census is 16; the only production file with FTS5 SQL is the SQLite implementation; workspace suite, LOC/package ceilings, fitness suite, and whitespace check are green
  - **SATISFIES**: SC01, SC02, SC03, SC06

### Testing Strategy

- [TI03–TI06] Layer 2 against real SQLite: `SqliteBackend(sqlite3.openInMemory())` or a temp-file store, schema from `SqliteSchemaGate.prepareSearch` or the S02 `schema_fixtures.dart` DDL, never from code under test; raw `INSERT INTO memory_chunks` seeding in existing suites may stay (it exercises the S02 shape against the reader); no mocks, no private call-order assertions; never touch `Directory.current`.
- [TI03] Read, overwrite, and delete with the same id under two users are three separate assertions – each is a distinct confidentiality or integrity failure. Bound-asserting tests enumerate the surviving set (LEARNINGS: `unorderedEquals`, never `isNot(contains(...))`).
- [TI02] The projection test builds corpora from raw canonical documents (including `error` and `audit` members), not from the projection's own output.
- [TI06] Fault injection reuses the reconciler's existing `transitionHook` matrix; do not add a production fault seam. Test names used as Verify targets are group names the `--plain-name` selector matches.

### Execution Contract

- Stories S01 and S02 must be complete first; this story consumes `SqliteBackend`, `transaction()`, `SqliteSchemaGate.prepareSearch`, and the S02 fixtures as-is – if the prepared store cannot serve the implementation without schema code here, raise `CONFUSION:` rather than adding a local bootstrap. Order: TI01 → TI02 → TI03 → TI04 → TI05 → TI06 → TI07 → TI08. All commands run from the `../dartclaw-public/` root.
- The public working tree may carry another session's uncommitted edits outside this story's Work Areas; touch only the files named there.


## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Spec authors: leave this section empty._

### Run: 2026-09-05 08:35 UTC – repair-proof

#### DRIFT

- spec-stale: TI02 Verify target repaired | Stale targets: – | `packages/dartclaw_core/test/memory/memory_index_projection_test.dart#memory index projection` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/memory/memory_index_projection_test.dart --name "memory index projection"`

### Run: 2026-09-05 08:35 UTC – repair-proof

#### DRIFT

- spec-stale: TI03 Verify target repaired | Stale targets: – | `packages/dartclaw_core/test/search/sqlite_fts_index_test.dart#SqliteFtsIndex` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/search/sqlite_fts_index_test.dart --name "SqliteFtsIndex"`

### Run: 2026-09-05 08:39 UTC – repair-proof

#### DRIFT

- spec-stale: TI02 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/memory/memory_index_projection_test.dart --name "memory index projection"` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/memory/memory_index_projection_test.dart --plain-name "memory index projection"`

### Run: 2026-09-05 08:39 UTC – repair-proof

#### DRIFT

- spec-stale: TI03 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/search/sqlite_fts_index_test.dart --name "SqliteFtsIndex"` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/search/sqlite_fts_index_test.dart --plain-name "SqliteFtsIndex"`

### Run: 2026-09-05 08:42 UTC – repair-proof

#### DRIFT

- spec-stale: TI02 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/memory/memory_index_projection_test.dart --plain-name "memory index projection"` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/memory/memory_index_projection_test.dart --plain-name "memory index projection" && ! rg -q "class (MemoryService|MemoryIndexRow)\b" packages apps`

### Run: 2026-09-05 08:42 UTC – repair-proof

#### DRIFT

- spec-stale: TI03 Verify target repaired | Stale targets: – | `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/search/sqlite_fts_index_test.dart --plain-name "SqliteFtsIndex"` → `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/search/sqlite_fts_index_test.dart --plain-name "SqliteFtsIndex" && ! rg -q "package:sqlite3" packages/dartclaw_core/lib/src/search/sqlite_fts_index.dart`

### Run: 2026-09-08 11:48 UTC – repair-proof

#### DRIFT

- spec-stale: TI08 Verify target repaired | Stale targets: – | `cmd: dart analyze --fatal-infos && test "$(rg -l "import 'package:sqlite3" packages apps --glob '!**/test/**' --glob '!**/*_test.dart' | wc -l | tr -d ' ')" = 16 && test "$(rg -l "MATCH|bm25\(|memory_chunks_fts" packages apps --glob '*.dart' --glob '!**/test/**' --glob '!**/*_test.dart' | tr -d ' ')" = "packages/dartclaw_core/lib/src/search/sqlite_fts_index.dart" && bash dev/tools/test_workspace.sh && dart run dev/tools/arch_check.dart && bash dev/tools/fitness/run_all.sh && git diff --check` → `cmd: dart analyze --fatal-infos && test "$(rg -l "import 'package:sqlite3" packages apps --glob '!**/test/**' --glob '!**/*_test.dart' | wc -l | tr -d ' ')" = 16 && test "$(rg -l "MATCH|bm25\(|memory_chunks_fts" packages apps --glob '*.dart' --glob '!**/test/**' --glob '!**/*_test.dart' | sort)" = "$(printf '%s\n' packages/dartclaw_core/lib/src/search/sqlite_fts_index.dart packages/dartclaw_core/lib/src/storage/schema_identity.dart)" && ! rg -q "MATCH|bm25\(" packages/dartclaw_core/lib/src/storage/schema_identity.dart && bash dev/tools/test_workspace.sh && dart run dev/tools/arch_check.dart && bash dev/tools/fitness/run_all.sh && git diff --check`

### Run: 2026-09-08 11:48 UTC – observations

#### ASSUMPTIONS (AUTO_MODE)
- SC02 assigns runtime FTS operations to SqliteFtsIndex. S02 schema_identity.dart remains the declaration-only FTS table/trigger owner under SC03. TI08 therefore requires exactly those two production identifier owners and separately rejects MATCH/bm25 queries in the manifest. Independent bounded review passed; every other TI08 gate is unchanged.

### Run: 2026-09-08 13:13 UTC – observations

#### DRIFT

- spec-stale: The preparation's uniqueness claim for `SearchResult` missed the runtime web-search DTO. The distinct internal DTO is now `WebSearchResult`; the pinned kernel port type remains `SearchResult`.
- spec-stale: Opaque metadata round trips only within the fixed table descriptor's declared columns. Mutations reject unsupported, missing required, or non-canonical integer metadata with `ArgumentError`; filters that cannot match an accepted stored map return zero.
- spec-stale: The native source-label identity fallback conflicts with preserving multiple legacy entries from the same file. The legacy whole-corpus pruner assigns deterministic source-qualified ordinal locators; direct native projections retain the source fallback and canonical UUID identity is unchanged.

### Run: 2026-09-08 13:25 UTC – observations

#### DRIFT

- spec-stale: TI04's raw-SQL absence scan included CLI tests whose required rebuild assertions inspect `memory_chunks`. The repaired scan excludes test paths while retaining its production consumer scope and every required TI06 assertion.

### Run: 2026-09-08 13:25 UTC – repair-proof

#### DRIFT

- spec-stale: TI04 Verify target repaired | Stale targets: – | `cmd: ! rg -q "MemoryService|MemoryIndexRow|encodeNaturalLanguageQuery" packages apps --glob '*.dart' --glob '!**/memory_index_projection*' && ! rg -q "searchDb\.select|FROM memory_chunks" packages/dartclaw_runtime/lib apps && dart test --reporter=failures-only packages/dartclaw_core/test/search packages/dartclaw_core/test/memory/memory_pruner_test.dart packages/dartclaw_runtime/test/memory_handlers_test.dart packages/dartclaw_runtime/test/knowledge/knowledge_hub_service_test.dart packages/dartclaw_runtime/test/memory/memory_status_service_test.dart packages/dartclaw_runtime/test/api/memory_prune_test.dart` → `cmd: ! rg -q "MemoryService|MemoryIndexRow|encodeNaturalLanguageQuery" packages apps --glob '*.dart' --glob '!**/memory_index_projection*' && ! rg -q "searchDb\.select|FROM memory_chunks" packages/dartclaw_runtime/lib apps --glob '!**/test/**' --glob '!**/*_test.dart' && dart test --reporter=failures-only packages/dartclaw_core/test/search packages/dartclaw_core/test/memory/memory_pruner_test.dart packages/dartclaw_runtime/test/memory_handlers_test.dart packages/dartclaw_runtime/test/knowledge/knowledge_hub_service_test.dart packages/dartclaw_runtime/test/memory/memory_status_service_test.dart packages/dartclaw_runtime/test/api/memory_prune_test.dart`

### Run: 2026-09-08 13:34 UTC – observations

#### DRIFT
- spec-stale: The completed full-text seam migration measures `dartclaw_core` at exactly 27,942 production lines, 130 above the pinned 27,812 ceiling. The authorized exact rebaseline is recorded in `arch_check.dart` and the changelog with no headroom.

### Run: 2026-09-08 13:59 UTC – observations

2026-09-08 15:58 CEST: The independent gate identified three bounded correction families. The current non-batched reconciler path now verifies FTS integrity before comparing canonical documents; a real-file regression proves an intact schema/base table with corrupt FTS data is rebuilt. Added public-port falsifiers for duplicate IDs in one upsert (last occurrence wins) and immutable constructor/exposed collections. Existing real-backend contract coverage already enforces search limit, so no duplicate limit test was added. The canonical SearchDocument ID diagram now states entry UUID. Restoring the integrity call raises measured core lib LOC from 27942 to 27943; its exact ceiling and CHANGELOG measurement follow that one-line correction, with no headroom.
