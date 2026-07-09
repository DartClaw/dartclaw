# ADR-045: Pluggable Database Backend — SQLite Default, PostgreSQL Opt-In

**Status:** Proposed — 2026-07-01. Three-phase delivery; no implementation started. Phase 1 (SQLite-only storage abstraction + migration runner) sequenced after 0.21's Windows SQLite work stabilizes; phases 2–3 (PostgreSQL backend, `pgvector`) target a dedicated backend-track milestone after 0.22, gated on a concrete deployment demand signal. See Proposed Sequencing.
**Deciders:** DartClaw team

**Related:** [ADR-002](002-file-based-storage.md) (current storage architecture), [ADR-004](004-vector-search-approach.md) (vector/FTS search — QMD outpost), [ADR-017](017-multi-project-architecture.md) (multi-project storage layout)

---

## Context

DartClaw's current persistence layer (ADR-002) splits storage across two zones:

- **File-based** — sessions, messages, memory, config, projects (source of truth; human-inspectable; append-only or atomic-rename)
- **SQLite** — `tasks.db` (authoritative relational: tasks, goals, artifacts, turns, events, KG facts), `search.db` (derived FTS5 index; rebuildable), `state.db` (transient recovery state)

This design was the right trade-off at MVP scale: single-user, single-process, Mac-local, zero operational overhead. Two forces are now pushing against its ceiling:

1. **Production-grade FTS / vector search.** SQLite FTS5 has no language-aware stemming or stopword lists. The `unicode61` tokenizer handles character encoding (å/ä/ö) but treats all tokens as opaque — "springer"/"springa"/"sprang" are unrelated. Multi-language content makes this worse. The QMD outpost (ADR-004) addresses memory-search quality for individual users but is not a backend for relational task data. PostgreSQL ships `pg_trgm`, native language configurations (`swedish`, `english`, etc.), and `pgvector` for embeddings — covering both FTS and vector search in a single backend without an outpost dependency.

2. **Separate hosting, backup, and data-tier scaling.** SQLite's file-local assumption ties the data to the same host as the process. Production deployments increasingly want the data tier on a separate, managed, backed-up host — decoupled from the app process for backup/restore, point-in-time recovery, and independent scaling. PostgreSQL provides this plus cloud-hosted options (RDS, Cloud SQL, Neon, Supabase) that map to established ops playbooks. This aligns with the product's existing move toward a connected/remote-server architecture (connected-CLI in 0.16.4, the desktop/mobile apps connecting to a remote `dartclaw serve`).

   **Scope honesty:** the strong near-term driver is a **separately-hosted data tier for a single logical instance**, not multi-tenancy. DartClaw's own multi-user plan (private backlog) is *N isolated single-user instances* with per-user state dirs and memory namespaces — logical isolation, not one shared multi-tenant DB. True active-active multi-instance against one database (concurrent task-claiming, scheduling, workspace git coordination) is a **separate and much larger effort** — leader election, task-claim semantics, idempotency — that this ADR *enables* but does not deliver. MVCC removes the single-writer file lock; it does not by itself make DartClaw horizontally scalable.

### What the File Layer Already Handles Well

Sessions, messages, memory, config, and projects are file-based with no SQLite involvement. These are not in scope — they remain file-based regardless of the database backend choice. The scope of this decision is the **SQLite databases** (`tasks.db`, `search.db`, `state.db`) only.

### Current SQLite Coupling Points

Before a pluggable backend is viable, these coupling points must be abstracted:

| Category | Examples | Blast radius |
|---|---|---|
| FTS5 syntax | `CREATE VIRTUAL TABLE … USING fts5(…)`, `MATCH`, `bm25()` | `MemoryService`, search index rebuild |
| SQLite pragmas | `PRAGMA journal_mode=WAL`, `PRAGMA foreign_keys=ON` | DB init code |
| `RETURNING` clause | Insert-and-fetch patterns | Task/event insert paths |
| `json_extract` / `json_each` | JSON column queries | Goal/artifact queries |
| Type coercions | SQLite's dynamic typing silently accepts mistyped values | All insert paths |
| Migration tooling | Ad-hoc `CREATE TABLE IF NOT EXISTS` + manual version table | All schema init |
| `sqlite3` package API | `Database`, `Statement`, `ResultSet` used directly throughout | All storage services |

