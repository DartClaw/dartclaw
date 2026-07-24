# ADR-045: Pluggable Database Backend — SQLite Default, PostgreSQL Opt-In

**Status:** Accepted — 2026-07-24. Proposed 2026-07-01; council-reviewed and remediated 2026-07-24 (report: `.agent_temp/reviews/adr-045-pluggable-database-backend-mixed-review-claude-2026-07-24.md`); owner accepted all eight council-surfaced posture/contract decisions same day (§ Decided Posture & Contracts). **Demand gate satisfied (owner, 2026-07-24):** multi-language (Swedish) FTS is a requirement; phases 1+2 are committed together as **one milestone — 0.23** (previously-planned 0.23+ shifted down; renumber sanctioned by owner). Phase 3 (`pgvector`) stays deferred pending an embedding-source decision. No implementation started; milestone is PRD-ready. See Proposed Sequencing.
**Deciders:** DartClaw team

**Related:** [ADR-002](002-file-based-storage.md) (current storage architecture), [ADR-004](004-vector-search-approach.md) (vector/FTS search — QMD outpost), [ADR-017](017-multi-project-architecture.md) (multi-project storage layout)

---

## Context

DartClaw's current persistence layer (ADR-002) splits storage across two zones:

- **File-based** — sessions, messages, memory, config, projects (source of truth; human-inspectable; append-only or atomic-rename)
- **SQLite** — `tasks.db` (authoritative relational: tasks, goals, artifacts, turns, events, KG facts), `search.db` (derived FTS5 index; rebuildable), `state.db` (transient recovery state)

This design was the right trade-off at MVP scale: single-user, single-process, Mac-local, zero operational overhead. Two forces are now pushing against its ceiling:

1. **Production-grade FTS / vector search.** SQLite FTS5's only built-in stemmer is the English-only `porter` tokenizer; there is no stemming for Swedish or other non-English languages and no stopword lists. The default `unicode61` tokenizer handles character encoding (å/ä/ö) but treats all tokens as opaque — "springer"/"springa"/"sprang" are unrelated. Multi-language content makes this worse. The QMD outpost (ADR-004) addresses memory-search quality for individual users but is not a backend for relational task data. PostgreSQL's core `tsvector`/`tsquery` full-text search ships native language configurations (`swedish`, `english`, etc. — Snowball stemmers + stopword dictionaries, no extension required), and `pgvector` adds vector similarity — covering both FTS and vector search in a single backend without an outpost dependency. (`pg_trgm` is a separate trigram-similarity extension for fuzzy matching; it does not stem and is not the FTS mechanism.)

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
- **Single-binary default preserved** — SQLite remains the default; no *running* PostgreSQL required for solo users. (Under AOT whole-program compilation with runtime backend selection, the `postgres` package still compiles into every binary — see Consequences/Negative; excluding it would need a build flavor or conditional import, recorded in Open Questions)
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

The coupled units receive a `DatabaseBackend` via constructor injection and issue only standard SQL — no FTS5 syntax, no pragmas, no `json_extract`. The rg-verified census (2026-07-24, `rg -l "package:sqlite3" packages/dartclaw_storage/lib/`) counts **14 production files**, not the ~7 the first draft estimated: `SqliteTaskRepository`, `SqliteGoalRepository`, `SqliteAgentExecutionRepository`, `SqliteWorkflowRunRepository`, `SqliteWorkflowStepExecutionRepository`, `SqliteExecutionRepositoryTransactor`, `TaskEventService`, `TurnTraceService`, `MemoryService`, `TurnStateStore`, `WebhookDeliveryStore`, `TemporalKnowledgeGraphService` (KG facts, incl. its ad-hoc `PRAGMA table_info` column migrations), plus the `task_db.dart`/`search_db.dart` open helpers. The existing `TaskDbFactory`/`SearchDbFactory` typedefs return the concrete sqlite3 `Database` type — they are surface to *replace*, not seams that reduce the work. Re-run the census at spec time; it sizes Phase 1.

### Backend Implementations

