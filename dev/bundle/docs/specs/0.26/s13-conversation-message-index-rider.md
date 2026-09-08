# FIS: Conversation-Message Index Rider

**Plan**: dev/bundle/docs/specs/0.26/plan.json
**Story-ID**: S13

_Refreshed 2026-09-02 against released 0.25 (public HEAD `daf5125a`), after the 2026-08-07 authoring and the 2026-08-14 refresh against 0.24. Version labels: 0.26 is this milestone (the PRD title still carries its pre-renumber label), released 0.25 is the compatibility baseline, 0.27 is the Chat milestone that consumes this index. The packages the prior FIS targeted are gone: `dartclaw_storage` was absorbed into `dartclaw_core`, `dartclaw_models` and `dartclaw_config` into `dartclaw_kernel`, `dartclaw_server` became `dartclaw_runtime`; every file this story touches survived under a new path, and `MessageService.insertMessage`, `<sessionsDir>/<id>/messages.ndjson`, `Message.id`, and the seven-value `SessionType` are unchanged. The five owner decisions of 2026-08-07 stand and are stated once each below. Code references (`packages/...`, `apps/...`, `dev/...`, `docs/guide/...`) are paths inside `../dartclaw-public/`; every command runs from that root._

## Feature Overview and Goal

**Intent**: Let a user find what was discussed and decided in past chat sessions, which today are the only primary content layer with no search path, without weakening the file-authoritative message store or mixing the memory corpus with conversation text.

**Expected Outcomes**:

- [OC01] Persisted `user` and `assistant` messages of chat-facing sessions are searchable through a dedicated conversation `FullTextIndex` instance on both backends, and a service-layer query returns scored hits carrying message id, session id, role, and timestamp.
- [OC02] `sessions/<id>/messages.ndjson` stays the sole authoritative store: message persistence never fails or waits on indexing, and the whole conversation corpus is reconstructible from NDJSON alone by `dartclaw rebuild-index` and survives a memory-index rebuild.
- [OC03] The index follows the session lifecycle: deleting, clearing, or archiving a session removes its rows, resuming an archived session restores them, and every index operation carries the contract's `userId` dimension.
- [OC04] On PostgreSQL the shared `fts_language` applies to conversation search (Swedish regular inflections match); SQLite keeps `unicode61` sanitized-term matching with no stemming and no prefix queries.


## Required Context