---

## Decision Drivers

- **Production FTS/vector search** — language-aware stemming, multi-language support, vector similarity without a separate outpost dependency
- **Operational flexibility** — separate host, cloud-managed DB, standard backup/replication tooling
- **Team/multi-instance deployments** — concurrent writers, MVCC isolation, connection pooling
- **Single-binary default preserved** — SQLite remains the default; no PostgreSQL dependency for solo users
- **Abstraction, not duplication** — one storage interface, two implementations; shared migration tooling

---

## Decision

**Introduce a `DatabaseBackend` abstraction; ship SQLite as the default implementation; add PostgreSQL as an opt-in backend.** Everything above the abstraction layer is backend-agnostic.

### Abstraction Shape (sketch)

```dart
/// Single seam between all storage services and the database engine.
abstract interface class DatabaseBackend {
  Future<void> execute(String sql, [List<Object?> params]);
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?> params]);
  Future<void> transaction(Future<void> Function(DatabaseBackend tx) body);
  Future<void> close();
}
```

Storage services (`TaskService`, `GoalService`, `ArtifactService`, `TurnTraceService`, `TaskEventService`, `MemoryService`, `StateRecoveryService`) receive a `DatabaseBackend` via constructor injection. They issue only standard SQL — no FTS5 syntax, no pragmas, no `json_extract`.

### Backend Implementations

| Backend | Package | FTS | Vector | Concurrency | Deploy model |
|---|---|---|---|---|---|
| `SqliteBackend` | `sqlite3` (existing) | FTS5 (`unicode61`) | sqlite-vec (opt-in, alpha) | Single-writer | Embedded; single binary |
| `PostgresBackend` | `postgres` (pub.dev) | `pg_trgm` + language configs | `pgvector` | MVCC; connection pool | External; `DATABASE_URL` config |

### FTS Abstraction

FTS queries are issued through a `FullTextIndex` abstraction rather than raw SQL, so the backend implementation can emit the correct dialect:

```dart
abstract interface class FullTextIndex {
  Future<List<SearchResult>> search(String query, {int limit = 20});
  Future<void> upsert(String id, String content, Map<String, String> metadata);
  Future<void> delete(String id);
}
```

`SqliteFtsIndex` → FTS5 + `bm25()`.  
`PostgresFtsIndex` → `tsvector`/`tsquery` with configurable language (`english`, `swedish`, etc.).

Vector search follows the same pattern (`VectorIndex` abstraction), with `SqliteVectorIndex` (sqlite-vec, alpha) and `PostgresVectorIndex` (pgvector).

### Configuration

```yaml
# config.yaml

# Default — embedded SQLite, no external dependency
database:
  backend: sqlite   # default; omit to get sqlite

# PostgreSQL opt-in
database:
  backend: postgres
  url: postgresql://user:pass@host:5432/dartclaw
  pool_size: 5       # connection pool; default 5
  # fts_language: english   # language config for pg FTS; default english
```

### Migration Strategy

Replace ad-hoc `CREATE TABLE IF NOT EXISTS` with a versioned migration runner shared across both backends. Migrations are plain SQL files tagged with a dialect (`common`, `sqlite`, `postgres`). The runner applies `common` + the backend-specific variant in sequence, tracking applied migrations in a `schema_migrations` table (standard Rails/Flyway convention — supported identically by both engines).

### What Does NOT Change