| Backend | Package | FTS | Vector | Concurrency | Deploy model |
|---|---|---|---|---|---|
| `SqliteBackend` | `sqlite3` (existing) | FTS5 (`unicode61`) | none (sqlite-vec is a stub — not implemented, see R4) | Single-writer | Embedded; single binary |
| `PostgresBackend` | `postgres` (pub.dev) | `tsvector`/`tsquery` language configs (core PG) | `pgvector` (extension) | MVCC; connection pool | External; `DATABASE_URL` config |

### FTS Abstraction

FTS queries are issued through a `FullTextIndex` abstraction rather than raw SQL, so the backend implementation can emit the correct dialect:

```dart
abstract interface class FullTextIndex {
  Future<List<SearchResult>> search(String query, {required String userId, int limit = 20});
  Future<void> upsert(String id, String content, {required String userId, Map<String, String> metadata});
  Future<void> delete(String id);
}
```

The `userId` dimension is part of the contract (decided 2026-07-24, § Decided Posture & Contracts #7): the live `MemoryService` queries filter `AND mc.user_id = ?`, and that filter *is* the multi-user isolation mechanism — an implementation without it is a cross-user confidentiality regression. The shared contract-test suite asserts tenancy isolation on both backends. `SearchResult` fields and `metadata` semantics are pinned at spec time.

`SqliteFtsIndex` → FTS5 + `bm25()`.  
`PostgresFtsIndex` → `tsvector`/`tsquery` with configurable language (`english`, `swedish`, etc.).

Vector search follows the same pattern (`VectorIndex` abstraction) — but with only `PostgresVectorIndex` (pgvector) as a real implementation. There is no SQLite-side counterpart: sqlite-vec never left stub status (ADR-002/004), and per R4 it will not be productionized. The SQLite backend simply has no in-database vector path.

### Configuration

```yaml
# config.yaml

# Default — embedded SQLite, no external dependency
database:
  backend: sqlite   # default; omit to get sqlite

# PostgreSQL opt-in
database:
  backend: postgres
  url: ${DARTCLAW_DATABASE_URL}   # env-var reference — inline credentials are unsupported
  pool_size: 5       # provisional default; sized for storage-layer await-concurrency in a single-threaded runtime — tune in Phase 2
  # fts_language: english   # language config for pg FTS; default english
```

**Credential handling (binding).** `database.url` carries a secret and follows the project's reference-based credential model (`configuration-architecture.md` §Credentials: secrets are never stored literally in `dartclaw.yaml`): the value must resolve via `${ENV_VAR}` substitution or a named `credentials:` reference. Config validation rejects inline passwords in a persisted `database.url`. The DSN must additionally be covered by redaction everywhere it can surface — `MessageRedactor` gains a `://user:pass@` DSN pattern, driver connection/auth exceptions are redacted before logging (the fail-closed migration boot path throws on startup and must not log the raw DSN), and `dartclaw config` output masks the URL the same way `CredentialEntry.toString()` masks secrets.

### Decided Posture & Contracts (owner-accepted, 2026-07-24)

The 2026-07-24 council review surfaced eight posture/contract decisions; the owner accepted all eight. These are binding on the milestone spec.

**Security & operational posture:**

1. **TLS** — `sslmode` is required for any non-loopback host, default `verify-full`; a credential over cleartext to a non-loopback host **fails closed** (mirrors the outbound-MCP rule, ADR-039 / commit 387ae564). Loopback exemption uses a shared loopback-classification seam extracted for both the MCP and DB boundaries — never a cross-package reach into `HttpMcpTransport` internals.
2. **Data fate on backend switch** — switching `database.backend` **never migrates data**: the new backend starts empty, and startup logs a prominent notice when an abandoned non-empty store exists for the other backend. The SQLite→PostgreSQL importer is explicitly a separate future tool (blocked on driver COPY support, see Resolved Q1). The PostgreSQL guide carries decommission guidance for a switched-away-from remote database, including provider snapshots/backups.
3. **Webhook delivery ledger** — stays **instance-local SQLite** (same reasoning as `state.db`, Resolved Q4: its dedup semantics are per-instance). This closes the fourth-database scope gap; the abstraction scope remains `tasks.db` + `search.db`.
4. **Single-writer interlock** — the PostgreSQL backend takes an advisory lock (or instance-lease row) at startup; a second instance pointing at the same database **fails loud** with a clear error. Active-active remains out of scope; this converts silent corruption into a refusal.
5. **Egress classification** — the DB connection is **trusted host-side egress** (same category as git operations): initiated by the host storage layer, not reachable or influenceable from agent tooling, outside the agent egress guard chain. Connection lifecycle events (open, close, auth failure) are audited.
6. **Role separation** — documented two-role model: an elevated *bootstrap* role for migrations/extension enablement, a least-privilege *runtime* role owning only DartClaw's schema (DML). Guidance plus a startup warning when the runtime role is superuser; not enforced in v1.

**Runtime contracts:**

7. **R1 fork — ratified: hybrid.** Portable-subset CRUD behind the thin `DatabaseBackend` (placeholder rewriting + result-type marshalling shim); FTS/vector behind `FullTextIndex`/`VectorIndex`. Riders folded in: the port exposes prepared-statement handles (current repos depend on statement reuse), literal-aware placeholder rewriting is counted as real shim cost, the `FullTextIndex` contract **carries the tenancy (`user_id`) dimension** (it is the multi-user isolation mechanism in the live queries), and `SearchResult`/metadata semantics are pinned at spec time.
8. **Outage, parity, and migration recovery.** (a) *PG-unreachable*: fail closed at startup connect (consistent with the migration gate), bounded retry with surfaced errors mid-session; **local orphan-turn recovery runs before the backend/migration gate**, which makes Resolved Q4's offline-recovery rationale actually hold. (b) *Search parity*: only **set-membership** is contractual across backends; ranking order is explicitly backend-specific (`bm25()` vs `ts_rank`) — this is what makes the shared `databaseBackendContractTests` suite writable. (c) *Migration recovery*: no-transaction migrations must be idempotent (`IF NOT EXISTS`-style), and the wedged-boot runbook (manual `schema_migrations` repair) is documented.

### Migration Strategy

Replace ad-hoc `CREATE TABLE IF NOT EXISTS` with a versioned migration runner shared across both backends. Migrations are plain SQL files tagged with a dialect (`common`, `sqlite`, `postgres`). The runner applies `common` + the backend-specific variant in sequence, tracking applied migrations in a `schema_migrations` table (standard Rails/Flyway convention — supported identically by both engines).

Runner semantics are informed by a source-level analysis of Serverpod's migration system (private repo: `dartclaw-private/docs/research/serverpod-4-analysis/deep-dive-build-and-migrations.md`, 2026-07-10). Binding lessons for the spec: transaction scope is chosen **explicitly** — one transaction per migration file — rather than falling out of implementation plumbing (Serverpod's SQLite and PostgreSQL runners apply identical generated SQL with opposite mid-sequence failure semantics, purely by accident of parameter threading); applied-version bookkeeping is idempotent (upsert into `schema_migrations`, hard-stop on a recorded version the runner doesn't know); the runner re-verifies live schema against the expected definition after applying (fatal in development, warning in production); and non-additive SQLite changes (column type, `NOT NULL`, FK changes) use SQLite's documented 12-step table-rebuild recipe — in-place `ALTER TABLE` covers only additive cases.

### What Does NOT Change

- File-based storage (sessions, messages, memory, config, projects) — untouched
- QMD outpost (ADR-004) — remains valid; PostgreSQL FTS doesn't replace QMD's reranking/expansion pipeline for memory search. QMD operates over markdown files; this decision is about relational + indexed task data
- Single-binary story for solo users — SQLite default means no PostgreSQL server, setup, or configuration is ever required. (The `postgres` *package* does compile into the binary — see Consequences/Negative)

---

## Consequences

### Positive

- **Language-aware FTS at no extra operational cost** (for PostgreSQL users) — `to_tsvector('swedish', …)` is a config value, not a code change
- **Standard ops tooling** — `pg_dump`, streaming replication, cloud-managed hosting (RDS, Neon, Supabase) work out of the box
- **Separately-hosted, backed-up data tier** — MVCC removes the single-writer file lock; the database can live on managed infrastructure independent of the app process (backup/restore, PITR, scaling the data tier). Active-active multi-instance is *unblocked but not delivered* here — see Context driver #2
- **Cleaner storage layer** — the abstraction removes SQLite-isms from service code; raw `sqlite3` package calls become an implementation detail
- **Shared migration tooling** — versioned SQL migrations replace scattered `CREATE TABLE IF NOT EXISTS` calls; schema evolution becomes auditable

### Negative

- **Abstraction cost** — the `DatabaseBackend` seam, `FullTextIndex`/`VectorIndex` abstractions, and dual implementations are real complexity. The earlier "Phase 1 = 2–3 stories" estimate is superseded by the verified 14-file census (§ Decision) and the R2 sync→async contagion scope — Phase-1 sizing comes from the milestone spec, and the full arc including the dual-backend test harness (R3) is milestone-sized.
- **Migration tooling investment** — a proper migration runner must be built (in-house Dart runner — external tools ruled out, see Resolved Q2). This is prerequisite work that pays off regardless of the PostgreSQL backend.
- **Two implementations to maintain** — any schema change must be expressed in both dialects. Dialect-tagged migration files mitigate this but don't eliminate it.
- **PostgreSQL operational burden** — PostgreSQL users take on connection management, backup, and version compatibility. DartClaw's role is to work correctly against a user-supplied PostgreSQL instance, not to manage it.
- **Third-party data-processor exposure** — `tasks.db` content (task prompts, artifacts, turn traces, KG facts) is Mac-local today; on a managed PostgreSQL (RDS/Neon/Supabase) it is stored, backed up, and retained by a third party under that provider's access model. This is precisely the data-leaves-the-trust-boundary shape the threat model otherwise works to prevent — acceptable because it is an explicit operator opt-in, but the user-facing PostgreSQL guide must say so and recommend at-rest encryption; retention/residency are the operator's responsibility.
- **`postgres` package compiles into every binary** — runtime config-based backend selection makes `PostgresBackend` reachable from `main()`, so under Dart AOT whole-program compilation the `postgres` package (and its transitive deps) ships in the default solo-user binary too. The single-binary promise holds at the "no running PostgreSQL required" level, not the dependency level. A build flavor / conditional import could exclude it; see Open Questions.
- **`postgres` Dart package maturity** — evaluated and cleared (see Resolved Q1): production-ready, ecosystem-standard (Serverpod depends on it), but single-maintainer-led with lifecycle gaps (no COPY, no force-close, no auto-retry-on-restart) that DartClaw's backend wrapper must design around. Pin `^3.5.12` (bounded per DART-PACKAGE-GUIDELINES §Version Constraints — never an open-ended lower bound at a transaction-critical boundary).

### Neutral

- `sqlite3` package stays as a dependency (default backend). No change for existing users.
- Database layout is decided (see Resolved Q3/Q4): `tasks.db` + `search.db` collapse into one PostgreSQL database with one pool; `state.db` stays instance-local SQLite always and is out of the abstraction's scope; SQLite keeps its per-concern files.

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

**Rejected:** Adds a third external runtime dependency (after QMD). Splits the storage landscape further (file + SQLite + search engine) without solving the operational hosting or concurrency problems. PostgreSQL with `tsvector`/`pgvector` covers the search use case without an additional service.

### Keep SQLite; add hosted-SQLite tooling for the backup/hosting driver (Litestream/LiteFS, Turso/libSQL)

Litestream/LiteFS provide continuous WAL streaming to object storage with point-in-time recovery; Turso/libSQL offer a SQLite-compatible server mode with replication. Either addresses driver #2 (separately-hosted, backed-up data tier) without a second backend.

**Rejected:** Neither addresses driver #1 — language-aware FTS remains FTS5's, so the multi-language search requirement is unmet. Litestream adds an external sidecar process (outpost-shaped, but for the *authoritative* store rather than an optional enhancement), and the Dart client story for libSQL server mode is immature. Recorded for completeness; the rejection is driver-#1-decisive.

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

**Ratified: hybrid (owner, 2026-07-24 — § Decided Posture & Contracts #7).** The CRUD paths are simple (insert / select-by-id / update-status / list-by-status / the `ON CONFLICT … DO UPDATE SET … excluded.*` upsert already in `turn_state_store.dart` — which *is* portable across both) → keep them in portable-subset SQL behind a thin `DatabaseBackend` that owns **placeholder rewriting + result-type marshalling** (the non-negotiable shim), and exposes prepared-statement handles. Push the genuinely divergent surfaces (FTS, vector) behind the `FullTextIndex`/`VectorIndex` abstractions where they already live.

### R2 — Async transaction trap (`sqlite3` is sync, `postgres` is async).

The interface must be async (`Future`), because `postgres` is. But `sqlite3` is synchronous and single-connection: an `await` inside a `transaction(body)` on the SQLite backend does **not** actually isolate — another queued operation can interleave into the open `BEGIN…COMMIT` unless the backend serializes all access. This is a correctness trap, not a style choice: the SQLite `transaction()` implementation must hold an exclusive lock for the async body's full duration. The canonical in-repo precedent is `SqliteExecutionRepositoryTransactor` (`dartclaw_storage`), which already implements exactly this single-slot queue holding `BEGIN…COMMIT` across an awaited body — reuse its pattern, not a new one. Second, the blast radius is wider than the transaction contract: the entire storage layer is currently *synchronous* sqlite3 (`_db.execute`/`_db.select`, no Futures), so an async `DatabaseBackend` forces async signatures through every storage call site and their upstream `dartclaw_server` callers. That sync→async contagion is a pervasive mechanical change and must be counted in Phase-1 sizing, not discovered mid-story.

### R3 — Dual-backend testing is a recurring cost, not a one-time one.

Every storage test must exercise **both** backends or the PostgreSQL path silently rots — this is exactly the "green tests mask unwired features" failure mode this project has hit before. The mechanism is not new machinery: TESTING-STRATEGY.md already defines `@Tags(['integration'])` for skipped-by-default live-resource tests (the PG-live path: skipped on a macOS dev box, run in the CI service container) and the shared contract-test pattern (`searchBackendContractTests` is the existing exemplar). Enforcement is a `databaseBackendContractTests`-style shared suite both backends must pass — which is where the tenancy and search-parity assertions also live. This *resolves* the portable-tests rule rather than conflicting with it; the residual cost (both dialects forever, local dev rarely exercising PG) is real and budgeted as first-class scope, not an afterthought.

### R4 — The search story now has three overlapping answers; draw the line.

After this ADR, vector search could come from sqlite-vec (alpha stub, ADR-004), QMD (opt-in outpost, ADR-004), or pgvector (here); FTS from FTS5, QMD, or PostgreSQL native. Reconciliation: **QMD stays the memory-file search outpost — it indexes markdown (`MEMORY.md`, daily logs) with reranking/query-expansion, orthogonal to the DB backend.** `pgvector`/PostgreSQL-FTS serve **in-database structured search** (tasks, artifacts, KG facts) — a different corpus. Since sqlite-vec never left stub status, **pgvector would be DartClaw's first real in-database vector search** — which is why the vector slice belongs with the Future "vector search" item, gated behind the Postgres backend, rather than bolted onto the FTS driver work.

### R5 — `pgvector` is an extension with an enablement precondition. FTS is not.

PostgreSQL FTS (`tsvector`/`tsquery` + language configs) is core — it needs **no** extension, so the Phase-2 multi-language FTS payoff has no enablement precondition. `pgvector` (Phase 3) does require `CREATE EXTENSION` (often superuser/`rds_superuser`), as would `pg_trgm` if fuzzy matching were ever added; managed offerings support them but may not enable them by default, and locked-down corporate PostgreSQL may forbid them. When extension-dependent migrations exist, the runner must `CREATE EXTENSION IF NOT EXISTS …` before dependent tables and fail with a clear, actionable message when the extension is unavailable — not a cryptic "type vector does not exist".

## Resolved Questions (2026-07-01)

1. **`postgres` Dart package evaluation — resolved: production-ready.** `postgres` 3.5.12 (2026-06-11), publisher agilord.com, 160/160 pub points, ~210k downloads/30 days, 85 releases, active maintenance. Built-in connection pool (`Pool.withUrl`, `max_connection_count`, `max_connection_age`), TLS (`sslmode=verify-full`), transactions (`runTx`), extended query protocol, connection-string URLs. Ecosystem validation: **Serverpod depends on it** (`postgres: ^3.4.0`) as its only PostgreSQL driver, and `drift_postgres` wraps it — it is the ecosystem's de facto standard. Caveat on that inference: Serverpod's `^3.4.0` range *includes* the pre-3.5.12 releases this ADR distrusts, so the social proof validates the driver generally, not the specific `runTx` transaction fixes DartClaw depends on — Phase 2 therefore includes a small targeted transaction-integrity spike (`runTx` rollback/failure paths + the R2 SQLite serialization contract) rather than waiving verification entirely. 31 open issues on `isoos/postgresql-dart`, none structural. Adopt, with caveats:
   - **Pin `^3.5.12`** (bounded — never an open lower bound; DART-PACKAGE-GUIDELINES §Version Constraints) — 3.5.12 (2026-06-11) fixed three connection-left-broken-state bugs in `runTx` rollback/failure paths; older 3.x is not trustworthy for transaction-heavy code, and an unbounded range would let a breaking 4.x in on `pub upgrade`.
   - **No COPY protocol** (open request [#443](https://github.com/isoos/postgresql-dart/issues/443)) — bulk import/export needs batched INSERTs or a `psql`/`pg_dump` subprocess. Relevant to a future SQLite→PostgreSQL data-migration tool.
   - **No force-close connection API** ([#394](https://github.com/isoos/postgresql-dart/issues/394)) and no auto-retry on server restart ([#290](https://github.com/isoos/postgresql-dart/issues/290)) — reconnect/retry policy must live in DartClaw's backend wrapper.
   - Single-maintainer-led (agilord/isoos, responsive) — budget for occasional patch-level upgrades, not set-and-forget.

2. **Migration runner choice — resolved: minimal in-house Dart runner.** The startup constraint (migrations run automatically at server boot, zero user-visible tooling, AOT single binary) rules out external binaries (`dbmate`, `atlas`, `golang-migrate`) — an outpost is wrong here because migration is not optional functionality; the server cannot boot without it. Dart-native pub.dev options are immature or dormant (`migrant` last published 2024-08, `dox_migration` 2023-12, `athena_migrate` 2024-11, `dbmigrator_psql` at 0.1.2). A minimal runner *core* is ~150 lines: dialect-tagged migrations, `schema_migrations` tracking table, applied in transaction (PostgreSQL has transactional DDL; SQLite DDL is transactional too, with documented exceptions — see the no-transaction note below). The ~150 figure covers the apply loop only — the build-time SQL→Dart-const codegen, the two dialect executors, the no-transaction flag, and extension-enablement handling are additional scope the Phase-1 spike (Open Questions) must size. Design notes from the research:
   - **AOT gotcha:** a single AOT binary has no asset bundle — migrations must be embedded as Dart string constants (generated at build time from `.sql` files, or maintained as a const map), not files read at runtime.
   - **No shared driver abstraction exists** between the `sqlite3` and `postgres` packages — the runner branches at an internal executor boundary (`SqliteExecutor`/`PostgresExecutor`), which is the same seam the `DatabaseBackend` abstraction provides.
   - **Non-transactional DDL escape hatch from day one:** `CREATE INDEX CONCURRENTLY` (and similar) cannot run inside a PostgreSQL transaction — support a per-migration no-transaction flag rather than retrofitting it. Note the flag's semantics are backend-asymmetric: the exceptions are PostgreSQL-motivated (SQLite has no `CONCURRENTLY` equivalent, and SQLite's own DDL-transactionality exceptions are different ones) — the runner must not assume the flag means the same thing on both engines.
   - **Forward-only** — no down-migrations, matching the project's early-experimental, breaking-changes-acceptable posture.
   - Fail-closed: any migration failure aborts server startup.

3. **Three-DB vs single-DB layout — resolved: single PostgreSQL database, one connection pool.** `tasks.db` + `search.db` collapse into one PostgreSQL database (plain table namespace; schemas optional and not required at current table count). One pool, one backup target, one `DATABASE_URL`. SQLite keeps its per-concern files (WAL contention isolation still applies there). The search index tables remain rebuildable regardless of which database they live in.

4. **`state.db` scope — resolved: stays instance-local SQLite always, out of scope for the backend abstraction.** Codebase inspection: `state.db` holds a single `turn_state` table (session_id → active turn), written once per turn start/end — turn-boundary frequency, not hot-path. The deciding factor is not latency but semantics: crash-recovery state is per-instance (`turn_runner_cancellation.dart` scans for *this process's* orphaned turns), and today per-instance-ness derives from file locality. A shared-PostgreSQL variant *is* technically possible (an `instance_id` column scoping the orphan scan) — it was considered and rejected: locality is the simpler mechanism, and it keeps crash recovery independent of the network database's availability. This is a deliberate simplicity choice, not a forced one — recorded so a future active-active effort doesn't mistake it for an impossibility. This shrinks the abstraction scope to `tasks.db` + `search.db`.

## Proposed Sequencing (updated 2026-07-24)

Shipped reality as of this update: 0.20.1 tagged 2026-07-11, 0.21 (Windows) tagged 2026-07-18, 0.22 (Afterglow) implementation complete. The Phase-1 precondition — a stable Windows SQLite baseline after 0.21 — is **satisfied**. This ADR's work is the backend track's next milestone.

**Demand gate: satisfied.** The original gate (phases 2–3 wait for a concrete deployment needing separately-hosted data or multi-language FTS) was closed by the owner on 2026-07-24: multi-language (Swedish) FTS is a requirement. Consequence: phases 1 and 2 are **one committed milestone — proposed 0.23 "Pluggable Database Backend & Multi-Language Search"** — and the plans previously holding those numbers shift down one: Chat & Session Experience 0.23 → **0.24**, workflow track (DSL v2, Dynamic Workflows) 0.24/0.25 → **0.25/0.26** (renumber sanctioned by owner; the private ROADMAP is authoritative once updated). The phase split survives *inside* the milestone as story ordering, not as separate scheduling units:

- **Phase 1 stories — Storage abstraction + versioned migration runner (SQLite-only, zero behavior change).** Introduce `DatabaseBackend` (+ the R1 placeholder/type shim), route the rg-verified 14-file coupling surface in `dartclaw_storage` (census in § Decision) through it, and replace ad-hoc `CREATE TABLE IF NOT EXISTS` + scattered `PRAGMA table_info` column-checks with the in-house migration runner. Lands first as a pure refactor with green tests; independently shippable if the milestone is interrupted.
- **Phase 2 stories — `PostgresBackend` + PostgreSQL-native FTS.** The opt-in backend, `DATABASE_URL` config (credential-reference model per § Configuration), dual-backend contract-test harness (R3), language-aware `tsvector` FTS. The multi-language payoff — noting plainly: multi-language FTS ships **on the PostgreSQL backend only**; the SQLite default keeps `unicode61` exact/prefix matching.
- **Phase 3 — `pgvector` in-database vector search: NOT in this milestone.** Deferred not on demand but on a missing prerequisite: an embedding-generation pipeline (ADR-004 deliberately keeps embeddings in the QMD outpost; pgvector without an embedding source is dead tables). Requires its own small design pass (embedding source: cloud API / local / QMD-generated) when in-database semantic search is actually wanted. QMD (multilingual embeddings) remains the available semantic-search answer meanwhile.

Synergy noted for later scheduling: `0.next-desktop-app`'s remote-`dartclaw serve` story — a remote server backed by managed PostgreSQL is precisely the deployment this milestone unlocks.

**Preconditions before the milestone PRD: resolved.** All Gate A/B decisions from the 2026-07-24 council review were accepted by the owner the same day and are recorded in § Decided Posture & Contracts. The remaining Open Questions (FTS language granularity, migration-runner spike sizing, `postgres` dependency-exclusion mechanism) are spec-time items, not PRD blockers. **The 0.23 milestone is PRD-ready.**

## Open Questions

Spec-time items — none block the milestone PRD. (The former Open Question 1, the R1 abstraction fork, was ratified 2026-07-24 — § Decided Posture & Contracts #7.)

1. **PostgreSQL FTS language config granularity** — single `fts_language` for the whole index, or per-document language detection? Default to single config; note a mixed Swedish/English corpus under one config mis-stems the other language — revisit if that becomes a real complaint.
2. **Migration-runner spike** — a Phase-1 spike sizes the full runner scope (core loop + build-time codegen + two executors + no-tx flag + extension handling) and confirms build over adapting the dormant `migrant`; default is build.
3. **`postgres` dependency exclusion mechanism** — should the default solo-user binary exclude the `postgres` package via a build flavor / conditional import, or is the compile-in cost accepted? (See Consequences/Negative; decide before release packaging of the milestone.)