- `docs/specs/0.26/plan.json#sharedDecisions` – "FullTextIndex contract: corpus-agnostic, tenancy-carrying, two instances" (this story instantiates the port a second time; `user_id` on every operation; KG facts stay in `kg_facts`); "DatabaseBackend seam shape and placement under the 0.25 topology" (implementations in `dartclaw_core`, port types in `dartclaw_kernel`, LOC ceilings with the rebaseline protocol, 1500/1300-line file caps, explicit `show` clauses); "Schema compatibility: exact released 0.25 baseline, required-object manifests" (the conversation table joins the backend-owned manifests; the derived-store predicate is per corpus).
- `docs/specs/0.26/prd.md#fr11-conversation-message-index-rider-2026-08-07` – the acceptance criteria this story seeds: chat-facing types `user`/`main`/`channel` by one shared predicate; own table, never mixed with memory; write-through at append with the NDJSON path unchanged; `user_id` populated with the instance-owner identity; full rebuild from NDJSON under FR2's derived-store policy; session deletion removes rows; `fts_language` on PostgreSQL, sanitized `unicode61` on SQLite; service-layer search only; doc sync. **NOTICED**: the FR still names "0.26's Cmd+K" as the consumer and "0.25" as this milestone; read 0.27 and 0.26 respectively. The PRD amendment is owner-owned.
- `docs/specs/0.26/prd.md#edge-cases` – rows "`fts_language` changed with existing memory, conversation, and KG data" (conversation vectors stay on the old language until `rebuild-index`) and "Session deleted while its messages are indexed" (rows removed with the session; rebuild reconciles missed cleanup).
- `docs/specs/0.26/prd.md#data-requirements` – search-layer ownership: two `FullTextIndex` instances, separate tables; `rebuild-index` reconstructs memory from the canonical corpus and conversation messages from session NDJSON and rewrites neither KG facts nor wiki pages.
- `docs/specs/0.26/s03-fulltextindex-abstraction-and-fts5-implementation.md#technical-overview` – the pinned port this instance consumes verbatim: #1 `SearchDocument(id, chunks, metadata, timestamp)` and `SearchResult`; #2 `(userId, id)` identity; #3 operations (`search`, `listRecent`, `fetch`, `count`, `upsert(retire:)`, `delete`, `replaceAll`, `verifyIntegrity`); #4 natural-language `search` with the SQLite encoder quoting every surviving word; #5 `withinTransaction(tx, table:)`; #6 the `SqliteFtsTable` descriptor ("Story S13 adds a `conversation_chunks` descriptor"); #7 the memory vocabulary owned by `MemoryIndexProjection`, the projection-shape precedent for this story's mapper. `#implementation-tasks` – TI06: the reconciler streams documents and `rebuild-index` prints the unchanged `Rebuilt index:` line.
- `docs/specs/0.26/s02-sqlite-schema-bootstrap-and-compatibility-gate.md#technical-overview` – `SqliteSchemaGate.prepareSearch(backend, storeName:, rebuild:)` is the only DDL owner for `search.db`; the derived rebuild takes one populate/authenticate pair per corpus, and "S13 adds the conversation corpus". `#constraints--gotchas` – the required search manifest this story extends, and the derived-source boundary: completeness is per corpus, "zero chat-facing sessions is a complete empty source".
- `docs/specs/0.26/s07-opt-in-postgresbackend-core.md#technical-overview` – #10 `PostgresSchemaGate.prepare`: fresh bootstrap in one transaction, type mapping (`INTEGER PRIMARY KEY` → `bigint GENERATED BY DEFAULT AS IDENTITY`), catalog validation by name; the conversation table is added to this manifest in the same shape as `memory_chunks`.
- `docs/specs/0.26/s09-language-aware-postgresql-memory-and-kg-search.md#technical-overview` – #3 the `content_tsv tsvector NOT NULL` column and GIN index shape; #4 `PostgresFtsIndex(backend, {table, language})` and `PostgresFtsTable`, language bound as `?::regconfig` data; #6 `IndexRebuildTarget` – `SiblingFileRebuildTarget` swaps the whole `search.db` file on SQLite, `TransactionalRebuildTarget` replaces memory rows in one transaction on PostgreSQL; #7 `validatePostgresFtsLanguage` runs once before any index exists; #8 `rebuild-index` selects the backend by config. `#what-were-not-doing` – "The conversation corpus – story S13 supplies its own `PostgresFtsTable` descriptor and bootstrap".
- `docs/specs/0.26/s06-composition-root-wiring-and-census-closure.md#technical-overview` – the `wire()` order this story extends: 4a search gate with the S02 rebuild source (`populate(tx)` = `SqliteFtsIndex.withinTransaction`), 6 reconciliation, 7 search open and `SqliteFtsIndex` construction; every derived-store open passes through `prepareSearch` before an index is constructed.
- `docs/specs/0.26/s10-startup-interlock-and-backend-switch-semantics.md#structural-criteria` – SC05, the post-S10 `wire()` order this story's insertion points are defined against: the SQLite search steps above unchanged; 7b turn-state open and read-only scan; step 8 active store (`sqlite`: S14 adoption → open → `prepareTasks`; `postgres`: `PostgresBackend.open` → `PostgresInterlock.acquire` → `prepareAuthoritativeStore` → `validatePostgresFtsLanguage` → reconciliation; fatal, the interlock connection closing before the backend on any failure after acquire); 8a abandoned-store probe, never fatal. `s14-authoritative-store-rename.md#implementation-tasks` TI03 (adoption first inside step 8's `sqlite` try) and `s15-filesystem-backed-instance-local-state.md#implementation-tasks` TI03 (`openTurnStateStore(p.join(dataDir, 'turn_state.json'))`, moved to 7b by S10) – neither touches the search store.
- `../dartclaw-public/packages/dartclaw_core/lib/src/storage/message_service.dart#MessageService` – `insertMessage` appends one JSON line per message through a `BoundedWriteQueue`, assigns `Message.id` (UUID v4) and `createdAt` inside the queued op, tolerates malformed lines on read, and `clearMessages` truncates the file. The write path is unchanged by this story; it gains one post-append observer seam.
- `../dartclaw-public/packages/dartclaw_core/lib/src/storage/session_service.dart#SessionService` – `deleteSession` refuses `protectedTypes` (`main`, `channel`, `cron`, `task`) and removes the directory under the repo lock; `updateSessionType` rewrites `meta.json`; `listSessions(types:)` is the enumeration the rebuild reuses. Both gain one observer seam; no caller changes.
- `../dartclaw-public/packages/dartclaw_runtime/lib/src/session/session_reset_service.dart#SessionResetService` – the archive-reset path: keyed `main`/`channel`/`cron` sessions become `archive` type with their messages left on disk and a fresh session is created under the same key; unkeyed `user` sessions have `clearMessages` called. It never deletes.
- `../dartclaw-public/packages/dartclaw_runtime/lib/src/maintenance/session_maintenance_service.dart#SessionMaintenanceService` – archives stale and over-cap sessions through `updateSessionType(archive)`, deletes orphaned cron sessions (after retyping them `user`) and archived sessions over the disk budget through `deleteSession`.
- `../dartclaw-public/packages/dartclaw_kernel/lib/src/models.dart#SessionType` – the seven values; no chat-facing predicate exists at HEAD, this story defines it here. `#Message` – `cursor`, `id`, `sessionId`, `role`, `content`, `metadata`, `createdAt`; `cursor` is derived on read and never stored.
- `../dartclaw-public/dev/state/LEARNINGS.md#concurrency--async` – serialize fire-and-forget writes through a pending-future chain; wrap with a caught-and-logged handler. `#storage--data-model` – "FTS5 MATCH has special operators" (encoding is the index's job); the 0.25.1 entry "Fingerprint the corpus replacement at the current revision, bump only on commit" (a no-op memory prune no longer bumps `Collection-Revision`, so memory reconciliation runs less often; this story's re-projection piggybacks only on real rebuilds). `#package-architecture` – "Green tests can mask unwired features" (the lifecycle proofs run through the real reset and maintenance services).
- `docs/specs/0.26/launch-context.md` – the live session/message lifecycle, search, topology, LOC, and 0.27-boundary evidence that supersede both temporary re-plan audits.


## Deeper Context

- `docs/specs/0.next-chat-and-sessions/prd-brief.md#phase-c--navigation-attention-keyboard` – TR-4, the global Cmd+K palette, explicitly consumes the conversation-message `FullTextIndex` and service query path delivered here. `docs/specs/0.next-ui-ux-improvements/cross-surface-ux-plan-2026-06.md#5-resolved-decisions-operator-2026-06-10-amended-2026-07-04` – D7's timing was amended when TR-4 moved to Chat & Session Experience; this story remains the producer half only.
- `../dartclaw-public/dev/adrs/002-file-based-storage.md#decision` – files-authoritative rationale the derived index must not erode.
- `../dartclaw-public/dev/adrs/045-pluggable-database-backend.md#fts-abstraction` – the `user_id` filter is the isolation mechanism; `#configuration` – `fts_language` under `database.*`.
- `../dartclaw-public/dev/architecture/data-model.md#message` and `#derived-memory-index-row` – the sections TI08 extends; `../dartclaw-public/docs/guide/search.md#memory-search` and `../dartclaw-public/docs/guide/workspace.md#directory-layout` – the user-guide sections; `../dartclaw-public/dev/state/UBIQUITOUS_LANGUAGE.md` rows `Full-Text Index` and `Search Index`.
- `../dartclaw-public/dev/guidelines/TESTING-STRATEGY.md#layer-2--component--integration-tests` – real temp-dir NDJSON and real in-memory SQLite, no mocks; `#layer-4--live-integration--e2e-tests` – `@Tags(['integration'])`, `dart test --run-skipped -t integration`.
- `docs/specs/0.26/s13-conversation-message-index-fis-doc-review-claude-2026-08-07.md` – the review whose five blockers the owner settled on 2026-08-07.


## Acceptance Scenarios