- File-based storage (sessions, messages, memory, config, projects) — untouched
- QMD outpost (ADR-004) — remains valid; PostgreSQL FTS doesn't replace QMD's reranking/expansion pipeline for memory search. QMD operates over markdown files; this decision is about relational + indexed task data
- Single-binary story for solo users — SQLite default means zero new dependencies at the default install level

---

## Consequences

### Positive

- **Language-aware FTS at no extra operational cost** (for PostgreSQL users) — `to_tsvector('swedish', …)` is a config value, not a code change
- **Standard ops tooling** — `pg_dump`, streaming replication, cloud-managed hosting (RDS, Neon, Supabase) work out of the box
- **Separately-hosted, backed-up data tier** — MVCC removes the single-writer file lock; the database can live on managed infrastructure independent of the app process (backup/restore, PITR, scaling the data tier). Active-active multi-instance is *unblocked but not delivered* here — see Context driver #2
- **Cleaner storage layer** — the abstraction removes SQLite-isms from service code; raw `sqlite3` package calls become an implementation detail
- **Shared migration tooling** — versioned SQL migrations replace scattered `CREATE TABLE IF NOT EXISTS` calls; schema evolution becomes auditable

### Negative

- **Abstraction cost** — the `DatabaseBackend` seam, `FullTextIndex`/`VectorIndex` abstractions, and dual implementations are real complexity. Phase 1 alone (SQLite-only refactor + migration runner) is medium (2–3 stories); the full three-phase arc including the dual-backend test harness (R3) is milestone-sized. Do not treat the whole thing as a 2–3 story effort.
- **Migration tooling investment** — a proper migration runner must be built or adopted (e.g., `dbmate`, `atlas`, or a Dart-native runner). This is prerequisite work that pays off regardless of the PostgreSQL backend.
- **Two implementations to maintain** — any schema change must be expressed in both dialects. Dialect-tagged migration files mitigate this but don't eliminate it.
- **PostgreSQL operational burden** — PostgreSQL users take on connection management, backup, and version compatibility. DartClaw's role is to work correctly against a user-supplied PostgreSQL instance, not to manage it.
- **`postgres` Dart package maturity** — evaluated and cleared (see Resolved Q1): production-ready, ecosystem-standard (Serverpod depends on it), but single-maintainer-led with lifecycle gaps (no COPY, no force-close, no auto-retry-on-restart) that DartClaw's backend wrapper must design around. Pin `>=3.5.12`.

### Neutral

- `sqlite3` package stays as a dependency (default backend). No change for existing users.
- The `search.db` / `tasks.db` / `state.db` three-database split may collapse to a single database per backend (PostgreSQL uses schemas for isolation; SQLite keeps separate files). Schema layout TBD at implementation time.

---

## Alternatives Considered

### Keep SQLite; add language-specific pre-processing for FTS

Pre-stem and normalize text before inserting into FTS5; apply the same transformation at query time. Avoids the abstraction cost.

**Rejected:** Requires maintaining language-specific stemmer ports in Dart (none exist on pub.dev for Swedish). Doesn't scale across languages. Doesn't address the operational hosting limitation. Doesn't address the single-writer concurrency ceiling for team deployments.

### Keep SQLite; rely solely on QMD outpost for all search

Route all FTS and vector search through QMD (ADR-004), not just memory search.

**Rejected:** QMD operates over markdown files on the filesystem — it is not a query engine for relational task data. Routing task/artifact/goal queries through a filesystem-indexed outpost would require exporting structured data to markdown, which inverts the source-of-truth relationship. QMD is the right answer for memory search; it is not a database.

### Introduce a dedicated search engine (Meilisearch, Typesense) alongside SQLite

Keep SQLite for relational data; add Meilisearch/Typesense for full-text and vector search.

**Rejected:** Adds a third external runtime dependency (after QMD). Splits the storage landscape further (file + SQLite + search engine) without solving the operational hosting or concurrency problems. PostgreSQL with `pg_trgm`/`pgvector` covers the search use case without an additional service.

### Replace SQLite entirely with PostgreSQL (no opt-in)

Make PostgreSQL the only supported backend.

**Rejected:** Breaks the single-binary, zero-ops story for solo users. Installing and running PostgreSQL locally is a non-trivial ask for an individual developer using DartClaw as a personal AI runtime. SQLite's simplicity is a genuine feature for that use case.

---

## Reflection — Sharpened Risks & the Central Design Fork (2026-07-01)

A second pass surfaced issues the first draft glossed. These are the load-bearing risks; the "medium, 2–3 stories" framing above holds only for phase 1 (SQLite-only refactor), not the whole arc.

### R1 — The `DatabaseBackend` sketch is misleadingly thin. This is the central decision.

A `execute(String sql)` / `query(String sql)` interface that passes raw SQL through does **not** abstract SQLite from PostgreSQL — it relocates the divergence into every call site. The dialects differ on: placeholders (`?` vs `$1`/`@named`), booleans (SQLite has no bool type — 0/1 integers vs native `boolean`), timestamps (current code stores ISO8601 **TEXT**; PostgreSQL wants `timestamptz`), JSON access (`json_extract(c,'$.x')` vs `c->>'x'`), and read-side types (`sqlite3` returns dynamic/strings; `postgres` returns typed `DateTime`/`bool`/etc., so the *same* query yields different Dart types per backend).

The real fork:
- **Thin** — shared portable-subset SQL + an adapter that normalizes placeholders and marshals result types. Constrains queries to a portable subset; needs a translation shim.
- **Thick** — a repository *interface* with two full implementations each; every backend uses native idioms. No SQL portability constraint, but doubles the repository code.

**Recommendation: hybrid.** The CRUD paths are simple (insert / select-by-id / update-status / list-by-status / the `ON CONFLICT … DO UPDATE SET … excluded.*` upsert already in `turn_state_store.dart` — which *is* portable across both) → keep them in portable-subset SQL behind a thin `DatabaseBackend` that owns **placeholder rewriting + result-type marshalling** (the non-negotiable shim). Push the genuinely divergent surfaces (FTS, vector) behind the `FullTextIndex`/`VectorIndex` abstractions where they already live. Decide and record this before any implementation — it dominates the story breakdown.

### R2 — Async transaction trap (`sqlite3` is sync, `postgres` is async).

The interface must be async (`Future`), because `postgres` is. But `sqlite3` is synchronous and single-connection: an `await` inside a `transaction(body)` on the SQLite backend does **not** actually isolate — another queued operation can interleave into the open `BEGIN…COMMIT` unless the backend serializes all access (write-queue/mutex, the pattern `MemoryFileService` already uses). This is a correctness trap, not a style choice: the SQLite `transaction()` implementation must hold an exclusive lock for the async body's full duration. Call it out in the abstraction contract.

### R3 — Dual-backend testing is a recurring cost, not a one-time one.

Every storage test must exercise **both** backends or the PostgreSQL path silently rots — this is exactly the "green tests mask unwired features" failure mode this project has hit before. That means PostgreSQL in CI (a service container) and a locally-skippable tag so `dart test` still runs on a macOS dev box without a live PostgreSQL — but then local dev never exercises PG, widening the rot window. The portable-tests rule (Linux CI + macOS local) is complicated by this. Budget for it as first-class scope, not an afterthought.

### R4 — The search story now has three overlapping answers; draw the line.

After this ADR, vector search could come from sqlite-vec (alpha stub, ADR-004), QMD (opt-in outpost, ADR-004), or pgvector (here); FTS from FTS5, QMD, or PostgreSQL native. Reconciliation: **QMD stays the memory-file search outpost — it indexes markdown (`MEMORY.md`, daily logs) with reranking/query-expansion, orthogonal to the DB backend.** `pgvector`/PostgreSQL-FTS serve **in-database structured search** (tasks, artifacts, KG facts) — a different corpus. Since sqlite-vec never left stub status, **pgvector would be DartClaw's first real in-database vector search** — which is why the vector slice belongs with the Future "vector search" item, gated behind the Postgres backend, rather than bolted onto the FTS driver work.