- **S01 [OC01] [TI03,TI04,TI05] A chat turn becomes searchable with provenance through any persistence path**
  - **Given** a `user` session where `How do we configure the webhook retry policy?` was persisted as role `user` and an `assistant` reply mentioning `retry policy` was persisted through `MessageService.insertMessage` by a different caller than the HTTP route (the turn loop's assistant persistence)
  - **When** the conversation search service searches `retry policy` for the instance owner
  - **Then** it returns both messages as scored hits, best-first by backend score, each carrying the persisted `Message.id`, the session id, the role, and the message's UTC `createdAt`; a hit's text is the message content only

- **S02 [OC01] [TI01,TI03,TI04] Internal roles and non-chat session types stay out of the corpus**
  - **Given** a `system` message in that `user` session, and `assistant` messages containing the same searched text in a `task` session, a `cron` session, a `logicalAgent` session, and an `archive` session
  - **When** conversation search runs a query matching that text
  - **Then** none of them is returned or present in the conversation corpus; the corpus holds exactly the `user`/`assistant` messages of `user`, `main`, and `channel` sessions, decided by the one predicate declared beside `SessionType`

- **S03 [OC03] [TI04] Session deletion removes its rows and a refused deletion removes nothing**
  - **Given** two sessions with indexed messages, one `user` and one `channel`
  - **When** `SessionService.deleteSession` runs for the `user` session and then for the `channel` session
  - **Then** the `user` session's directory is gone and conversation search returns none of its messages while the `channel` session's hits are unchanged; the second call throws `StateError` and the `channel` session's rows stay searchable
  - **Proof**: `packages/dartclaw_core/test/storage/session_service_test.dart#deleteSession` – green – parity/regression (protected-type refusal and directory removal; the index half is red at spec time in TI04's suite)

- **S04 [OC03] [TI04] Archive-reset, maintenance archiving, and in-place clear remove rows; resume restores them**
  - **Given** an indexed keyed `channel` session, an indexed stale `user` session, and an indexed unkeyed `user` session, composed with the real `SessionResetService` and `SessionMaintenanceService`
  - **When** `SessionResetService.resetSession` runs for the `channel` session (archive plus fresh replacement), `SessionMaintenanceService.run` in enforce mode archives the stale session, `resetSession` clears the unkeyed session, and then the maintenance-archived session is resumed through `SessionService.updateSessionType(id, SessionType.user)`
  - **Then** after each transition the affected session's messages are absent from conversation search while the others are unchanged, the archived sessions' `messages.ndjson` files are untouched, and after the resume that session's messages are searchable again, re-projected from its NDJSON

- **S05 [OC02] [TI03,TI07] `rebuild-index` reconstructs the corpus from NDJSON alone**
  - **Given** an empty canonical memory corpus, session NDJSON containing three `user`/`assistant` messages across two chat-facing sessions plus one `system` line and one malformed line, a `task` session with two messages, and stale rows in the conversation corpus
  - **When** `dartclaw rebuild-index` runs
  - **Then** it prints the unchanged memory line followed by a line beginning `Rebuilt conversation index: 3 messages from 2 sessions`, a subsequent search matches exactly the three messages, the stale rows are gone, and `--json` carries `conversationMessages: 3` and `conversationSessions: 2` beside the existing keys
  - **Proof**: `apps/dartclaw_cli/test/commands/rebuild_index_command_test.dart#rebuilds the index from a canonical corpus` – green – parity/regression (the memory line and JSON keys are unchanged; the conversation half is red at spec time in TI07's suite)

- **S06 [OC02] [TI06] A memory-index rebuild never loses the conversation corpus**
  - **Given** a SQLite deployment with indexed conversation messages whose memory index evidence is stale, so startup reconciliation takes the rebuild path and publishes a new `search.db` by sibling-file swap
  - **When** `StorageWiring.wire()` completes
  - **Then** conversation search finds the messages, re-projected from NDJSON after the swap; when reconciliation takes the fast path instead, no re-projection runs and the rows are untouched

- **S07 [OC02] [TI04] Index failure never blocks or fails message persistence**
  - **Given** a conversation index whose every operation throws (a failing `DatabaseBackend` beneath it)
  - **When** a chat message is persisted through `insertMessage`
  - **Then** the call completes with the message in `messages.ndjson`, the failure is logged once as a warning, no unhandled asynchronous error surfaces, and a later `rebuild-index` against a working store makes the message searchable
  - **Proof**: `packages/dartclaw_core/test/storage/message_service_test.dart#insertMessage` – green – parity/regression (the NDJSON write path; the failing-index half is red at spec time in TI04's suite)

- **S08 [OC04] [TI03,TI05] [runtime] Swedish inflections match on PostgreSQL and not on SQLite**
  - **Given** `fts_language: swedish` on PostgreSQL and an indexed `assistant` message `hunden springer snabbt`, and the same message indexed on the SQLite default
  - **When** conversation search runs `springa` on each backend
  - **Then** PostgreSQL returns the message and SQLite returns zero hits – the SQLite encoder double-quotes the term, so neither stemming nor prefix expansion applies; a language change on PostgreSQL reaches conversation search only after `rebuild-index`

- **S09 [OC03] [TI02,TI03] Tenancy isolation holds on the conversation descriptor**
  - **Given** conversation documents upserted for `owner` and `other` under the same document id on the conversation table, on both backends
  - **When** search, `fetch`, `upsert`, `delete`, and `replaceAll` run scoped to `owner`
  - **Then** no operation reads, overwrites, or removes `other`'s document, and no conversation row appears in any memory-corpus query


## Structural Criteria

- **SC01** The conversation corpus is the separate table `conversation_chunks` with its own FTS objects on both backends; `memory_chunks` DDL and every memory suite are unchanged, and no production path writes a message into the memory corpus.
- **SC02** The chat-facing predicate is declared exactly once, beside `SessionType` in `packages/dartclaw_kernel/lib/src/models.dart`; the projection, indexer, and rebuild consume it and none re-enumerates `SessionType` members.
- **SC03** Every `insertMessage`, `clearMessages`, `deleteSession`, and `updateSessionType` caller is untouched: indexing and cleanup enter through observer seams on `MessageService` and `SessionService`, composed only in `StorageWiring.wire()` and `RebuildIndexCommand`; `InMemorySessionService` still implements `SessionService`.
- **SC04** The S02 search manifest and the S07/S09 PostgreSQL manifest carry the conversation objects; the S02 derived rebuild runs a conversation populate/authenticate pair beside memory's; a `search.db` lacking the conversation table classifies as incompatible and rebuilds.
- **SC05** No new HTTP route, Web UI surface, or MCP/agent tool exists for conversation search; the query path is reachable only through `StorageWiring`.
- **SC06** `dev/architecture/data-model.md`, `docs/guide/search.md`, `docs/guide/workspace.md`, and the glossary describe two `FullTextIndex` instances and the conversation rebuild.
- **SC07** Governance: workspace analysis, the fitness suite, `arch_check` (LOC ceilings with the recorded-rebaseline protocol, 12-package ceiling), and `git diff --check` are green; new exports carry `show`; no lib file exceeds 1500 lines and no test file 1300; no retired package or file name appears in anything this story touches.


## Scope & Boundaries

### Work Areas

- Kernel predicate: `packages/dartclaw_kernel/lib/src/models.dart` (`SessionType.isChatFacing`) (TI01)
- Schema: `packages/dartclaw_core/lib/src/storage/schema_identity.dart` (S02 search manifest), `postgres_schema_gate.dart` (S07/S09 manifest and bootstrap) (TI02)
- Descriptors and projection: `packages/dartclaw_core/lib/src/search/sqlite_fts_index.dart` (`SqliteFtsTable.conversationChunks`), `postgres_fts_index.dart` (`PostgresFtsTable.conversationChunks`), new `packages/dartclaw_core/lib/src/search/conversation_index_projection.dart` (`ConversationIndexProjection`) (TI03)
- Write-through and lifecycle: `packages/dartclaw_core/lib/src/storage/message_service.dart`, `session_service.dart` (observer seams), new `packages/dartclaw_core/lib/src/search/conversation_indexer.dart` (`ConversationIndexer`), `packages/dartclaw_testing/lib/src/in_memory_session_service.dart` (TI04)
- Query path: new `packages/dartclaw_core/lib/src/search/conversation_search_service.dart` (`ConversationSearchService`, `ConversationHit`) (TI05)
- Composition root: `packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart` – second index instance on both backends, observer registration, the gate's conversation populate/authenticate pair, post-rebuild re-projection, getters; `packages/dartclaw_core/lib/src/storage/index_reconciler.dart` (`IndexReconcileResult.rebuilt`) (TI06)
- CLI: `apps/dartclaw_cli/lib/src/commands/rebuild_index_command.dart` (TI07)
- Docs: `dev/architecture/data-model.md`, `docs/guide/search.md`, `docs/guide/workspace.md`, `dev/state/UBIQUITOUS_LANGUAGE.md` (TI08)
- Tests: new `packages/dartclaw_core/test/search/conversation_index_projection_test.dart`, `conversation_indexer_test.dart`, `conversation_index_postgres_live_test.dart`; new `packages/dartclaw_runtime/test/session/session_lifecycle_conversation_index_test.dart`, `packages/dartclaw_runtime/test/runtime/storage_wiring_conversation_index_test.dart`; new `apps/dartclaw_cli/test/commands/rebuild_index_conversation_test.dart`; extended `sqlite_fts_index_test.dart`, `sqlite_schema_gate_search_test.dart`, `postgres_schema_gate_live_test.dart`, `in_memory_session_service_test.dart` (TI02–TI07)

### What We're NOT Doing

_(`S<NN>` outside `## Acceptance Scenarios` names a plan story; inside it, a scenario ID.)_

- Per-user session ownership – sessions carry no owner field; every conversation-index operation uses the instance-owner constant `'owner'`, exactly as the memory corpus does (owner decision 2026-08-07). Inventing session ownership is out of scope.
- UI, HTTP, or agent exposure – 0.27's Cmd+K palette (TR-4) consumes the service-layer path; Cross-Session Recall (summarization, agent recall tooling) stays in the backlog.
- Chunking long messages – one document with one chunk per message; revisit only on a measured relevance problem.
- Indexing `system` messages, message `metadata` JSON, attachments, or `task`/`cron`/`logicalAgent`/`archive` sessions – only `user`/`assistant` `content` of chat-facing sessions is recall material.
- Changing the port, the reconciler's transitions, health evidence, the `Rebuilt index:` line, or the QMD, wiki, KG, and task search paths – stories S03/S09 own them; this story adds one additive field to `IndexReconcileResult` and nothing else there.


## Architecture Decision

**Approach**: Instantiate the S03 port a second time over a `conversation_chunks` descriptor on both backends (`SqliteFtsIndex` / `PostgresFtsIndex`), with one document per persisted `user`/`assistant` message identified by `Message.id`; feed it through observer seams on `MessageService` and `SessionService` (the `MemoryCorpusService.registerPostCommitProjection` shape) so every caller is covered without per-call-site hooks; rebuild it from NDJSON as its own step of `rebuild-index` and after any memory-index rebuild. See ADR: `../dartclaw-public/dev/adrs/045-pluggable-database-backend.md` (§ FTS Abstraction); files-authoritative posture: `../dartclaw-public/dev/adrs/002-file-based-storage.md`.
**Why this over alternatives**: the prior FIS composed the hook at the server and CLI roots because `dartclaw_core` could not see the storage package; at 0.25 both live in `dartclaw_core` and `insertMessage` has twelve production call sites across seven files, so a per-site hook would miss the guard-block, turn-failure, and harness-routed assistant messages; a separate `conversations.db` would dodge the sibling-swap interaction but contradicts S02's search manifest, S03's descriptor design, and adds a third SQLite file the PostgreSQL posture is trying to shed.


## Technical Overview

1. **Predicate** (kernel, `models.dart`): `bool get isChatFacing` on `SessionType` – `true` for `user`, `main`, `channel`; `false` for `task`, `cron`, `logicalAgent`, `archive` (owner decision 2026-08-07: chat-facing only). It is the only place the set is spelled out.
2. **Document mapping** (`ConversationIndexProjection`, core): `SearchDocument(id: message.id, chunks: [message.content], metadata: {'session_id': sessionId, 'role': role}, timestamp: createdAt.toUtc())` for a `user` or `assistant` message whose session type `isChatFacing`; `null` otherwise. `Message.id` is the persisted collision-free UUID, identical on write-through and rebuild (owner decision 2026-08-07); `cursor` is never used in identity or metadata. `created_at` is the port's document timestamp, not metadata. `metadata` JSON is never indexed. `documents(sessionsDir)` enumerates chat-facing sessions through `SessionService.listSessions(types:)` and reads each `messages.ndjson` through `MessageService.getMessages` (malformed lines skipped as today), yielding per-session document batches plus the counts the CLI prints; `populate(tx)` and `rebuild(index)` both use it (`replaceAll` for owner, then per-session `upsert`).
3. **Table shape** (owner decision 2026-08-07, named projection columns, no key-value metadata storage): SQLite `conversation_chunks(id INTEGER PRIMARY KEY AUTOINCREMENT, message_id TEXT NOT NULL, user_id TEXT NOT NULL, text TEXT NOT NULL, session_id TEXT NOT NULL, role TEXT NOT NULL, created_at TEXT NOT NULL)`, FTS5 `conversation_chunks_fts(body)` with external content `conversation_chunks` / rowid `id`, triggers `conversation_chunks_ai/ad/au` – the `memory_chunks` pattern. The integer `id` is the FTS5 content rowid exactly as `memory_chunks.id` is, and `message_id` is the document-id column exactly as `locator` is; this is the decision's column list with the rowid the pattern requires, not a reopening. PostgreSQL: the same columns under S07's type mapping plus `content_tsv tsvector NOT NULL` and GIN `conversation_chunks_content_tsv_idx`, language never in DDL (S09 #3). Descriptors: `SqliteFtsTable.conversationChunks` (id `message_id`, text `text`, timestamp `created_at`, user `user_id`, metadata keys `session_id`, `role`) and `PostgresFtsTable.conversationChunks` (same plus `contentTsv`).
4. **Observer seams**: `MessageService` accepts one optional observer notified after a message's line is durably appended (with the completed `Message`) and after `clearMessages` truncates (with the session id and the ids that were on disk before truncation); `SessionService` accepts one optional observer notified before `_deleteSessionLocked` removes the directory (session id, the type read from `meta.json`) and after `updateSessionType` persists (session id, old type, new type). Notifications are synchronous calls returning `void` inside the service's own error boundary; the services never await index work and never propagate an observer failure. `InMemorySessionService` gains the same constructor parameter and calls it from its delete and retype paths.
5. **`ConversationIndexer`** (core) implements the observers over `(FullTextIndex index, SessionService sessions, MessageService messages, userId: 'owner')`: append → `document(...)` (session type read once per append through `getSession`, cacheable) → `upsert`; clear → `delete(ids)`; before-delete → enumerate the session's ids from NDJSON, then `delete`; type change → `delete` when the new type is not chat-facing, re-project the session's NDJSON (`upsert`) when it becomes chat-facing. All index work is chained on one pending future (LEARNINGS § Concurrency / Async), each step wrapped so a failure is logged once at warning and the chain continues; `Future<void> get idle` awaits the chain (tests and the rebuild ordering use it). Missed cleanup is reconciled by the next rebuild.
6. **`ConversationSearchService`** (core): `Future<List<ConversationHit>> search(String query, {int limit = 20})` over the owner scope; `ConversationHit(messageId, sessionId, role, createdAt, text, score)` mapped from `SearchResult` (id, metadata, timestamp, chunk, score). An unavailable index yields an empty list with one logged warning, never a throw and never out-of-scope results (FR11 Error Handling). No route, page, or tool registers it.
7. **Rebuild interaction**: `IndexReconcileResult` gains `bool rebuilt` (false on the fast path). In `StorageWiring.wire()`, after the search store is open and both index instances exist, if reconciliation ran the rebuild path the conversation corpus is re-projected (`ConversationIndexProjection.rebuild`) before search is served, non-fatally (a failure logs severe and leaves the rows as they are). On SQLite this is load-bearing: the S09 sibling-file target publishes a fresh `search.db` whose conversation table is empty. On PostgreSQL the transactional target leaves the rows in place and the re-projection is a harmless refresh; one rule, both backends. The S02 gate's derived rebuild (incompatible `search.db`) receives the conversation populate/authenticate pair beside memory's: `populate(tx)` writes through `SqliteFtsIndex.withinTransaction(tx, table: conversationChunks)`; `authenticateComplete` re-lists chat-facing sessions and confirms the set of `(sessionId, line count)` is what was projected. Zero chat-facing sessions is a complete empty source (owner decision 2026-08-07).
8. **`rebuild-index`**: after the memory reconcile returns, open the published store the way the reconciler's default opener does on SQLite (S03 TI06: `SqliteBackend` → `prepareSearch` → index), or reuse the already-open PostgreSQL backend (S09 #8), construct the conversation index with the validated language, run `rebuild`, print `Rebuilt conversation index: N messages from M sessions`, add `conversationMessages` and `conversationSessions` to `--json`, close what this step opened. An absent or empty `sessionsDir` is zero sessions: the corpus is cleared and the line prints `0 messages from 0 sessions`. The memory line, keys, and order are unchanged (the Windows gate matches `Rebuilt index:`; the new line does not contain that substring). Description: "Rebuild the memory and conversation search indexes offline (stop DartClaw first)".
9. **Composition** (`StorageWiring.wire()`): both instances share the search store's backend (SQLite: `SqliteFtsIndex(backend, table: conversationChunks)` after step 7's `prepareSearch`; PostgreSQL: `PostgresFtsIndex(backend, table: conversationChunks, language:)` after S09's validation); `ConversationIndexer` is constructed and registered on `_messages` and `_sessions` before `getOrCreateMainSession` returns control to later wiring; when `_searchUnavailable` the indexer is registered over the in-memory fallback so persistence behaviour is identical. Exposed: `FullTextIndex get conversationIndex`, `ConversationSearchService get conversationSearch`. `dispose()` awaits `indexer.idle` before closing the store.


## Code Patterns & External References

```
# type | path#anchor                                                                                                         | why needed (intent)
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/memory/memory_index_projection.dart#MemoryIndexProjection          | as landed by story S03: corpus → SearchDocument mapper shape to mirror for messages
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/search/sqlite_fts_index.dart#SqliteFtsTable                         | as landed by story S03: descriptor fields the conversationChunks descriptor fills
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/search/postgres_fts_index.dart#PostgresFtsTable                      | as landed by story S09: descriptor plus contentTsv; language bound as data
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/schema_identity.dart#SchemaIdentity                          | as landed by story S02: required-object descriptors the conversation objects join
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/postgres_schema_gate.dart#PostgresSchemaGate                 | as landed by stories S07/S09: bootstrap and catalog validation the conversation objects join
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/memory/memory_corpus_service.dart#registerPostCommitProjection       | the store-owned post-commit hook shape the observer seams follow
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/message_service.dart#insertMessage                          | queued append; the observer fires after completer completion, never inside the write op
file   | ../dartclaw-public/packages/dartclaw_core/lib/src/storage/session_service.dart#_deleteSessionLocked                    | where the before-delete notification sits (after the protected-type check, before dir.delete)
file   | ../dartclaw-public/packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart#StorageWiring.wire                    | step 1 service construction, 4a gate source, 6 reconciliation, 7 search open, 8 `postgres` branch (S10 SC05) – the insertion points
file   | ../dartclaw-public/packages/dartclaw_runtime/lib/src/memory_handlers.dart#createMemoryHandlers                        | the async, health-gated write-through error boundary (await inside the try) to mirror in the indexer
file   | ../dartclaw-public/apps/dartclaw_cli/lib/src/commands/rebuild_index_command.dart#RebuildIndexCommand                  | preflight → manifest → reconcile → print flow; the conversation step follows the reconcile
file   | ../dartclaw-public/packages/dartclaw_testing/lib/src/in_memory_session_service.dart#InMemorySessionService             | implements SessionService – must gain the new member
file   | ../dartclaw-public/packages/dartclaw_core/test/storage/message_service_test.dart                                       | temp-dir NDJSON fixture conventions for the indexer suite
file   | ../dartclaw-public/packages/dartclaw_runtime/test/maintenance/session_maintenance_service_test.dart                    | enforce-mode fixture shape for the lifecycle suite
file   | ../dartclaw-public/packages/dartclaw_core/test/storage/postgres_live_support.dart                                      | as landed by story S07: DARTCLAW_TEST_POSTGRES_URL, fail loud without it
```


## Constraints & Gotchas

- **Critical**: the observer seams are the whole coverage story. `rg -n "\.insertMessage\(" packages apps --glob '!**/*_test.dart'` matches twelve production sites in seven `dartclaw_runtime` files at HEAD; none of them changes, and no second indexing entry point may be added at a call site.
- **Critical**: index work never runs inside `MessageService`'s write queue or `SessionService`'s repo-lock body beyond enumerating ids; the indexer chains its own work and the services return as before. An `await` of index work inside the queued op would make scenario S07 impossible.
- **Critical**: on SQLite a memory-index rebuild replaces the whole `search.db` file (S09 `SiblingFileRebuildTarget`). Any path that rebuilds memory must be followed by the conversation re-projection (Technical Overview #7/#8) or every conversation row is silently lost.
- **Constraint**: `userId` is `'owner'` at every production call, as in the memory corpus; no per-user session ownership exists.
- **Constraint**: query encoding is the index's job (S03 #4, S09 #4) – the search service passes natural language through; no second sanitizer.
- **Constraint**: schema ownership – S02's `SqliteSchemaGate` and S07's `PostgresSchemaGate` are the only DDL owners; this story adds descriptors to their manifests and bootstrap data, never a local `CREATE`.
- **Constraint**: the S09 language validation runs once per process before any `PostgresFtsIndex` exists; the conversation instance is constructed after it, in wiring and in `rebuild-index`.
- **Constraint**: `dartclaw_core` LOC (measured 2026-09-02 by S03: 26269 of 27740, before S07/S09 growth). This story adds roughly 500–700 core lib lines; a crossed ceiling takes the recorded-rebaseline protocol (`dev/tools/arch_check.dart#_libLocCeilings` plus a CHANGELOG `### Changed` note in the same change). No lib file over 1500 lines, no test file over 1300, no public constructor over 12 parameters.
- **Constraint**: comments are rationale-only; no story IDs in code, dartdoc, CHANGELOG, or user-facing text; en dashes only.


## Implementation Plan

### Implementation Tasks

- **TI01** `SessionType` exposes the one chat-facing predicate
  - Technical Overview #1 in `packages/dartclaw_kernel/lib/src/models.dart`, dartdoc naming the contract (chat-facing sessions are indexed; internal and archived are not).
  - **Verify**: `cmd: rg -q "bool get isChatFacing" packages/dartclaw_kernel/lib/src/models.dart && dart test --reporter=failures-only packages/dartclaw_kernel/test --name "isChatFacing"` – the getter exists and the kernel test enumerates all seven values with the expected verdicts (scenario S02's predicate half)
  - **SATISFIES**: S02, SC02

- **TI02** Both schema gates carry the conversation objects and the S02 derived rebuild accepts a second corpus pair
  - Technical Overview #3 into `schema_identity.dart` (search manifest: table, FTS5 table, three triggers) and `postgres_schema_gate.dart` (table, `content_tsv`, GIN index); `prepareSearch`'s rebuild source accepts a list of populate/authenticate pairs (memory's stays first). Depends on stories S02, S07, S09.
  - **Verify**: `cmd: rg -q "conversation_chunks" packages/dartclaw_core/lib/src/storage/schema_identity.dart packages/dartclaw_core/lib/src/storage/postgres_schema_gate.dart && ! rg -qi "english|swedish|regconfig" packages/dartclaw_core/lib/src/storage/postgres_schema_gate.dart && dart test --reporter=failures-only packages/dartclaw_core/test/storage/sqlite_schema_gate_search_test.dart && test -n "$DARTCLAW_TEST_POSTGRES_URL" && dart test --run-skipped -t integration --reporter=failures-only packages/dartclaw_core/test/storage/postgres_schema_gate_live_test.dart` – both manifests name the table and no language leaks into DDL; the SQLite suite proves fresh bootstrap creates the conversation objects, a store with `memory_chunks` but no `conversation_chunks` classifies incompatible and rebuilds through both pairs (an empty conversation source yields zero rows and commits), and a failing conversation populate rolls the whole rebuild back; the live suite proves the PostgreSQL bootstrap and a missing GIN index refusing
  - **SATISFIES**: S09, SC01, SC04

- **TI03** Descriptors and the projection map messages to documents and enumerate NDJSON
  - Technical Overview #2 and #3: `SqliteFtsTable.conversationChunks`, `PostgresFtsTable.conversationChunks`, `ConversationIndexProjection` (`document`, `documents`, `rebuild`, `populate`), `show`-exported; `sqlite_fts_index_test.dart` gains a `conversationChunks` group; new `conversation_index_projection_test.dart`; new `conversation_index_postgres_live_test.dart` (`@Tags(['integration'])`). Depends on TI01, TI02.
  - **Verify**: `cmd: ! rg -q "SessionType\.(user|main|channel|task|cron|logicalAgent|archive)" packages/dartclaw_core/lib/src/search/conversation_index_projection.dart && dart test --reporter=failures-only packages/dartclaw_core/test/search/conversation_index_projection_test.dart packages/dartclaw_core/test/search/sqlite_fts_index_test.dart && test -n "$DARTCLAW_TEST_POSTGRES_URL" && dart test --run-skipped -t integration --reporter=failures-only packages/dartclaw_core/test/search/conversation_index_postgres_live_test.dart` – the projection names no enum member; the projection suite proves scenario S02's mapping half (`system` and non-chat sessions map to `null`, id equals `Message.id`, chunk equals `content`, timestamp is UTC, metadata is exactly `session_id` and `role`) and scenario S05's enumeration half (three documents from two sessions, `task` session and malformed line skipped); the SQLite suite proves scenario S09 on the conversation descriptor and that `springa` misses `springer`; the live suite proves scenario S09 and the PostgreSQL half of scenario S08 (`springa` finds `hunden springer snabbt` under `swedish`, not under `english`)
  - **SATISFIES**: S02, S05, S08, S09, SC01, SC02

- **TI04** Every persisted message and every lifecycle transition reaches the indexer through the store-owned seams, non-fatally
  - Technical Overview #4 and #5: observer seams on `MessageService` and `SessionService`, `InMemorySessionService` updated, `ConversationIndexer` with the pending chain and `idle`. New `conversation_indexer_test.dart` (real temp-dir services, gate-prepared in-memory `SqliteBackend`, S02's `failing_database_backend.dart` for the failure case) and `session_lifecycle_conversation_index_test.dart` (real `SessionResetService` and `SessionMaintenanceService` composed over the indexer). Depends on TI03.
  - **Verify**: `cmd: ! rg -q "ConversationIndexer|ConversationIndexProjection" packages/dartclaw_runtime/lib apps/dartclaw_cli/lib --glob '!**/storage_wiring.dart' --glob '!**/rebuild_index_command.dart' && dart test --reporter=failures-only packages/dartclaw_core/test/search/conversation_indexer_test.dart packages/dartclaw_runtime/test/session/session_lifecycle_conversation_index_test.dart packages/dartclaw_testing/test/in_memory_session_service_test.dart packages/dartclaw_core/test/storage/message_service_test.dart packages/dartclaw_core/test/storage/session_service_test.dart` – no call-site file names the indexer; the indexer suite proves scenarios S01 (two roles, provenance, best-first), S02 (system and non-chat messages absent), S03 (delete removes, refused delete removes nothing), S07 (failing index: `insertMessage` completes, line on disk, one warning, no unhandled error), and clear/retype transitions at the seam; the lifecycle suite proves scenario S04 through the real reset and maintenance services including the resume re-projection; the fake and the two store suites pass unchanged
  - **SATISFIES**: S01, S02, S03, S04, S07, SC03

- **TI05** A service-layer conversation search returns provenance-bearing scored hits and degrades to empty
  - Technical Overview #6, `show`-exported; tests live in `conversation_indexer_test.dart` (SQLite) and `conversation_index_postgres_live_test.dart` (PostgreSQL). Depends on TI03.
  - **Verify**: `cmd: ! rg -q "ConversationSearchService|conversationSearch" packages/dartclaw_runtime/lib apps/dartclaw_cli/lib --glob '!**/storage_wiring.dart' && dart test --reporter=failures-only packages/dartclaw_core/test/search/conversation_indexer_test.dart --name "ConversationSearchService"` – no route, page, tool, or CLI command reaches the search service (only the wiring getter names it); the group proves scenario S01's hit shape (`messageId == Message.id`, `sessionId`, `role`, UTC `createdAt`, `text == content`, ordered by score) and that a failing index returns `[]` with one warning
  - **SATISFIES**: S01, S08, SC05

- **TI06** The composition root serves two index instances on both backends, registers the indexer, and re-projects after a memory rebuild
  - Technical Overview #7 and #9 against the post-S10 `wire()` (S10 SC05). `sqlite`: insertion points unchanged – the step 4a gate source gains the conversation populate/authenticate pair, the re-projection follows step 6 when `rebuilt`, `SqliteFtsIndex(backend, table: conversationChunks)` is constructed after step 7's `prepareSearch`; 7b, step 8's `sqlite` try, and 8a are not touched. `postgres`: the second instance lands inside step 8's `postgres` branch after `PostgresInterlock.acquire` → `prepareAuthoritativeStore` → `validatePostgresFtsLanguage` → reconciliation, beside the memory `PostgresFtsIndex` (S09 #7) – `PostgresFtsIndex(backend, table: conversationChunks, language:)`, then the re-projection when `rebuilt`, keeping #7's non-fatal posture inside the branch's fatal try (an escaping exception still closes the interlock connection before the backend); 8a untouched. Indexer registration and getters per #9. `IndexReconcileResult.rebuilt` (additive, default false on the fast path). New `storage_wiring_conversation_index_test.dart` through `DartclawRuntime.build` with an injected reconciler whose result reports `rebuilt` and a store whose conversation table was emptied. Depends on TI02–TI05 and stories S06, S09, S10, S14, S15.
  - **Verify**: `cmd: rg -q "conversationChunks" packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart && rg -q "bool get rebuilt|final bool rebuilt" packages/dartclaw_core/lib/src/storage/index_reconciler.dart && dart test --reporter=failures-only packages/dartclaw_runtime/test/runtime/storage_wiring_conversation_index_test.dart packages/dartclaw_runtime/test/runtime/storage_wiring_memory_preflight_test.dart packages/dartclaw_core/test/storage/index_reconciler_test.dart` – wiring constructs the conversation descriptor; the suite proves scenario S06 (rebuilt result → messages searchable after wiring; fast path → no re-projection call), that an appended message during serve is searchable, that the in-memory fallback still registers the indexer, and that `conversationSearch` is exposed; the preflight and reconciler suites pass unchanged
  - **SATISFIES**: S06, SC03, SC05

- **TI07** `rebuild-index` reconstructs the conversation corpus after the memory reconcile and prints its own line
  - Technical Overview #8; new `rebuild_index_conversation_test.dart` (SQLite); the PostgreSQL half rides S09's `rebuild_index_command_postgres_live_test.dart` with one added case. Depends on TI03, TI06.
  - **Verify**: `cmd: rg -q "Rebuilt conversation index: " apps/dartclaw_cli/lib/src/commands/rebuild_index_command.dart && ! rg -q "FTS5" apps/dartclaw_cli/lib/src/commands/rebuild_index_command.dart && dart test --reporter=failures-only apps/dartclaw_cli/test/commands/rebuild_index_command_test.dart apps/dartclaw_cli/test/commands/rebuild_index_conversation_test.dart` – the line is printed and the description is backend-neutral; the existing suite passes with `Rebuilt index: 3 entries at collection revision 2` unchanged; the new suite proves scenario S05 (empty canonical corpus, `Rebuilt conversation index: 3 messages from 2 sessions`, exactly three searchable, stale rows gone, `--json` keys), and that an absent `sessionsDir` prints `0 messages from 0 sessions` and leaves an empty corpus
  - **SATISFIES**: S05, S08

- **TI08** Documentation describes two `FullTextIndex` instances and the conversation rebuild
  - `dev/architecture/data-model.md`: a `### Derived Conversation Index Row` block beside the memory one (table, source `messages.ndjson`, predicate, write-through and rebuild, cleanup on delete/clear/archive), the `### Message` storage line noting the derived index, bump "Current through"; `docs/guide/search.md`: a `## Conversation Search` section after Memory Search (what is indexed, that `rebuild-index` rebuilds both, SQLite exact-term vs PostgreSQL stemming); `docs/guide/workspace.md#directory-layout`: the `search.db` comment names both indexes; `dev/state/UBIQUITOUS_LANGUAGE.md`: `Full-Text Index` row names the two instances, `Search Index` row names both corpora. No story IDs.
  - **Verify**: `cmd: rg -q "conversation_chunks" dev/architecture/data-model.md && rg -q "^## Conversation Search" docs/guide/search.md && rg -qi "conversation" docs/guide/workspace.md && rg -q "conversation" <(rg "^\| Full-Text Index" dev/state/UBIQUITOUS_LANGUAGE.md) && ! rg -q "S13|story S" dev/architecture/data-model.md docs/guide/search.md` – each doc names the conversation corpus and no story reference leaked
  - **SATISFIES**: SC06

- **TI09** Governance gates hold and the default run needs no PostgreSQL
  - Depends on TI01–TI08. Apply the LOC rebaseline protocol if `arch_check` reports a crossed `dartclaw_core` ceiling.
  - **Verify**: `cmd: ! rg -q "dartclaw_storage|dartclaw_server|dartclaw_models|dartclaw_config" packages/dartclaw_core/lib/src/search/conversation_index_projection.dart packages/dartclaw_core/lib/src/search/conversation_indexer.dart packages/dartclaw_core/lib/src/search/conversation_search_service.dart && rg -qU "conversation_search_service\.dart'\s*show" packages/dartclaw_core/lib/dartclaw_core.dart && (unset DARTCLAW_TEST_POSTGRES_URL; dart analyze --fatal-infos && bash dev/tools/test_workspace.sh) && bash dev/tools/fitness/run_all.sh && dart run dev/tools/arch_check.dart && git diff --check` – no retired name in the new files, the new exports carry `show`, analysis and the whole workspace suite pass with no PostgreSQL reachable, the fitness suite and `arch_check` are green, the diff is whitespace-clean
  - **SATISFIES**: SC01, SC07

### Testing Strategy

- [TI03–TI07] Layer 2 against real stores: temp-dir `SessionService`/`MessageService` writing real `meta.json` and `messages.ndjson`, `SqliteBackend(sqlite3.openInMemory())` prepared through `SqliteSchemaGate.prepareSearch`; never a faked `MessageService`. Fixtures for the rebuild are raw NDJSON literals (LEARNINGS § Testing: fixtures built by the code under test never exercise its parser). Bound-asserting tests enumerate the surviving set with `unorderedEquals`.
- [TI04] Await `indexer.idle` before asserting; the failure case uses S02's failing `DatabaseBackend` decorator, no production fault seam.
- [TI03, TI07] Live PostgreSQL suites carry `@Tags(['integration'])` and S07's helper; none was reachable at spec time (2026-09-02), so no live Proof is bound and execution reports `BLOCKED:` for the PostgreSQL halves of TI02/TI03 rather than treating SQLite suites as language proof.
- The three bound Proofs are parity (all green 2026-09-02); the red-at-spec-time surface is the six new suites plus the extended descriptor and gate suites.

### Execution Contract

- Stories S03, S09, S10, S14, and S15 must be complete (S02, S06, S07 transitively) – S10, S14, and S15 are the artifact edge on `StorageWiring.wire()`, and TI06's insertion points are defined against the `wire()` they leave (S10 SC05); consume `FullTextIndex`, `SqliteFtsIndex`/`SqliteFtsTable`, `PostgresFtsIndex`/`PostgresFtsTable`, `SqliteSchemaGate.prepareSearch`, `PostgresSchemaGate`, `validatePostgresFtsLanguage`, the rebuild targets, and `IndexReconcileResult` as-is except for the one additive `rebuilt` field. If the S02 rebuild source cannot take a second populate/authenticate pair, or the port cannot express the session-scoped delete without a contract change, raise `CONFUSION:` rather than forking a rebuild path or widening the port.
- Order: TI01 → TI02 → TI03 → TI04 ∥ TI05 → TI06 → TI07 → TI08 → TI09. All commands run from the `../dartclaw-public/` root.
- The public working tree may carry another session's uncommitted edits outside this story's Work Areas; touch only the files named there.


## Final Validation Checklist

- No new HTTP route, Web UI surface, or MCP tool in the diff; no `insertMessage`, `clearMessages`, `deleteSession`, or `updateSessionType` call site changed.
- A SQLite memory rebuild (startup reconcile and `rebuild-index`) leaves conversation search answering.
- No retired package or file name (`dartclaw_storage`, `dartclaw_models`, `dartclaw_config`, `dartclaw_server`) appears in code, tests, or dev docs touched by this story.


## Implementation Observations

> _Managed by exec-spec post-implementation – append-only. Spec authors: leave this section empty._

_No observations recorded yet._