### R5 — `pgvector`/`pg_trgm` are extensions with an enablement precondition.

Both require `CREATE EXTENSION` (often superuser/`rds_superuser`); managed offerings support them but may not enable them by default, and locked-down corporate PostgreSQL may forbid them. The migration runner must `CREATE EXTENSION IF NOT EXISTS …` before dependent tables and fail with a clear, actionable message when the extension is unavailable — not a cryptic "type vector does not exist".

## Resolved Questions (2026-07-01)

1. **`postgres` Dart package evaluation — resolved: production-ready.** `postgres` 3.5.12 (2026-06-11), publisher agilord.com, 160/160 pub points, ~210k downloads/30 days, 85 releases, active maintenance. Built-in connection pool (`Pool.withUrl`, `max_connection_count`, `max_connection_age`), TLS (`sslmode=verify-full`), transactions (`runTx`), extended query protocol, connection-string URLs. Decisive validation: **Serverpod depends on it** (`postgres: ^3.4.0`) as its only PostgreSQL driver, and `drift_postgres` wraps it — it is the ecosystem's de facto standard. 31 open issues on `isoos/postgresql-dart`, none structural. No spike needed; adopt, with caveats:
   - **Pin `>=3.5.12`** — 3.5.12 (2026-06-11) fixed three connection-left-broken-state bugs in `runTx` rollback/failure paths; older 3.x is not trustworthy for transaction-heavy code.
   - **No COPY protocol** (open request [#443](https://github.com/isoos/postgresql-dart/issues/443)) — bulk import/export needs batched INSERTs or a `psql`/`pg_dump` subprocess. Relevant to a future SQLite→PostgreSQL data-migration tool.
   - **No force-close connection API** ([#394](https://github.com/isoos/postgresql-dart/issues/394)) and no auto-retry on server restart ([#290](https://github.com/isoos/postgresql-dart/issues/290)) — reconnect/retry policy must live in DartClaw's backend wrapper.
   - Single-maintainer-led (agilord/isoos, responsive) — budget for occasional patch-level upgrades, not set-and-forget.

2. **Migration runner choice — resolved: minimal in-house Dart runner.** The startup constraint (migrations run automatically at server boot, zero user-visible tooling, AOT single binary) rules out external binaries (`dbmate`, `atlas`, `golang-migrate`) — an outpost is wrong here because migration is not optional functionality; the server cannot boot without it. Dart-native pub.dev options are immature or dormant (`migrant` last published 2024-08, `dox_migration` 2023-12, `athena_migrate` 2024-11, `dbmigrator_psql` at 0.1.2). A minimal runner is ~150 lines: dialect-tagged migrations, `schema_migrations` tracking table, applied in transaction (PostgreSQL has transactional DDL; SQLite DDL is transactional too). Design notes from the research:
   - **AOT gotcha:** a single AOT binary has no asset bundle — migrations must be embedded as Dart string constants (generated at build time from `.sql` files, or maintained as a const map), not files read at runtime.
   - **No shared driver abstraction exists** between the `sqlite3` and `postgres` packages — the runner branches at an internal executor boundary (`SqliteExecutor`/`PostgresExecutor`), which is the same seam the `DatabaseBackend` abstraction provides.
   - **Non-transactional DDL escape hatch from day one:** `CREATE INDEX CONCURRENTLY` (and similar) cannot run inside a PostgreSQL transaction — support a per-migration no-transaction flag rather than retrofitting it.
   - **Forward-only** — no down-migrations, matching the project's early-experimental, breaking-changes-acceptable posture.
   - Fail-closed: any migration failure aborts server startup.

3. **Three-DB vs single-DB layout — resolved: single PostgreSQL database, one connection pool.** `tasks.db` + `search.db` collapse into one PostgreSQL database (plain table namespace; schemas optional and not required at current table count). One pool, one backup target, one `DATABASE_URL`. SQLite keeps its per-concern files (WAL contention isolation still applies there). The search index tables remain rebuildable regardless of which database they live in.

4. **`state.db` scope — resolved: stays instance-local SQLite always, out of scope for the backend abstraction.** Codebase inspection: `state.db` holds a single `turn_state` table (session_id → active turn), written once per turn start/end — turn-boundary frequency, not hot-path. The deciding factor is not latency but semantics: crash-recovery state is inherently **per-instance** (`turn_runner_cancellation.dart` scans for *this process's* orphaned turns). Putting it in a shared PostgreSQL would let one instance see another's live turns as orphans. Keeping it local also means crash recovery works when the network database is unreachable. This shrinks the abstraction scope to `tasks.db` + `search.db`.

## Proposed Sequencing (2026-07-01)

Grounded in the current roadmap (backend track 0.20 → 0.21 → 0.24/0.25 (renumbered 2026-07-06), running parallel to the UI track). Three phases, deliberately not one milestone:

- **Phase 1 — Storage abstraction + versioned migration runner (SQLite-only, zero behavior change).** Introduce `DatabaseBackend` (+ the R1 placeholder/type shim), route the ~7 SQLite-coupled files in `dartclaw_storage` through it, and replace ad-hoc `CREATE TABLE IF NOT EXISTS` with the in-house migration runner. **Delivers value on its own** — versioned, auditable schema evolution regardless of whether PostgreSQL ever ships. Pure refactor; independently shippable.
  - **Timing: after 0.21, not before.** 0.21 (Windows) hardens the bundled-SQLite build and `sqlite` source-mode ([memory: sqlite3 user_defines from workspace root]). Abstracting a *moving* SQLite baseline invites conflict, and two milestones editing storage wiring at once is avoidable churn. Sequence Phase 1 as a small prep milestone once the Windows SQLite baseline is stable — candidate slot: alongside or just after 0.24/0.25 on the backend track.
- **Phase 2 — `PostgresBackend` + PostgreSQL-native FTS.** The opt-in backend, `DATABASE_URL` config, dual-backend CI harness (R3), language-aware `tsvector` FTS. This is the "production-grade FTS" + "separately-hosted data tier" payoff.
- **Phase 3 — `pgvector` in-database vector search.** DartClaw's first real in-DB vector search (R4). Answers the Future "vector search" backlog item via the Postgres backend rather than productionizing the sqlite-vec stub.

**Recommended home for phases 2–3: a dedicated backend-track milestone after 0.25**, roughly where the Future backlog already parks "vector search" and the data-tier half of "multi-user deployment." Strong synergy with `0.next-desktop-app`'s remote-`dartclaw serve` story — a remote server backed by managed PostgreSQL is precisely the deployment this unlocks; consider co-sequencing so the connected/remote architecture and its production data tier land together. Not a fit for 0.20 (active, workflow-focused) or as feature scope inside 0.21 (platform-focused).

**Demand-signal gate:** phases 2–3 should wait for a concrete deployment asking for it (a user wanting separately-hosted/backed-up data, or multi-language FTS in production). Phase 1 is worth doing on hygiene grounds alone and need not wait.

## Open Questions

1. **R1 thin-vs-thick abstraction fork** — confirm the hybrid recommendation (portable-subset CRUD + type/placeholder shim, dialect modules only for FTS/vector) at the start of Phase 1; it dominates the story breakdown.
2. **PostgreSQL FTS language config granularity** — single `fts_language` for the whole index, or per-document language detection? Default to single config; revisit if mixed-language corpora become a real complaint.
3. **Migration-runner reuse vs. build** — a Phase-1 spike should confirm the ~150-line in-house runner over adapting the dormant `migrant` (last release 2024-08); default is build.
