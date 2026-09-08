# Product Requirements Document: DartClaw 0.26 Phase A – Pluggable Database Backend & Multi-Language Search

> **Milestone structure (owner, 2026-07-25; Phase-A schema scope amended 2026-07-30; riders added 2026-08-07 – FR11/S13 conversation index, FR12/S14 store rename, FR13/S15 filesystem instance-local state, the former S14 split on FIS size 2026-09-02; milestone renumbered 0.25 → 0.26 on 2026-08-18 when Lean Runtime took 0.25)**: 0.26 is a **two-phase milestone with one PRD per phase**. This PRD is **Phase A**. **Phase B – Native Hybrid Search (`dartclaw_search`)** is scoped in [hybrid-search-prd-brief.md](hybrid-search-prd-brief.md). Phase A remains the independently shippable fallback release point.
> **Context**: [ROADMAP.md § 0.26](../../ROADMAP.md) (scheduled 2026-07-24; two-phase split 2026-07-25; renumbered 2026-08-18). Binding decision: public **ADR-045** (Accepted 2026-07-24, schema-evolution strategy amended 2026-07-30, `../dartclaw-public/dev/adrs/045-pluggable-database-backend.md`) – its backend, security, runtime, and amended schema-compatibility contracts are encoded here. Related: ADR-002 (file-based storage), ADR-004 (QMD outpost search), ADR-039 (outbound egress posture), ADR-034 (enforced package dependency direction).
> **Related Assets**: [intent.md](intent.md) (owner decisions settled 2026-07-30), `../dartclaw-public/dev/architecture/data-model.md` (storage deep-dive), `../dartclaw-public/dev/guidelines/TESTING-STRATEGY.md` (`@Tags(['integration'])` + shared contract-suite conventions), `../dartclaw-public/dev/guidelines/DART-PACKAGE-GUIDELINES.md` (§ Version Constraints).
> **Release baseline gate (2026-08-07) – EVALUATED 2026-08-14, FIRED; RE-EVALUATED 2026-09-02, FIRED AGAIN.** Phase A starts only after the preceding release ships. *2026-08-14 evaluation:* the gate required the released 0.24 SQLite state to retain the exact 0.23 structural fingerprint used by FR2. It did not: 0.24.0 (released 2026-08-13) added `role`, `provenance`, `locator`, `entry_id`, and `entry_revision` to `memory_chunks` for the canonical memory corpus. A full DDL diff confirmed this was the only schema change – `tasks.db` tables, indexes, and triggers were unchanged. Per the gate's own instruction the compatibility contract was **refreshed, not implicitly widened**: FR2's bounded transition rebased from the exact 0.23 shape to the exact 0.24 shape. This note previously stated that ADR-045 was amended accordingly on 2026-08-14; that amendment was never written into the ADR. S02 writes it in-milestone, together with the 0.25 rebase below.
> *2026-09-02 evaluation, on released 0.25.0 (the milestone was renumbered 0.26 after Lean Runtime shipped as 0.25):* the gate fired again. 0.25 dropped `workflow_step_executions.external_artifact_mount` with no migration (`CHANGELOG.md` 0.25.0: existing databases keep a nullable orphan column that no statement names), so a store created fresh by 0.25 and a store upgraded from 0.24 carry different column sets while both are valid to the running code; every other SQLite DDL is byte-identical 0.24 → 0.25. The contract is again refreshed, not widened: FR2's bounded transition targets the exact released 0.25 required structure; the required-object manifest (tables, columns, indexes) tolerates the documented orphan column by construction rather than fingerprinting it; no second adoption path (0.24-plus-0.25) is supported. The plan bundle (`plan.json` and every FIS) was regenerated 2026-09-02 against the released 0.25 tree, superseding the 2026-08-14 re-preflight list.

> **Terminology**: `FullTextIndex` names a backend-neutral lexical document-index port, not a global index over every knowledge layer. Phase A instantiates it twice: the memory-document corpus (FR3) and – rider, owner 2026-08-07 – the conversation-message corpus (FR11). Temporal knowledge-graph facts remain authoritative in `kg_facts` and use a separate fact-search path; wiki pages remain file-backed and are searched separately. Retrieval surfaces merge these layers at the application boundary. Rider (owner, 2026-08-07): the authoritative SQLite store file is renamed `tasks.db` → `dartclaw.db` (FR12/S14); references to `tasks.db` in this PRD and in the S01–S06 FIS denote that store under its pre-rename name, accurate at those stories' wave time.

## Executive Summary

- **Problem**: DartClaw's SQLite persistence ties the authoritative task data to the app host (no separately hosted, backed-up data tier) and its FTS5 search cannot stem non-English text – Swedish queries like "springa" miss documents containing "springer"/"springande". Multi-language (Swedish) search is now an owner-confirmed requirement; SQLite has no path to it.
- **Vision**: One storage abstraction, two backends. SQLite stays the zero-ops default – the supported 0.25 → 0.26 transition preserves the existing experience. PostgreSQL becomes an opt-in backend giving operators a managed, separately hosted, backed-up data tier plus language-aware full-text search as a config value.
- **Target Users**: (a) solo developers on the SQLite default – must notice nothing in the supported 0.25 → 0.26 transition; (b) operators deploying `dartclaw serve` against managed PostgreSQL (RDS/Neon/Supabase or self-hosted); (c) users with non-English (Swedish-first) content who need morphology-aware search; (d) contributors maintaining current schemas without a premature upgrade framework.
- **Success Metrics**:
  1. Zero behavior change for supported SQLite stores: full workspace test suite green after the Phase-1 refactor; no config, data-dir, or manual storage action for the 0.25 → 0.26 transition.
  2. Swedish search works across both primary knowledge layers on the PostgreSQL backend: with `fts_language: swedish`, regular morphological variants match in memory documents and temporal-KG facts (query "springa" finds content containing "springer"/"springande"); acceptance tests prove both paths.
  3. The shared `databaseBackendContractTests` suite passes 100% on both backends in CI (PostgreSQL via `@Tags(['integration'])` in a new `ci.yml` job with a postgres service container and an explicit tagged invocation), including tenancy-isolation and set-membership-parity assertions; the `PostgreSQL contract` job is registered in `dev/tools/release_check.sh` gate 10's required-job list, and the operator's branch-protection activation is recorded as the external gate (amended 2026-09-02).
  4. Fail-closed posture verified by test: cleartext credential to a non-loopback host, second instance on one `DATABASE_URL`, incompatible authoritative schema, and unreachable PostgreSQL at startup each refuse loudly with an actionable error.
  5. No DSN or credential ever appears in logs, exceptions, or `dartclaw config` output – redaction tests cover the connect-failure and startup-abort paths.

### Capabilities at a Glance

- **FR1: Backend-Agnostic Storage Layer** _(Must / P0)_ – `DatabaseBackend` seam behind the `tasks.db`/`search.db` surfaces (census recounted 2026-09-02 against released 0.25: 18 `package:sqlite3` importers – 15 in `dartclaw_core`, 1 in `dartclaw_workflow`, 2 in `dartclaw_runtime` – plus 5 `dartclaw_cli` typedef consumers; all route through the seam except the 2 open-helpers it replaces and, until FR13, the 2 instance-local stores); SQLite-only pure refactor, zero behavior change, lands first.
- **FR2: Current-Schema Bootstrap & Compatibility Gate** _(Must / P0)_ – fresh stores receive the current schema; one epoch plus backend-owned required-object manifests detect incompatibility; the exact released 0.25 SQLite required structure has one transactional repair (the documented orphan column is tolerated, not fingerprinted); derived search storage rebuilds where complete reconstruction is supported; no general migration framework.
- **FR3: Full-Text Index Abstraction with Tenancy** _(Must / P0)_ – generic `FullTextIndex` lexical-document contract carrying the `user_id` isolation dimension (a real tenancy key: per-persona workspaces after 0.26 and context-engine read clients populate it, so no wiring pins it to the single owner as a constant); Phase A's instance is the memory corpus and its FTS5 implementation preserves current search behavior.
- **FR4: Opt-In PostgreSQL Backend** _(Must / P0)_ – `database.backend: postgres` with pooled connections, single-database layout, pre-dispatch-only retry policy, transaction-integrity spike gate.
- **FR5: Language-Aware Search on PostgreSQL** _(Must / P0)_ – core-PG `tsvector`/`tsquery` search with configurable language across memory documents and temporal-KG facts (Swedish is the driving case); PG backend only.
- **FR6: Credential-Reference Database Configuration** _(Must / P0)_ – mutually exclusive `database.url` env substitution or `database.credential` generic-credential reference; inline passwords rejected; DSN redacted everywhere.
- **FR7: Connection Security Posture** _(Must / P0)_ – TLS fail-closed for non-loopback hosts (`verify-full` default), trusted host-side egress classification with lifecycle audit, two-role guidance.
- **FR8: Startup & Backend-Switch Semantics** _(Must / P0)_ – advisory-lock single-writer interlock with full-seam recovery quarantine, no-data-transfer switch semantics with abandoned-store notice, local recovery ordered before the backend gate, and no replay after ambiguous dispatch.
- **FR9: Dual-Backend Contract Test Suite** _(Must / P0)_ – `databaseBackendContractTests` both backends must pass; PG-live path under `@Tags(['integration'])` in CI.
- **FR10: Operator & Developer Documentation** _(Must / P1)_ – PostgreSQL deployment guide (roles, TLS, data-residency, decommission, schema compatibility/reset) plus architecture/config/glossary doc sync.
- **FR11: Conversation-Message Index** _(Must / P1; rider, owner 2026-08-07)_ – second `FullTextIndex` instance over session messages: NDJSON files stay authoritative, write-through indexing plus full rebuild, `user_id` tenancy, language-aware on PostgreSQL; service-layer search path sized for 0.27's Cmd+K conversation search (cross-surface decision D7).
- **FR12: Authoritative Store Rename** _(Must / P1; rider, owner 2026-08-07)_ – the authoritative SQLite store becomes `dartclaw.db`: fresh bootstrap uses the new name, the supported 0.25 transition adopts an existing `tasks.db` automatically (checkpoint-first, one atomic rename), both-present refuses loudly.
- **FR13: Filesystem-Backed Instance-Local State** _(Should / P1; rider, owner 2026-08-07 – TD-115)_ – turn-state and webhook-dedup storage move from instance-local SQLite (`state.db`, ledger) to plain filesystem stores with identical crash-recovery/dedup guarantees; PostgreSQL deployments then touch SQLite zero times at runtime, and the sanctioned instance-local-SQLite carve-out in the census fitness check is retired.

### Scope Highlights

- **In scope**: storage abstraction + current-schema bootstrap/compatibility over `tasks.db`/`search.db` (SQLite-only refactor first); opt-in PostgreSQL backend with language-aware memory-document and temporal-KG fact search; credential-reference config + redaction; conversation-message indexing as a second `FullTextIndex` instance (rider, 2026-08-07); authoritative-store rename `tasks.db` → `dartclaw.db` (rider, 2026-08-07); dual-backend contract tests; operator docs.
- **Out of scope**: `pgvector`/vector search (scheduled for Phase B, whose validation and ADR gates are satisfied); task indexing/search; multi-tenancy and active-active multi-instance; a SQLite→PostgreSQL data importer; changes to file-based storage as authoritative stores (FR11's conversation index is a derived projection over unchanged NDJSON) or to the instance-local semantics of turn state and the webhook ledger (FR13 changes their mechanism from SQLite to filesystem stores); changes to the QMD outpost; language-aware FTS on the SQLite backend.
- **MVP boundary**: both phases ship as one milestone (the demand gate closed on Swedish FTS); the Phase-1 refactor is an independently shippable zero-behavior-change checkpoint if the milestone is interrupted.

### Key Constraints, Assumptions & Dependencies

- *Constraint*: ADR-045's backend/security/runtime contracts and its 2026-07-30 schema-compatibility amendment are settled owner decisions – encoded here as requirements, not reopened.
- *Constraint*: `postgres` driver pinned `^3.5.12`; its gaps (no COPY, no force-close, no auto-retry) put reconnect/retry policy in DartClaw's wrapper.
- *Assumption (void at released 0.25, recorded 2026-09-02)*: the sync→async storage-signature contagion ADR-045 anticipated does not exist – the repositories, the execution transactor, and their `dartclaw_runtime`/`dartclaw_workflow`/`dartclaw_cli` callers are already `Future`-returning, so S04/S05 port implementations onto the seam without a caller-signature change.
- *Dependency*: a new `ci.yml` PostgreSQL service-container job for the live contract-test path (no service container or tagged-test invocation exists in CI at 0.25).
- *Constraint (plan decision 2026-09-02)*: `PostgresBackend` lands in `dartclaw_core` beside `SqliteBackend` – the 12-package ceiling in `dev/tools/arch_check.dart` is saturated, so no new package; `dartclaw_core`'s lib LOC ceiling is raised as a recorded rebaseline owned by S07.

## Problem Definition

### Problem Statement

DartClaw's relational store (`tasks.db`, `search.db`) is embedded SQLite. Two hard limits follow:

1. **Search cannot stem non-English text.** FTS5's only stemmer is the English-only `porter` tokenizer; `unicode61` treats Swedish inflections as unrelated opaque tokens. A user whose memory and knowledge-graph facts are in Swedish gets exact/prefix matching only – morphological variants silently miss. Swedish-language search is an owner-confirmed requirement (demand gate closed 2026-07-24) that SQLite cannot meet: no Swedish stemmer exists for FTS5 or as a Dart port.
2. **The data tier cannot leave the app host.** SQLite's file locality means backup, point-in-time recovery, and data-tier scaling are all DIY on the same machine that runs the process. Production deployments of `dartclaw serve` (the connected-CLI/remote-server direction since 0.16.4) increasingly want a managed, separately hosted database with standard ops tooling.

If nothing changes: Swedish/multi-language users get degraded search with no recourse, and remote-server deployments carry an unmanaged single-host data tier – both cap DartClaw's usefulness precisely where the product is heading.

A narrower internal requirement remains: the running release must never silently use a schema it cannot safely interpret. DartClaw is pre-alpha and makes no automatic-upgrade promise, so that safety requirement does not justify a production-grade migration subsystem yet.

### Evidence & Context

- ADR-045 (Accepted 2026-07-24) records the decision, an rg-verified census of 14 sqlite3-coupled production files, and eight owner-accepted posture/contract decisions after council review.
- FTS5 stemming limitation and PostgreSQL `tsvector` language configs (Snowball stemmers + stopwords, core PG, no extension) verified in ADR-045 § Context.
- The N-isolated-instances multi-user model (private backlog) and the desktop/mobile remote-`serve` drafts both point at separately hosted data tiers; ADR-045 notes the desktop-app synergy explicitly.
- Timing: 0.22 Afterglow implementation is complete; the backend track is free. The Phase-1 precondition (stable Windows SQLite baseline, 0.21) is satisfied.

## Scope

### In Scope

- `DatabaseBackend` abstraction (ratified hybrid shape) covering the sqlite3 coupling surface recounted 2026-09-02 against released 0.25: 18 `package:sqlite3` importers across `dartclaw_core`, `dartclaw_workflow`, and `dartclaw_runtime`, plus 5 `dartclaw_cli` typedef consumers (the 2 open-helpers are replaced by the seam; the 2 instance-local stores are refactored but stay outside it until FR13) – SQLite-only, zero behavior change, landing first as a pure refactor. The repositories and their callers are already `Future`-returning at 0.25, so no signature migration is in scope.
- Current-schema bootstrap and compatibility gating for both backends: preserve the supported 0.25 → 0.26 SQLite transition, initialize fresh stores, rebuild incompatible derived search storage only when complete reconstruction is supported, and refuse incompatible authoritative stores before use.
- Generic `FullTextIndex` lexical-document abstraction (tenancy-carrying), with the memory-document instance (FR3) and the FTS5 implementation preserving current search behavior.
- **(Rider, owner 2026-08-07)** Conversation-message indexing: a second `FullTextIndex` instance over session messages. `sessions/<id>/messages.ndjson` stays the sole authoritative store (ADR-002); the index is a derived, rebuildable projection. Write-through indexing at message append, full rebuild, session-deletion cleanup, `user_id` tenancy, language-aware on PostgreSQL via the shared `fts_language`. Service-layer search path only – UI/API exposure lands with 0.27's Cmd+K (cross-surface decision D7). See FR11.
- **(Rider, owner 2026-08-07)** Authoritative-store rename: the authoritative SQLite store file becomes `dartclaw.db` (fresh bootstrap and all open paths); the supported 0.25 transition adopts an existing `tasks.db` automatically (checkpoint-first) before open; both files present refuses loudly. `search.db` keeps its name. See FR12.
- **(Rider, owner 2026-08-07 – TD-115)** Filesystem-backed instance-local state: `state.db` (active-turn recovery) and the webhook delivery ledger are replaced by plain filesystem stores – atomic write-temp-rename JSON for turn state, file-per-event-id dedup with TTL purge for the ledger – preserving their exact crash-recovery and dedup guarantees with fault-injection parity tests. Locality is unchanged (ADR-045 decisions #3/Q4 rationale holds); only the mechanism changes. A PostgreSQL deployment then performs zero SQLite operations at runtime. See FR13.
- Opt-in `PostgresBackend`: config selection, `DATABASE_URL` credential-reference model, connection pool, single-database layout, reconnect/bounded-retry policy, startup interlock, TLS posture, egress audit.
- PostgreSQL-native language-aware search (`tsvector`/`tsquery`, configurable `fts_language`, Swedish as the acceptance case) for memory documents and temporal-KG facts – on the PostgreSQL backend only. KG facts are queried directly from `kg_facts`, never copied into `FullTextIndex`.
- Dual-backend contract-test suite with tenancy and set-membership-parity assertions; PG-live CI path.
- Operator documentation (PostgreSQL guide) and developer doc sync (architecture deep-dives, config reference, glossary).

### Out of Scope

- **`pgvector` / in-database vector search** – out of Phase A; **delivered by 0.26 Phase B** ([hybrid-search-prd-brief.md](hybrid-search-prd-brief.md)). The formerly-blocking embedding-source decision was made 2026-07-25 (`../../research/dart-native-hybrid-search/research.md`: in-process llamadart embeddings + a new `dartclaw_search` package composing the `FullTextIndex`/`VectorIndex` seams). QMD remains the semantic-search answer until Phase B ships.
- **Multi-tenancy / active-active multi-instance** – the N-isolated-instances model is unchanged; this milestone *enables* a shared data tier for one logical instance and adds a fail-loud interlock against accidental dual-attach, nothing more.
- **SQLite→PostgreSQL data importer** – explicitly a separate future tool (blocked on driver COPY support). Backend switch never migrates data.
- **File-based storage** (sessions, messages, memory files, config, projects) – untouched as authoritative stores. (Rider 2026-08-07: FR11 adds a *derived* conversation-message index over session NDJSON; the files and their write path are unchanged. The original blanket exclusion was inherited from the ADR-002 zone split, not a weighed search decision – see Decisions Log.)
- **`state.db` and the webhook delivery ledger** – stay instance-local always; outside the abstraction. (Rider 2026-08-07, FR13: their *mechanism* changes from SQLite to plain filesystem stores late in Phase 1 – locality and semantics unchanged, TD-115.)
- **QMD outpost** – unchanged in Phase A; it indexes markdown memory files, a different corpus. (Its deprecate-then-remove path was decided 2026-07-25 and begins in Phase B, not here.)
- **Language-aware FTS on SQLite** – the default backend keeps `unicode61` exact/prefix matching; no pre-stemming workarounds.
- **Task indexing/search** – tasks remain available through their existing structured repository/API paths; this milestone adds no task search producer or index.
- **Web UI changes** – no new UI surfaces; existing search UIs work unchanged against either backend.
- **Versioned migrations and automatic incompatible-schema upgrades** – no migration runner, history, dialect stream, generator, transaction directives, or recovery subsystem while DartClaw remains pre-alpha. Revisit when compatibility becomes a product promise or manual resets become unacceptable.

### MVP Boundary

The full milestone (both phases) is the MVP: the demand gate that committed it is the Swedish-FTS requirement, which only the PostgreSQL backend satisfies. Internally, the Phase-1 refactor (FR1–FR3) must land first and leave `main` shippable with zero behavior change – it is the fallback release point if the milestone is interrupted.

## Functional Requirements

### User Stories

| ID | Story | Acceptance Criteria | Priority |
|----|-------|---------------------|----------|
| US01 | As a solo developer on the default setup, I want the SQLite backend to keep working exactly as before, so that adopting 0.26 costs me nothing. | Full test suite green post-refactor; no config, data-dir, behavior, or manual storage action for the supported 0.25 SQLite state. | Must / P0 |
| US02 | As an operator, I want to point DartClaw at managed PostgreSQL through an env-substituted URL or existing named credential, so that my data tier is separately hosted, backed up, and recoverable independent of the app host. | `database.backend: postgres` plus exactly one resolvable `database.url`/`database.credential` initializes a fresh DartClaw schema or validates a compatible one, then serves all task/search functionality; `pg_dump`-style provider tooling works on the resulting single database. | Must / P0 |
| US03 | As a user with Swedish content, I want search to match morphological variants across memory and the knowledge graph, so that I find remembered content and structured facts regardless of regular inflection. | With `fts_language: swedish` on PG, "springa" matches both a memory document and a temporal-KG fact containing "springer"/"springande"; both paths are test-proven. Tasks are explicitly excluded; irregular ablaut forms are excluded – see FR5. | Must / P0 |
| US04 | As an operator, I want database credentials kept out of config files, logs, and CLI output, so that adopting PostgreSQL doesn't leak secrets. | Inline password in persisted config rejected at validation; DSN redacted in logs/exceptions; `dartclaw config` masks the URL. | Must / P0 |
| US05 | As an operator, I want misconfiguration and incompatible authoritative storage to refuse loudly instead of degrading silently, so that I can't corrupt data or leak credentials by accident. | Cleartext-to-non-loopback, dual-attach, and incompatible authoritative schema each abort startup with a distinct actionable error. | Must / P0 |
| US06 | As an operator switching backends, I want unambiguous data-fate semantics, so that I don't discover data "loss" or an orphaned remote corpus by surprise. | No data is transferred: a fresh selected backend bootstraps empty, while an existing compatible selected backend reopens its data; startup prominently notices an abandoned non-empty store for the other backend (best-effort – FR8); decommission guidance in the guide. | Must / P0 |
| US07 | As an experimental user, I want fresh stores initialized automatically and incompatible authoritative stores refused explicitly, so that schema churn cannot cause silent corruption or deletion while DartClaw avoids premature upgrade machinery. | Fresh bootstrap and compatible reopen work on both backends; incompatible authoritative stores fail before use; derived search storage rebuilds only from complete supported sources. | Must / P0 |
| US08 | As a user, I want past chat conversations to be searchable, so that I can recall what was discussed and decided across sessions. (Rider, 2026-08-07.) | Session messages are indexed into a dedicated conversation `FullTextIndex` instance at write time; a service-layer search returns tenancy-scoped, scored hits with session/message provenance; full rebuild reconstructs the index from NDJSON alone; on PG with `fts_language: swedish`, regular morphological variants match. UI exposure ships in 0.27 (Cmd+K, D7). | Must / P1 |

### Feature Specifications

#### FR1: Backend-Agnostic Storage Layer

**Description**: Introduce the `DatabaseBackend` abstraction (ratified hybrid shape – ADR-045 decision #7) as the single seam between storage services and the database engine, and refactor the entire rg-verified sqlite3 coupling surface against it. Recounted 2026-09-02 against released 0.25 (ADR-056 absorbed `dartclaw_storage` into `dartclaw_core`): 18 `package:sqlite3` importers – 15 in `dartclaw_core`, 1 in `dartclaw_workflow` (`sqlite_workflow_run_repository.dart`), 2 in `dartclaw_runtime` (`service_wiring.dart`, `storage_wiring.dart`) – plus 5 `dartclaw_cli` typedef consumers. The `tasks.db`/`search.db` surfaces route through the seam (the 2 open-helper files `task_db.dart`/`search_db.dart` are replaced by it); the 2 instance-local stores are refactored but stay outside it (AC1). Ships SQLite-only as a pure refactor before any PostgreSQL code.

**Acceptance Criteria**:
- [ ] All 18 census files (in `dartclaw_core`: task/goal/agent-execution/workflow-step repositories, execution transactor, execution row mappers, task-event/turn-trace/memory services, canonical index reconciler, turn-state store, webhook delivery store, temporal-KG service, `task_db.dart`/`search_db.dart` helpers; in `dartclaw_workflow`: the workflow-run repository; in `dartclaw_runtime`: `service_wiring.dart`/`storage_wiring.dart`) are refactored: the `tasks.db`/`search.db` surfaces consume the backend seam, while the webhook ledger and `state.db` code keep their direct instance-local SQLite usage per decisions #3/Q4 until FR13 (neither consumes the `TaskDbFactory`/`SearchDbFactory` typedefs, which are removed with the `task_db.dart`/`search_db.dart` helpers). The composition root – `DartclawRuntime.build` → `StorageWiring.wire()` in `dartclaw_runtime` – is refactored to construct the backend seam for the `tasks.db`/`search.db` surfaces instead of raw `Database` instances; `dartclaw_cli` commands (which carry zero `package:sqlite3` imports at 0.25) reach stores only through injected factories. The instance-local opens (`state.db` is opened in `StorageWiring` today; the ledger self-opens) stay direct SQLite, homed wherever the spec places them (store-side self-open or a sanctioned wiring call site). No `package:sqlite3` import remains outside `SqliteBackend` (the SQLite backend implementation) and, until FR13 retires the carve-out, the instance-local store surface (the two stores plus their open call sites). *(Census history: the 2026-08-14 recount against released 0.24 added `index_reconciler.dart` and `sqlite_execution_row_mappers.dart` as seam consumers, not allowlist entries – the reconciler in particular must reach PostgreSQL under S09; the 2026-09-02 recount against released 0.25 found the 16 storage files moved into `dartclaw_core`/`dartclaw_workflow`, the two wiring files moved into `dartclaw_runtime`, and `release_sqlite_check_command.dart` and `cli_workflow_wiring.dart` deleted.)*
- [ ] The seam is async end-to-end (the repositories, the execution transactor, and their callers are already `Future`-returning at 0.25, so this is a contract property of the seam, not a signature migration); the SQLite `transaction()` implementation serializes access for the awaited body's full duration (single-slot queue holding `BEGIN…COMMIT`, reusing the `SqliteExecutionRepositoryTransactor` pattern) – an interleaving operation cannot enter an open transaction.
- [ ] Nested/reentrant `transaction()` calls reject with `NestedTransactionError` on both backends. A prepared statement created through a transaction handle is transaction-bound: use after transaction completion throws `StateError`, while `close()` remains idempotent.
- [ ] Portable-subset CRUD goes through the thin backend (placeholder rewriting incl. literal-aware cases + result-type marshalling + prepared-statement handles); FTS stays behind `FullTextIndex` (FR3).
- [ ] The census is re-run at spec time repo-wide (`packages/` + `apps/`, tests excluded) with both instruments: `package:sqlite3` imports (**18 files: 15 `dartclaw_core` + 1 `dartclaw_workflow` + 2 `dartclaw_runtime`**, recounted 2026-09-02 against released 0.25; the 2026-08-14 recount against released 0.24 gave 16 storage files + 4 `dartclaw_cli` files) **and** `TaskDbFactory`/`SearchDbFactory`/`openTaskDb`/`openSearchDb` consumers (**5 `dartclaw_cli` files** – the typedef-mediated command call sites the import census misses; 8 at released 0.24, of which two moved into `dartclaw_runtime` and one was deleted in 0.25; `rebuild_index_command.dart` left this set in 0.24 when it moved to `CanonicalIndexReconciler`). Any drift is reflected in the plan, not discovered mid-story.
- [ ] Zero behavior change: full workspace test suite green; no schema, data-format, or user-visible change.

**Inputs / Outputs**:
- **Inputs**: existing storage-service call sites; existing `tasks.db`/`search.db` data.
- **Outputs**: identical persisted state and query results; storage/service APIs stay `Future`-returning (already async at 0.25).

**Validation**: a repo-level check (fitness function or targeted test) proves no stray `package:sqlite3` import outside the sanctioned surface: `SqliteBackend` and, until FR13, the instance-local stores plus their open call sites (`release_sqlite_check_command.dart` was deleted in 0.25). The sanctioned surface lives in `dartclaw_core`, the only package that may carry the sqlite3 and postgres drivers (plan decision 2026-09-02); `dartclaw_workflow` and `dartclaw_runtime` drop their sqlite3 dependency once their importers move onto the seam.

**Error Handling**: backend errors surface as typed storage exceptions; no behavioral change to existing error paths in this phase.

**Priority**: Must / P0

#### FR2: Current-Schema Bootstrap & Compatibility Gate

**Description**: DartClaw initializes a fresh SQLite or PostgreSQL store with the schema required by the running release and refuses to use an authoritative store whose schema it cannot safely interpret. During pre-alpha, DartClaw does not promise automatic data-preserving upgrades between incompatible schemas.

**Acceptance Criteria**:
- [ ] A fresh store receives the running release's complete schema before repository use.
- [ ] Each backend records one current schema epoch and validates a backend-owned manifest of required tables, columns, and indexes before repository use. Missing, older, newer, or malformed epochs and epoch/structure mismatches are incompatible.
- [ ] The exact verified released-0.25 SQLite required structure opens without operator action using only the narrow transition repair required by 0.26. The documented orphan column `workflow_step_executions.external_artifact_mount` (present on stores upgraded from 0.24, absent on stores created by 0.25 – `CHANGELOG.md` 0.25.0) is tolerated by the required-object manifest rather than fingerprinted; any other older or structurally different shape is incompatible. This bounded exception does not become an ordered history, a second adoption path, or a general upgrade framework.
- [ ] Fresh bootstrap and the 0.25 repair are transactional: they either commit the complete current schema or roll back safely. Fault-injection tests prove failure after each schema step leaves no partially initialized or partially repaired authoritative store.
- [ ] An incompatible authoritative `tasks.db` or PostgreSQL schema is never deleted, partially initialized, or used; startup identifies the store and gives backup/reset/recreate guidance.
- [ ] An incompatible derived `search.db` is rebuilt automatically only when complete supported sources can reconstruct it; otherwise startup fails explicitly rather than serving partial search state.
- [ ] No general migration runner, version stream, migration history, SQL code generator, rollback directive, extension hook, or wedged-migration recovery subsystem is introduced.
- [ ] Tests cover fresh bootstrap on both backends; the exact 0.25 SQLite transition (both the fresh-0.25 and the upgraded-from-0.24 column set); compatible reopen; missing, older, newer, malformed, and epoch/structure-mismatch refusal; transactional rollback under injected bootstrap/repair failure; authoritative incompatibility refusal; and derived-search rebuild/refusal.

**Inputs / Outputs**:
- **Inputs**: backend selection; store presence; current schema epoch; backend-owned required-object manifest; exact released-0.25 SQLite transition shape.
- **Outputs**: a ready current-schema store, a safely rebuilt derived search store, or an actionable refusal before repository use.

**Validation**: shared bootstrap/compatibility contracts prove current-schema parity and every specified startup outcome without relying on migration history.

**Error Handling**: authoritative incompatibility fails before repository use and never deletes data; interrupted bootstrap or bounded repair rolls back; derived search rebuild failure is explicit and leaves the prior store recoverable.

**Priority**: Must / P0

#### FR3: Full-Text Index Abstraction with Tenancy

**Description**: Lexical document operations move behind a generic `FullTextIndex` contract so each backend emits its own dialect. This FR's instance owns the memory-document search projection (the FR11 rider later adds a separate conversation-message instance); the name does not imply one global index over KG, wiki, tasks, or every future corpus. The contract carries the `user_id` tenancy dimension on search, upsert, and delete – it is the live isolation mechanism; an implementation without it is a cross-user confidentiality or integrity regression (ADR-045 decision #7 rider).

**Acceptance Criteria**:
- [ ] `FullTextIndex` requires `user_id` on search, upsert, and delete; `SearchResult` fields and `metadata` semantics are pinned in the spec.
- [ ] The contract stays corpus-agnostic. 0.24's canonical memory identity – `role`, `provenance`, `locator`, `entry_id`, `entry_revision` – travels as reserved **metadata keys** owned by the memory corpus, not as contract fields, so the conversation corpus (FR11) and Phase B's `VectorIndex` reuse the same shapes (owner decision 2026-08-14). A memory-side mapper owns the vocabulary, the `entry_revision` string↔`int` round trip, and the canonical-role invariant (canonical role ⇒ entry identity present, else `StateError`). Dropping any of these in the round trip breaks `memory_read` selectors and live citation resolution, and violates ADR-045's 2026-08-12 memory-preservation constraint.
- [ ] The FTS5 implementation reproduces current search behavior (tokenization, `bm25()` ranking, filters) – zero user-visible change on SQLite. The `error` canonical role added in 0.25 stays outside the searchable role set (`CHANGELOG.md` 0.25.0); neither backend projects `error` rows into the search vector.
- [ ] The shared contract suite (FR9) asserts read and mutation isolation on both backends: user A cannot search, overwrite, or delete user B's content, including when both users present the same document identifier.
- [ ] Search-index rebuild flows work unchanged through the abstraction.
- [ ] Temporal-KG facts are never copied into the memory `FullTextIndex`; KG search reads authoritative `kg_facts` through its own backend-specific query path, and application-layer retrieval merges the two result layers.

**Inputs / Outputs**:
- **Inputs**: memory documents + metadata + user scope; search queries.
- **Outputs**: scored memory results; memory-index mutations.

**Validation**: contract-suite tenancy assertions; existing search tests pass unchanged on SQLite.

**Error Handling**: index unavailability surfaces as the existing degraded-search behavior, never as cross-scope results.

**Priority**: Must / P0

#### FR4: Opt-In PostgreSQL Backend

**Description**: A `PostgresBackend` implementation of the seam, selected via `database.backend: postgres`, connecting through the pooled `postgres` driver (pinned `^3.5.12`) to a single PostgreSQL database (the `tasks.db` + `search.db` surfaces collapse into one database, one pool, one `DATABASE_URL`).

**Acceptance Criteria**:
- [ ] With PostgreSQL configured, all task, goal, workflow-run, event, trace, KG, and search functionality passes the contract suite; the server runs its full lifecycle (boot → bootstrap/validate schema → serve → shutdown closing the pool).
- [ ] SQLite remains the default; omitting `database:` config yields today's behavior. A deployment uses exactly one backend – never a mix.
- [ ] Reconnect policy lives in DartClaw's wrapper (driver has no auto-retry). It retries only failures proven to occur before dispatch. Once an operation was dispatched and its commit outcome may be ambiguous, DartClaw never auto-replays it and surfaces `StorageUnknownOutcomeException`; startup connect failure fails closed (FR8).
- [ ] `pool_size` configurable (provisional default 5, tuned during the milestone for single-threaded await-concurrency).
- [ ] A targeted transaction-integrity spike verifies `runTx` rollback/failure paths and the R2 SQLite serialization contract before transaction-bearing stories complete (Serverpod's `^3.4.0` social proof does not cover the 3.5.12 fixes).

**Inputs / Outputs**:
- **Inputs**: `database.*` config; reachable PostgreSQL ≥ a spec-pinned minimum version.
- **Outputs**: identical functional behavior to SQLite (modulo the contractual ranking difference, FR9); connection lifecycle audit events (FR7).

**Validation**: startup validates config completeness (backend `postgres` requires exactly one resolvable `database.url` or `database.credential`) before any connection attempt.

**Error Handling**: driver/auth exceptions are redacted (FR6) and mapped to the same typed storage exceptions as SQLite; pool exhaustion surfaces as a bounded wait then a typed error, not a hang.

**Priority**: Must / P0

#### FR5: Language-Aware Search on PostgreSQL

**Description**: PostgreSQL uses core-PG `tsvector`/`tsquery` with one configurable language (`fts_language`, default `english`) across two deliberately separate paths: the memory corpus through `PostgresFtsIndex`, and temporal facts through direct queries over authoritative `kg_facts`. Swedish is the driving requirement. This ships on the PostgreSQL backend only – the SQLite default keeps its existing FTS5 memory behavior and substring KG matching.

**Acceptance Criteria**:
- [ ] `fts_language: swedish` produces stemmed matching in both the memory corpus and temporal-KG fact search: regular inflection-variant queries (e.g. "springa" ↔ "springer"/"springande") return the expected memory documents and KG facts in separate acceptance fixtures.
- [ ] Snowball stemming is suffix-stripping: irregular/ablaut forms (e.g. "sprang" vs "springa") do not conflate and are not part of the acceptance bar; this limitation is documented in the PostgreSQL guide (FR10).
- [ ] Language is a config value, not a code or DDL choice. Switching it requires `dartclaw rebuild-index` for the stored memory `FullTextIndex` vectors; direct KG fact search uses the new language on the next query after restart and has no KG reindex step.
- [ ] The current schema is language-neutral: the configured language is bound as data when vectors/queries are produced, never baked into schema DDL.
- [ ] KG fact search computes its `tsvector` at query time over `entity`, `predicate`, `value`, and `source`, with the language bound as data. It adds no KG search-vector column or GIN index in v1; the expected KG corpus is small, matching the existing SQLite scan, and indexing is deferred until measurement justifies it.
- [ ] Default `english` config passes the shared contract-suite membership assertions identically to FTS5 (those fixtures are divergence-neutral by construction – FR9); stemming gains are asserted in the backend-specific FR5 fixtures, not the parity suite.
- [ ] One deployment-level language config applies to the whole memory index and all KG fact-text queries; mixed-language content can be mis-stemmed, and per-document/per-fact detection is deferred until a real complaint.
- [ ] No extension required – core PG only (`pg_trgm`/fuzzy matching explicitly not included).
- [ ] No task index or task-search producer is introduced; task lookup remains structured and is outside US03.

**Inputs / Outputs**:
- **Inputs**: `database.fts_language`; memory documents; authoritative KG facts.
- **Outputs**: language-stemmed ranked memory results (`ts_rank` – ranking order is backend-specific by contract) and separately ordered KG fact results preserving existing temporal/domain semantics, merged only by existing application retrieval surfaces.

**Validation**: config accepts only PG-shipped language configuration names; unknown value fails at startup validation with the valid list.

**Error Handling**: a language config missing on the server (nonstandard build) fails startup validation with an actionable message.

**Priority**: Must / P0

#### FR6: Credential-Reference Database Configuration

**Description**: Database configuration reuses the existing generic credential registry without a database-specific credential type or store. `database.url` is an env-substituted DSN such as `${DARTCLAW_DATABASE_URL}`; alternatively, `database.credential` names an existing generic `credentials:` entry whose resolved value is the DSN. The two fields are mutually exclusive, inline DSNs containing credentials are unsupported, and the resolved DSN is redacted everywhere it can surface.

**Acceptance Criteria**:
- [ ] Config validation requires exactly one of `database.url` or `database.credential` for the PostgreSQL backend, rejects both together, rejects an inline password in `database.url`, and reports the existing env-substitution/generic-credential mechanisms.
- [ ] `database.credential` resolves through the existing `CredentialEntry`/`CredentialRegistry` path in `dartclaw_kernel` (`resolve` is synchronous and runs before any async connect); no new credential type, registry, or storage mechanism is introduced.
- [ ] `MessageRedactor` (in `dartclaw_kernel`; key-side and unconditional since 0.25 – a secret-shaped key redacts its value, the value-side prose heuristics are gone) covers `://user:pass@` DSN shapes, extending the key-side rule to DSN userinfo where the key alone does not catch it; driver connection/auth exceptions are redacted before logging – including the fail-closed schema bootstrap/compatibility path, which aborts without ever logging the raw DSN.
- [ ] `dartclaw config` output masks the URL the same way credential entries are masked.
- [ ] Hot-reload/config-editor surfaces treat `database.*` as boot-time config: the section declares `ConfigReloadTier.restart` in `ConfigNotifier` (0.25 requires a declared tier per section); live backend switching is not supported (documented).

**Inputs / Outputs**:
- **Inputs**: env-substituted `database.url` or named `database.credential`; existing env and generic credential registry.
- **Outputs**: resolved DSN in memory only; masked forms in all observable surfaces.

**Validation**: redaction unit tests cover log, exception, audit, and CLI paths, including malformed-DSN edge shapes: passwords containing `@` or `:`, percent-encoded credentials, the keyword/value DSN form (`host=x password=secret` – no `://`), and missing-scheme strings.

**Error Handling**: an unresolvable env substitution or named credential fails startup with the variable/reference name (never the partial value).

**Priority**: Must / P0

#### FR7: Connection Security Posture

**Description**: Encode the accepted security posture (ADR-045 decisions #1, #5, #6): TLS fail-closed for non-loopback hosts, trusted host-side egress classification with lifecycle audit, and a documented two-role least-privilege model.

**Acceptance Criteria**:
- [ ] A non-loopback DSN with omitted `sslmode` resolves to effective `verify-full`. An explicit cleartext/disabled mode to a non-loopback host fails closed at startup (mirrors the outbound-MCP rule); loopback remains exempt.
- [ ] Loopback classification adopts the existing `dartclaw_kernel` predicate `isLoopbackHost` (`network_guard.dart`) as the single MCP+DB seam; `HttpMcpTransport`'s private duplicate is retired – no cross-package reach into transport internals. Recorded consequence (plan decision 2026-09-02, owner may veto): the kernel predicate accepts `localhost`, `127.0.0.1`, and `::1` only, so the outbound-MCP TLS loopback exemption narrows from `127.0.0.0/8` to those literals; S08 records it as a CHANGELOG line and a security-doc correction.
- [ ] The DB connection is classified trusted host-side egress (git-operations category): initiated by the host storage layer, not reachable from agent tooling, outside the agent egress guard chain – and this classification is documented in the security architecture doc.
- [ ] Connection lifecycle events (open, close, auth failure) are audited through the existing `GuardAuditLogger`/`AuditEntry` sink in `dartclaw_kernel` – not as `DartclawEvent` subtypes, whose sealed library ADR-057 closes.
- [ ] Two-role model documented: an elevated administrator provisions the database, runtime role, and DartClaw-owned schema; the runtime role connects thereafter and may create/use the current release's objects only within that schema. Startup warns when the runtime role is superuser. No second application credential or role-switching machinery; not enforced in v1.

**Inputs / Outputs**:
- **Inputs**: DSN host/`sslmode`; server TLS certificates.
- **Outputs**: refused startup on posture violation; audit events; superuser warning.

**Validation**: posture tests cover loopback-exempt, non-loopback-TLS, and non-loopback-cleartext matrices.

**Error Handling**: TLS/verification failures produce actionable errors distinguishing explicit cleartext disablement, failed verification, and an untrusted CA, with the redaction guarantees of FR6.

**Priority**: Must / P0

#### FR8: Startup & Backend-Switch Semantics

**Description**: Encode the accepted operational contracts (ADR-045 decisions #2, #4, #8): single-writer interlock, no-data-migration switch semantics, and outage/boot-ordering behavior.

**Acceptance Criteria**:
- [ ] The PostgreSQL backend takes a session-scoped advisory lock on a dedicated connection excluded from pool recycling. A second serve instance pointing at the same database fails loud with a clear conflict error. The lock is held for the process lifetime, auto-releases on crash, and is gracefully released on shutdown; connection loss enters the recovery quarantine below. No lease table, TTL/takeover, or fencing subsystem is introduced.
- [ ] On interlock loss, every storage-seam operation fails with the existing typed connection error while ownership is uncertain. Access resumes only after lock re-acquisition, PostgreSQL-version validation, and schema-compatibility validation all succeed. A failed re-acquisition, competing holder, version mismatch, or schema mismatch enters the existing condition-specific fail-stop path; no SQL read/write classifier or second storage seam is introduced.
- [ ] Switching `database.backend` never transfers data: a fresh selected backend bootstraps empty, while an existing compatible selected backend reopens its data. Startup logs a prominent notice when a non-empty abandoned store exists for the other backend. The notice is best-effort where detection requires connectivity: a switched-away-from PostgreSQL store is only detectable while its URL remains resolvable (the SQLite-side check is local and always possible). A lingering `database.url` under `backend: sqlite` is legal config, retained for exactly this check; the probe inherits the FR7 connection posture, but any probe failure – including a posture violation – degrades to a could-not-verify notice, never a boot abort and never a posture bypass. FR6's fail-startup validation applies to the active backend's URL only: under the non-active backend, an unresolvable or invalid `database.url` is itself a probe failure (notice).
- [ ] Local orphan-turn recovery (instance-local `state.db`) runs **before** the backend/schema gate, so crash recovery works even when the network database is unreachable.
- [ ] PostgreSQL unreachable at startup: fail closed at connect. Mid-session: retry is bounded and limited to failures proven before dispatch. A dispatched operation with an ambiguous commit outcome is never auto-replayed; it fails with `StorageUnknownOutcomeException`. There is no silent queueing or data-loss ambiguity.
- [ ] Graceful shutdown releases the advisory lock and closes the pool.

**Inputs / Outputs**:
- **Inputs**: startup sequence; backend config; prior instance state.
- **Outputs**: exclusive instance ownership; deterministic recovery ordering; explicit refusals.

**Validation**: integration tests cover dual-attach refusal; full-seam quarantine after mid-session lock loss; successful re-acquisition, re-gating, and access resumption; condition-specific fail-stop; pre-dispatch retry; dispatched-write unknown outcome without replay; switching to fresh and populated targets; switch-back; abandoned-store notice; and unreachable-at-boot failure.

**Error Handling**: while recovery is pending, storage operations fail with the existing `StorageConnectionException` and interlock-recovery-pending catalog message. An ambiguous dispatched operation fails with `StorageUnknownOutcomeException`. Every terminal refusal names the condition and remediation (stop the other instance / restore config / check `DATABASE_URL` reachability / correct the failed gate).

**Priority**: Must / P0

#### FR9: Dual-Backend Contract Test Suite

**Description**: A shared `databaseBackendContractTests` suite (pattern: existing `searchBackendContractTests`) that both backends must pass, wired into CI so the PostgreSQL path cannot silently rot.

**Acceptance Criteria**:
- [ ] The suite covers the portable CRUD surface; transactions (atomicity/rollback, unrelated operations never entering an open transaction, nested rejection and transaction-bound prepared-statement lifetime on both backends, completion ordering additionally on SQLite); pre-dispatch retry versus ambiguous-outcome no-replay; fresh bootstrap/compatible reopen/schema incompatibility and fault rollback; FTS membership; and read/mutation tenancy isolation.
- [ ] Search parity is contractual on **set membership only**: both backends return the same result set for parity fixtures; ranking order is explicitly backend-specific (`bm25()` vs `ts_rank`) and not asserted. Parity fixtures use divergence-neutral terms: stemming-neutral (stemming makes PG a superset on inflected queries), stopword-free (PG language configs strip stopwords that FTS5's `unicode61` indexes – the reverse direction), tokenizer-neutral (no compounds/emails/URLs the two tokenizers split differently), and diacritic-exact (FTS5's default `remove_diacritics=1` folds å/ä/ö; core PG does not). Any further exclusion requires reviewed engine-level evidence and an explicit durable divergence-whitelist entry; unexplained membership drift fails the suite. Stemming- and stopword-dependent behavior is asserted only in the backend-specific FR5 fixtures.
- [ ] The PostgreSQL-live path runs under `@Tags(['integration'])` per TESTING-STRATEGY conventions – skipped by default on dev machines, run against a postgres service container in a new `ci.yml` job on every PR. CI has no service container and no tagged-test invocation at 0.25 (`test_workspace.sh` passes no `-t` selector), so the job invokes the tagged suites explicitly.
- [ ] SQLite contract runs are part of the default (untagged) suite.
- [ ] The suite is the enforcement home for the FR3 tenancy assertions and FR5 membership assertions.
- [ ] CI uses job id `postgres_contract` with display name `PostgreSQL contract`. The merge gate is `dev/tools/release_check.sh` gate 10: `PostgreSQL contract` is added to its required-job list (matched by name against the `Checks` run for the exact HEAD SHA), with a test covering the list. GitHub `main` carries no branch protection or ruleset at 0.25; the plan documents the operator's ruleset step in `RELEASE_PREPARATION.md`, and that activation remains the recorded external gate – repository-settings automation is not introduced. (Amended 2026-09-02; supersedes the 2026-07-30 operator-confirmation wording.)

**Inputs / Outputs**:
- **Inputs**: backend factories; shared fixtures (incl. Swedish/English corpora).
- **Outputs**: green CI on both backends, the `PostgreSQL contract` job registered in `release_check.sh` gate 10, and the operator branch-protection activation recorded as the external gate.

**Validation**: CI compares the JSON report's passing contract-group IDs with an explicit required-group manifest; a missing or skipped group fails. Phase A sign-off records that the named job is in gate 10's required list and whether the operator has activated the ruleset.

**Error Handling**: PG-container unavailability fails the CI job – never silently skips.

**Priority**: Must / P0

#### FR10: Operator & Developer Documentation

**Description**: Documentation shipped with the milestone, not after it.

**Acceptance Criteria**:
- [ ] **PostgreSQL deployment guide** (public user guide): setup + env-substituted `database.url` and named `database.credential` examples, TLS requirements, administrator provisioning + runtime-role example SQL, pool sizing, backup/restore pointers, third-party data-processor exposure (managed-PG providers store/retain authoritative task data – recommend at-rest encryption; retention/residency are the operator's responsibility), backend-switch semantics + decommission guidance for a switched-away-from remote database (incl. provider snapshots), search-layer/reindex behavior (memory `FullTextIndex` rebuild; query-time KG; live file-backed wiki; tasks excluded), a **storage-tiers-at-a-glance table** (rider, owner 2026-08-07: per store – what lives where, what to back up, what is transient/safe to lose; explicitly covering the filesystem-backed instance-local turn-state and webhook-dedup stores, FR13, and the file-based authoritative stores), and schema-compatibility/reset guidance.
- [ ] **Architecture doc sync** in the same change: `data-model.md` (backend abstraction, current-schema bootstrap/compatibility, single-PG-database layout, authoritative stores vs. derived search projections, and per-layer rebuild behavior), `security-architecture.md` (egress classification, TLS posture, credential handling), `configuration-architecture.md` (`database.*` section).
- [ ] **Config reference** (`../dartclaw-public/docs/guide/configuration.md`) is generated from `schemas/dartclaw.schema.json` and drift-gated since 0.25, so it is never hand-edited: `database.backend`, mutually exclusive `url`/`credential` (`readonly` in the schema), `pool_size`, and `fts_language` are registered as typed config fields with descriptions, the schema and the reference are regenerated, and the `database.*` operator keys are added to the core-key list (`dev/tools/config_reference_core_keys.txt`, ceiling ≤ 90; 58 entries at 0.25).
- [ ] **Glossary** (`UBIQUITOUS_LANGUAGE.md`): `Database Backend`, `Full-Text Index`, and `Schema Compatibility Gate` entries re-confirmed against shipped behavior at Phase A close; `Full-Text Index` is defined as the generic lexical-document port with two Phase A instances (memory documents, conversation messages – FR11 rider), not a global knowledge index.
- [ ] Canonical `docs/ROADMAP.md` and its public mirror `../dartclaw-public/dev/state/ROADMAP.md` are synchronized at Phase A close; the public entry records Phase A complete and keeps the overall 0.26 milestone open until Phase B completes.

**Inputs / Outputs**: n/a (documentation deliverable).

**Validation**: doc updates are explicit stories in the plan (project rule), reviewed against the shipped behavior.

**Error Handling**: n/a.

**Priority**: Must / P1

#### FR11: Conversation-Message Index (Rider, 2026-08-07)

**Description**: Session conversation messages become searchable through a second, dedicated `FullTextIndex` instance – the conversation corpus, separate from the memory corpus in table/index and lifecycle. `sessions/<id>/messages.ndjson` remains the sole authoritative store (ADR-002); the index is a derived, rebuildable projection, so the files-vs-index architecture is preserved, not changed. Provenance: the original "sessions, messages … untouched" exclusion was inherited mechanically from the ADR-002 zone split (2026-07-25 PRD session), flagged as a probable gap by the 2026-07-31 backlog audit, and decided as this rider by the owner 2026-08-07 – 0.27's Cmd+K conversation search (cross-surface decision D7) is the committed consumer, and landing the producer while the `FullTextIndex` seam is open avoids reopening storage in 0.27. The consumer is now recorded in `docs/specs/0.next-chat-and-sessions/prd-brief.md` § Phase C; the former numbered brief and the note requesting that addition are superseded.

**Acceptance Criteria**:
- [ ] Messages of chat-facing sessions (`user`/`main`/`channel` types; task, cron, and other internal session types excluded by one shared predicate) are indexed into a dedicated conversation `FullTextIndex` instance (own table/index, never mixed with the memory corpus) at message-append time on both backends; the NDJSON write path is unchanged.
- [ ] `user_id` tenancy is carried on every operation, populated with the instance-owner identity (sessions carry no per-user ownership model – owner decision 2026-08-07); FR3's isolation semantics apply – cross-user search, overwrite, and delete are contract-impossible.
- [ ] Full rebuild reconstructs the conversation index from NDJSON files alone; `dartclaw rebuild-index` covers it. FR2's derived-store policy applies: complete reconstruction is supported, so incompatible conversation-index storage rebuilds rather than refusing.
- [ ] Index cleanup covers both session lifecycle paths: session deletion removes that session's rows, and archive-reset (`SessionResetService` archives keyed sessions or clears user-session messages in place rather than deleting) removes the reset session's rows – archived sessions fall outside the chat-facing predicate.
- [ ] On PostgreSQL the shared `fts_language` applies (Swedish acceptance: regular morphological variants match in message content); SQLite keeps its existing `unicode61` sanitized-term matching – no stemming, and no prefix queries (the shared sanitizer quotes every term).
- [ ] Search is exposed as a service-layer query path returning scored hits with session/message provenance, sized for the Chat & Session Experience milestone's Cmd+K conversation search (D7). No new Web UI, HTTP endpoint, or agent-facing tool in 0.26; Cross-Session Recall (summarization, agent recall tooling) stays in the backlog.
- [ ] Doc sync in the same story: `data-model.md` search-layer ownership, user-guide search/workspace sections, and the glossary `Full-Text Index` entry (two instances).

**Inputs / Outputs**:
- **Inputs**: appended session messages + session ownership; search queries with user scope.
- **Outputs**: scored conversation hits (session/message provenance); conversation-index mutations.

**Validation**: producer, deletion-lifecycle, rebuild-parity, and tenancy tests on both backends.

**Error Handling**: index unavailability degrades conversation search only – never message persistence, and never cross-scope results.

**Priority**: Must / P1

#### FR12: Authoritative Store Rename – `tasks.db` → `dartclaw.db` (Rider, 2026-08-07)

**Description**: The authoritative SQLite store file is renamed from `tasks.db` to `dartclaw.db`. The current name predates goals, agent executions, workflow runs, turn traces, and `kg_facts` – it now misnames the runtime relational store and actively misleads (knowledge-graph facts living in "tasks.db" reads as a defect). DartClaw is pre-release and this milestone already builds the supported-transition machinery, making 0.26 the last cheap rename window. PostgreSQL is unaffected (the operator names the database via the DSN); `search.db` is accurately named and unchanged, and the turn-state/webhook-dedup stores are FR13's concern.

**Acceptance Criteria**:
- [ ] Fresh SQLite bootstrap creates `dartclaw.db`; every open path (serve, standalone/maintenance commands) resolves the authoritative store through one config accessor, with internal identifiers renamed to match.
- [ ] Supported 0.25 → 0.26 transition: when `dartclaw.db` is absent and `tasks.db` exists, the store is adopted automatically before any open for use – checkpoint-first (WAL checkpointed into the main file, then one atomic rename; owner decision 2026-08-07), no operator action, all committed data intact; combined with FR2's marker adoption this preserves US01.
- [ ] Both `dartclaw.db` and `tasks.db` present refuses startup loudly, naming both files (ambiguous store identity, e.g. after a downgrade/re-upgrade cycle) with keep/remove guidance – no silent pick.
- [ ] Refusal and notice messages that name the store (FR2 gate, FR8 abandoned-store notice) use the actual file name, not a hardcoded legacy label.
- [ ] Doc sync in the same story: `data-model.md`, user-guide storage/backup references, and the glossary.

**Inputs / Outputs**:
- **Inputs**: data-dir contents at startup (presence of `dartclaw.db` / legacy `tasks.db` + sidecars).
- **Outputs**: the authoritative store under its new name, or a loud both-present refusal.

**Validation**: tests cover fresh-bootstrap naming, legacy rename with and without sidecars, both-present refusal, and unchanged `search.db` naming; instance-local stores change separately under FR13.

**Error Handling**: a failed rename aborts startup before open for use with the file-level error; no committed data is lost, no `dartclaw.db` is created, and `tasks.db` remains authoritative. The preceding checkpoint may already have changed the main file and sidecar bytes.

**Priority**: Must / P1

#### FR13: Filesystem-Backed Instance-Local State (Rider, 2026-08-07 – TD-115)

**Description**: The two instance-local SQLite stores – `state.db` (active-turn crash-recovery state, transient) and the webhook delivery ledger (per-instance dedup markers, TTL-purged) – are replaced by plain filesystem stores. Both are serve-process-only, small, transient, and single-writer, so SQLite's cross-process locking is not load-bearing for them; the owner flagged the resulting Postgres+SQLite+filesystem triple as an architectural smell (TD-115). Locality is unchanged – ADR-045 decisions #3/Q4's rationale (crash recovery independent of network DB; per-instance dedup semantics) holds in full; only the storage mechanism changes. After this, a PostgreSQL deployment performs zero SQLite operations at runtime (the library still ships in the one binary per ADR-045 OQ3 – not reopened).

**Acceptance Criteria**:
- [ ] Turn-state persistence uses an atomic write-temp-rename filesystem store (the `meta.json` pattern); orphan-turn recovery behavior is byte-for-byte equivalent under the existing crash fixtures, including recovery running before the backend gate with PostgreSQL unreachable.
- [ ] Webhook dedup uses a file-per-event-id store with atomic create semantics and TTL purge; the TTL-anchor-moves-forward-on-commit behavior (LEARNINGS) is preserved and test-proven.
- [ ] Fault-injection parity: every failure scenario the current stores' tests cover (interrupted write, crash between operations, purge races) has an equivalent passing test against the filesystem stores, including Windows rename semantics.
- [ ] `state.db` and the ledger database file are no longer created; a leftover pre-existing `state.db`/ledger file is ignored (transient data – no migration; a note in the transition guidance suffices).
- [ ] The census fitness check tightens: no `package:sqlite3` import remains outside `SqliteBackend` – the instance-local-store carve-out sanctioned in FR1 is retired (the sqlite-specific release tooling FR1 once allowlisted, `release_sqlite_check_command.dart`, was deleted in 0.25).
- [ ] A PostgreSQL-backend integration test proves zero SQLite file handles/operations at runtime.
- [ ] Doc sync in the same story: ADR-045 decisions #3/Q4 mechanism amendment (public repo), `data-model.md`, and the FR10 storage-tiers table reflect filesystem-backed transient state.

**Inputs / Outputs**:
- **Inputs**: existing turn-state and webhook-dedup call sites; crash/dedup test fixtures.
- **Outputs**: identical recovery/dedup behavior from plain files; no runtime SQLite on PostgreSQL deployments.

**Validation**: existing crash-recovery and webhook-dedup suites pass against the filesystem stores; fault-injection and Windows-path tests added; fitness check proves the tightened import surface.

**Error Handling**: a failed state write surfaces exactly as today's store failure does (no silent loss); dedup-store failures fail closed for the affected delivery, never corrupting other markers.

**Priority**: Should / P1

### User Flows

1. **Default (unchanged)**: user installs 0.26 over the supported 0.25 SQLite state → no `database:` config → narrow transition repair and compatibility validation run before repository use → identical experience with no operator action.
2. **PostgreSQL adoption**: administrator provisions PG + runtime role/schema → operator configures either env-substituted `database.url` or named `database.credential` → sets `database.backend: postgres` (+ optional `fts_language: swedish`) → `dartclaw serve` validates config, connects with TLS, takes the advisory lock, bootstraps a fresh schema or validates a compatible one, serves → operator verifies via `dartclaw config` (masked reference/value) and search behavior.
3. **Failure/recovery**: PG unreachable at boot → startup aborts with actionable connect error (after local orphan-turn recovery has already run) → operator fixes reachability → clean boot. Authoritative schema is incompatible → startup refuses before repository use → operator backs up/exports if needed and resets/recreates the store for the running release.
4. **Backend switch**: operator flips `database.backend` → no data is transferred; a fresh target bootstraps empty or an existing compatible target reopens its data; prominent abandoned-store notice for the old backend (best-effort – FR8) → operator follows decommission guidance (export/snapshot/delete per the guide).

### Data Requirements

- Entities unchanged: tasks, goals, agent executions, workflow runs/steps, task events, turn traces, memory search content, KG facts – same logical model on both backends.
- PostgreSQL layout: one database, plain table namespace, one pool. `memory_chunks.content_tsv` is a rebuildable derived memory-search projection; `kg_facts` is authoritative and its v1 morphology-aware search vector is computed at query time rather than persisted.
- SQLite layout unchanged (per-concern files, WAL). Turn-state and webhook-dedup data remain instance-local by contract; FR13 moves their mechanism from SQLite (`state.db`, ledger) to plain filesystem stores at the end of Phase 1.
- Search-layer ownership is explicit: two `FullTextIndex` instances – memory documents (FR3) and conversation messages (FR11 rider), separate tables/corpora; KG search reads `kg_facts`; `WikiSearchSource` reads `wiki/*.md` live; tasks have no text-search producer. Knowledge Hub and `context_research` merge layer results without copying one layer into another.
- `dartclaw rebuild-index` reconstructs the stored `FullTextIndex` projections: memory from `MEMORY.md` (existing behavior) and conversation messages from session NDJSON (FR11). It does not rewrite KG facts or wiki pages. QMD retains its own `qmd update` + `qmd embed` lifecycle until Phase B replaces it. Phase B owns deterministic parity between incremental memory writes and rebuild, including an explicit decision for `MEMORY.archive.md` and daily logs.
- Type mapping is the backend's job (booleans, timestamps currently stored as ISO8601 TEXT, JSON access) – services see one Dart-typed contract.

### Rider (owner 2026-09-03) – workflow schema stories S16/S17

Two spec-ready stories deferred from 0.25 – the declarative workflow step-type rule source (S63) and the published `workflow.schema.json` plus its drift gate (S64) – ride here as **S16** and **S17**. They belong to the workflow track, not to storage, and they ride in 0.26 for three reasons. They touch nothing in the storage seam this milestone rebuilds, so they cannot collide with S01–S15. They unblock the 1,345-line `built_in_workflow_contracts_test.dart` retention debt, which has no other scheduled home. And they are the trust boundary the dynamic-workflows slice (`../0.next-workflow-track/`, slice 1) is planned against, so landing them here puts the published schema in place before that slice starts rather than inside it.

Their salvage source is the branch `parked/s64-workflow-schema` at `a1e1bd95`, which is 2,256 files divergent from `main`: cherry-pick the two commits onto a fresh branch, do not rebase. One correction carries over from the 0.25 assumptions – S38 landed narrower than S63 assumed, and `onError` / `on_error` survives as an accepted authoring key that the rule source must declare. Details in [`s16-declarative-workflow-step-type-rule-source.md`](s16-declarative-workflow-step-type-rule-source.md) and [`s17-published-workflow-json-schema-and-drift-gate.md`](s17-published-workflow-json-schema-and-drift-gate.md).

## Non-Functional Requirements

| Category | Requirement | Threshold / Target |
|----------|-------------|--------------------|
| Compatibility | Zero user-visible behavior change on the SQLite default | Full workspace suite green post-refactor; no data-dir, config, or manual storage action for the supported 0.25 → 0.26 transition |
| Performance | The async seam adds no perceptible latency on the SQLite path | No user-visible regression in chat/task/search flows; no new hot-path allocation patterns flagged in review |
| Reliability | Fail-closed on authoritative schema incompatibility, TLS violation, dual-attach, PG-unreachable-at-boot | Each refusal integration-tested with actionable error text |
| Reliability | Crash recovery independent of network DB availability | Orphan-turn recovery ordered before the backend gate; test-proven with PG unreachable |
| Security | No credential/DSN in any log, exception, audit record, or CLI output | Redaction tests across all surfaces incl. failure paths |
| Security | Cross-user search and mutation isolation on both backends | Search, upsert, and delete tenancy assertions in the shared contract suite |
| Testability | PostgreSQL path exercised and required on every PR | `@Tags(['integration'])` CI job against a PG service container; cannot silently skip; exact job registered in `release_check.sh` gate 10, operator branch-protection activation recorded |
| Maintainability | Current schemas stay aligned without a migration subsystem | Fresh bootstrap and repository round-trip contracts pass on both backends; no general migration history/generator exists |

## Edge Cases

| Scenario | Expected Behavior | Recovery Path |
|----------|-------------------|---------------|
| Second instance attaches to the same `DATABASE_URL` | Startup fails loud naming the lock conflict | Stop the other instance or use a separate database |
| Backend switched with existing non-empty old store | No data is transferred; a fresh selected backend bootstraps empty, or an existing compatible selected backend reopens its data; prominent abandoned-store notice (best-effort – FR8) | Guide's decommission/rollback guidance; switch back reopens the old data untouched |
| Authoritative `tasks.db` or PostgreSQL schema is incompatible | Startup refuses before repository use; no deletion or partial initialization | Back up/manual export if needed, then reset/recreate for the running release |
| Derived `search.db` schema is incompatible | Rebuild automatically only when complete supported sources can reconstruct it; otherwise refuse explicitly | Restore supported rebuild sources or reset/rebuild knowingly |
| Inline password in persisted `database.url` | Config validation rejects with reference-model pointer | Use env substitution or set mutually exclusive `database.credential` to an existing generic credential entry |
| Cleartext DSN to non-loopback host | Fail-closed at startup; omitted `sslmode` instead resolves to `verify-full` | Remove the explicit disablement/use verified TLS, or use loopback |
| PG connection drops before dispatch | Bounded retry | Reconnect automatically within the bound; surface failure when exhausted |
| PG connection drops after dispatch and commit outcome is ambiguous | No automatic replay; `StorageUnknownOutcomeException` | Operator reconciles state before retrying the operation |
| Runtime role is superuser | Startup warning (not enforcement) | Follow two-role guide |
| Unknown `fts_language` value | Startup validation error listing valid configs | Correct config |
| Mixed Swedish/English corpus under one language config | Works; other-language terms mis-stemmed (documented limitation) | Accepted for v1; per-document detection is a recorded future option |
| `fts_language` changed with existing memory, conversation, and KG data | Stored memory and conversation vectors stay on the old language until rebuilt; direct KG fact search uses the new language immediately after restart | Run `dartclaw rebuild-index` for memory and conversations; no KG reindex |
| Session deleted while its messages are indexed | The session's conversation-index rows are removed with the session | Full rebuild from NDJSON reconciles any missed cleanup |
| 0.25 data dir with `tasks.db` on first 0.26 start | The store is adopted automatically before open – WAL checkpointed into the main file, then one atomic rename to `dartclaw.db` (spent sidecar remnants deleted) – then FR2 adoption runs | None needed – automatic (FR12) |
| Both `dartclaw.db` and legacy `tasks.db` present | Startup refuses loudly naming both files – ambiguous store identity, no silent pick | Operator keeps the correct store and removes/archives the other per guidance |
| Phase-A memory rebuild after pruning/archival or with empty `MEMORY.md` | Rebuild reproduces today's non-empty-`MEMORY.md`-only behavior; archive/daily files are not inputs, and an absent/empty file returns early rather than clearing stale rows | Known pre-existing corpus-parity gaps; Phase B's unified chunker/rebuild owns the fix before native hybrid-search acceptance |
| PG unreachable at boot, orphaned turns present locally | Orphan recovery completes, then startup aborts on connect | Restore DB reachability; recovery is not lost |
| SQLite async transaction with interleaving caller | Serialization holds `BEGIN…COMMIT` exclusive for the awaited body | n/a – contract-tested |

## Constraints & Assumptions

### Constraints

- ADR-045's backend/security/runtime contracts, resolved topology decisions, and 2026-07-30 schema-compatibility amendment are binding owner decisions; the plan/spec must not reopen them.
- `postgres` driver pinned `^3.5.12` (bounded per DART-PACKAGE-GUIDELINES § Version Constraints). Driver gaps – no COPY protocol, no force-close API, no auto-retry on restart – place bulk-transfer, teardown, and reconnect policy in DartClaw's wrapper.
- AOT single binary: fresh bootstrap and compatibility validation require no external schema tool or runtime asset bundle.
- The abstraction scope is exactly the `tasks.db` + `search.db` surfaces. Turn-state and webhook-dedup storage stays instance-local and outside the abstraction; FR1 leaves it direct SQLite (accurate while S01–S06 execute), and FR13 then replaces the mechanism with plain filesystem stores (rider, owner 2026-08-07 – amends the *mechanism* of ADR-045 decisions #3/Q4, not their locality rationale).
- The `postgres` package compiles into every binary under AOT whole-program compilation (runtime backend selection makes it reachable). The single-binary promise holds at the "no running PostgreSQL required" level; the dependency-exclusion question is resolved (owner, 2026-07-25): compile-in accepted, no build flavor (ADR-045 Open Questions #3 – decided together with the future hybrid-search native assets). `PostgresBackend` lands in `dartclaw_core` beside `SqliteBackend` (plan decision 2026-09-02): the 12-package ceiling in `dev/tools/arch_check.dart` is saturated, so no `dartclaw_postgres` package; `dartclaw_core`'s lib LOC ceiling is raised as a recorded rebaseline in `arch_check.dart` with a CHANGELOG note, owned by S07. ADR-056's caveat carries over: `dart compile exe` cannot produce a supported self-contained artifact from a package graph rooted in core because of SQLite's native-asset build hook, and may silently emit a binary without the native-asset mapping rather than refusing; a PostgreSQL backend inside core inherits that packaging constraint and must not compound it.
- Single-threaded runtime convention holds; `pool_size` sizes await-concurrency, not parallelism.
- Core Philosophy applies: portable-subset SQL, no ORM, no speculative multi-tenancy hooks, no third search engine.

### Assumptions

- The sync→async contagion ADR-045 R2 anticipated is void at released 0.25: the repositories, the execution transactor, and their `dartclaw_runtime`/`dartclaw_workflow`/`dartclaw_cli` callers are already `Future`-returning, so S04/S05 port implementations onto the seam without a caller-signature change (recorded 2026-09-02).
- The 14-file census (2026-07-24, within `dartclaw_storage`) was an import census only; the repo-wide re-verification also sweeps typedef/helper consumers (the `dartclaw_cli` command call sites reachable only through `TaskDbFactory`/`SearchDbFactory`/`openTaskDb`/`openSearchDb` – FR1). Recounted 2026-08-14 (20 importers at released 0.24) and 2026-09-02 (18 importers plus 5 CLI typedef consumers at released 0.25 under the ADR-056 topology).
- SQLite/PostgreSQL current-schema parity is an accepted recurring cost; fresh-bootstrap and repository contract tests are the enforcement making it sustainable.
- PostgreSQL minimum supported version is pinned at spec time (informed by the language-config and advisory-lock features used; all currently-supported PG majors qualify).
- Operators adopting PostgreSQL accept the third-party data-processor exposure documented in FR10; DartClaw's role is to work correctly against a user-supplied instance, not to manage it.
- FTS language granularity, dependency packaging, and schema evolution are settled by ADR-045 plus the 2026-07-25/30 owner decisions; none remains a PRD blocker.
- The Swedish-FTS demand gate is satisfied by Snowball-stemmed matching of **regular** inflections across memory documents and temporal-KG facts; conflating irregular/ablaut forms (e.g. "sprang" ↔ "springa") is excluded from v1 acceptance by owner decision 2026-07-30.
- Orphan-turn recovery writes only to instance-local turn state (filesystem-backed under FR13), which is what makes the recovery-before-backend-gate ordering meaningful – verify against `turn_runner_cancellation`'s write-set at spec time.

### Dependencies

| Dependency | Why It Matters |
|------------|----------------|
| `postgres` (pub.dev, agilord) `^3.5.12` | The PostgreSQL driver; transaction fixes land in 3.5.12; single-maintainer-led – budget for patch upgrades |
| CI PostgreSQL service container (new `ci.yml` job) | The `@Tags(['integration'])` live path; without it FR9 cannot gate PRs. No service-container precedent exists in CI at 0.25 |
| `SqliteExecutionRepositoryTransactor` (existing) | Canonical serialization precedent the SQLite async transaction contract reuses |
| `isLoopbackHost` (`dartclaw_kernel`, existing) | The single loopback predicate for both MCP and DB TLS boundaries; FR7 adopts it and retires `HttpMcpTransport`'s private duplicate |
| TESTING-STRATEGY.md conventions | `@Tags(['integration'])` + shared contract-suite pattern FR9 builds on |

## Decisions Log

| Decision | Rationale | Alternatives Considered |
|----------|-----------|-------------------------|
| Pluggable backend: SQLite default, PostgreSQL opt-in (ADR-045) | Preserves zero-ops solo story; adds managed hosting + language FTS for those who need it | Pre-stemming on SQLite (no Swedish stemmer exists); QMD-for-everything (not a relational engine); Meilisearch/Typesense (third runtime, doesn't solve hosting); Litestream/Turso (doesn't solve FTS); PG-only (breaks single-binary story) |
| Phases 1+2 as one milestone (0.26); demand gate closed | Swedish FTS is an owner-confirmed requirement; abstraction has a committed consumer, so it isn't speculative | Phase 1 alone (abstraction without consumer violates Core Philosophy); waiting for a deployment driver (overtaken by the FTS requirement) |
| `pgvector` deferred from Phase A to scheduled Phase B | Keeps Phase A independently shippable; Phase B's validation spike and ADR-050 gates are satisfied and its in-process embedding pipeline is separately scoped | Shipping vector search inside Phase A (expands the backend/FTS checkpoint and removes its fallback release boundary) |
| Hybrid abstraction (decision #7): thin portable-subset `DatabaseBackend` + `FullTextIndex`/`VectorIndex` for divergent surfaces; prepared-statement handles; literal-aware placeholder rewriting; tenancy in the FTS contract | CRUD paths are genuinely portable (incl. the existing `ON CONFLICT` upsert); FTS/vector genuinely diverge; tenancy is the live isolation mechanism | Thin-only (relocates dialect divergence into call sites); thick per-backend repositories (doubles repository code) |
| TLS fail-closed non-loopback; omitted mode resolves to `verify-full`; shared loopback seam (decision #1, clarified 2026-07-30) | Cleartext-credential-over-network is a codified defect class in this project | Explicit cleartext with warning (rejected – silent-degrade); rejecting an omitted mode despite a safe default |
| Backend switch never migrates data; abandoned-store notice; decommission guidance (decision #2) | Deterministic, honest semantics; importer is real future work blocked on driver COPY | Implicit auto-migration (driver can't COPY; silent data movement is a trust hazard); refusing to boot (hostile to legitimate switches) |
| Webhook ledger stays instance-local (decision #3; FR13 supersedes its SQLite mechanism) | Dedup semantics are per-instance, same reasoning as `state.db` | Moving it into the PG database (couples per-instance dedup to shared state) |
| Startup advisory-lock interlock (decision #4) | Converts silent dual-writer corruption into a loud refusal; active-active stays out of scope | No guard (silent corruption incl. duplicate webhook-triggered workflow starts) |
| Full storage quarantine during interlock recovery (owner 2026-07-30) | The generic seam cannot safely classify `query()` as read-only; re-gating before resume preserves exclusive ownership without a second API | Partial read availability (requires an unsafe SQL classifier or new seam) |
| DB connection is trusted host-side egress, lifecycle-audited (decision #5) | Same category as git operations: host-initiated, not agent-reachable; guard chain governs agent egress, not the storage layer | Routing through the agent egress guard chain (wrong trust boundary; storage isn't agent-influenceable) |
| Two-role model, guidance + superuser warning, not enforced (decision #6) | Least-privilege posture without blocking v1 adoption on operators' DB admin workflows | Hard enforcement in v1 (blocks legitimate setups); silence (invites superuser runtime DSNs) |
| Outage/parity/schema contracts (decision #8): fail-closed boot, local recovery before backend/schema gate, set-membership-only parity, explicit incompatibility refusal | Makes offline recovery hold, makes the shared contract suite writable, and prevents silent schema drift | Ranking parity across backends (impossible: `bm25()` vs `ts_rank`); lazy/void boot on unreachable PG (ambiguous data state) |
| Current-schema bootstrap + compatibility gate; no migration runner (ADR-045 amendment, owner 2026-07-30) | Pre-alpha permits storage-format breaks; a full runner is disproportionate before automatic upgrades are promised | Versioned in-house runner (premature generator/history/recovery machinery); no compatibility check (silent corruption risk) |
| Pre-dispatch-only retry; ambiguous dispatched outcomes never replay (owner 2026-07-30) | Avoids duplicate mutations while retaining safe transient recovery | Generic operation replay (can duplicate a successful commit whose response was lost) |
| PostgreSQL required-check activation is an operator Phase A gate (owner 2026-07-30) | Makes the live PG suite a real merge gate without repository-settings automation | Job exists but remains optional (not a gate); settings automation (out of product scope) |
| Single PG database, one pool (Resolved Q3) | One backup target, one URL; table count doesn't justify schemas | Separate databases per concern (multiplies ops surface for nothing) |
| `state.db` stays local (Resolved Q4) | Crash recovery must not depend on network DB availability; per-instance semantics derive from file locality | `instance_id`-scoped shared table (workable but more moving parts – recorded for a future active-active effort) |
| Mutually exclusive env-substituted `database.url` or generic `database.credential` + full DSN redaction | Reuses the existing credential registry without a database-specific type/store; DSN is secret-bearing | Inline URL with masking-on-display (leaves the secret at rest); new database credential subsystem (unnecessary duplication) |
| Swedish acceptance case; one deployment-level `fts_language`, default `english` | Swedish is the driving requirement; one setting shared by memory and KG is the simplest correct v1 | Per-document/per-fact language detection (deferred until a real mixed-corpus complaint) |
| Search scope: memory documents + temporal-KG facts; tasks excluded | Memory and KG are the two knowledge layers that need morphology-aware retrieval; tasks already have structured lookup and no demonstrated text-search need | Memory only (underserves the KG); adding task indexing (no requirement or producer) |
| KG facts stay out of `FullTextIndex` | `kg_facts` is authoritative and temporal; direct query-time FTS preserves fact identity/history, avoids dual-write/rebuild failure modes, and needs no new index at current corpus scale | Copy facts into `memory_chunks` (duplicate authority, stale/duplicate citations); stored KG vector + GIN (extra write/reindex machinery before measurement) |
| Council review report not cited by path in this PRD | The report lives in `.agent_temp/` (transient tier); project rule forbids referencing `.agent_temp/` from durable docs – its substance is inlined in ADR-045 § Decided Posture & Contracts, which this PRD cites | Citing the report path (breaks the transient-artifact rule) |
| Conversation messages indexed via a second `FullTextIndex` instance (rider, owner 2026-08-07) | The original sessions/messages exclusion was inherited from the ADR-002 files-vs-index split, never a weighed search decision; the 2026-07-31 backlog audit flagged it, and 0.27's Cmd+K conversation search (cross-surface D7) is a committed consumer – landing the producer while the seam is open avoids reopening storage in 0.27 | Deferring to 0.27 (reopens storage immediately after this milestone closes it); leaving it to unscheduled Cross-Session Recall (leaves the committed D7 consumer unserved) |
| Conversation index is a separate corpus/instance; NDJSON files stay authoritative | Different write path (append-time messages), retention (session deletion), and ranking needs than the memory corpus; ADR-002 holds – the index is derived and rebuildable | One global unified index (contradicts the FR3 terminology and layer-merge architecture); indexing messages into `memory_chunks` (mixes corpora and duplicates authority) |
| Authoritative SQLite store renamed `tasks.db` → `dartclaw.db` (rider, owner 2026-08-07) | The name predates goals/executions/traces/`kg_facts` and now actively misleads; pre-release plus this milestone's transition machinery make 0.26 the last cheap rename window; aligns with the PG single-database framing | Keeping the name (confusion compounds with every new table); renaming after release (requires the data-preserving upgrade machinery DartClaw deliberately doesn't build) |
| Turn-state + webhook-dedup storage becomes filesystem-backed (rider, owner 2026-08-07 – TD-115; amends the mechanism of decisions #3/Q4, not their locality rationale) | Both stores are serve-process-only, small, transient, single-writer – SQLite's cross-process locking isn't actually needed; plain files remove the three-datastore smell and make PostgreSQL deployments touch SQLite zero times at runtime | Keeping instance-local SQLite (works, but perpetuates the Postgres+SQLite+FS triple); moving them into the shared database (couples crash recovery and per-instance dedup to network DB availability – rejected in the original decisions and still wrong) |
| FR2 compatibility baseline rebased 0.23 → exact released 0.24 (owner 2026-08-14; the ADR-045 amendment this PRD once dated 2026-08-14 was never written – S02 writes it in-milestone) | The 2026-08-07 release baseline gate fired: 0.24.0 added `role`, `provenance`, `locator`, `entry_id`, `entry_revision` to `memory_chunks` for the canonical memory corpus, so 0.23 and 0.24 are not structurally identical. `tasks.db` is unchanged, so only the search manifest moves. A 0.23 store opened by 0.24 was already upgraded in place by 0.24's additive repair and converges on the 0.24 shape | Keeping the 0.23 manifest (fresh bootstrap would create a 6-column table the shipped memory write path cannot populate, and every real 0.24 store would be refused); supporting both 0.23 and 0.24 adoption paths (doubles the fingerprint/fixture/rollback matrix for a pre-alpha with no compatibility promise) |
| Canonical memory identity travels as `FullTextIndex` metadata, not contract fields (owner 2026-08-14) | Keeps `SearchDocument`/`SearchResult` corpus-agnostic so FR11's conversation corpus and Phase B's `VectorIndex` reuse them unchanged; ADR-045's 2026-08-12 memory-preservation constraint is satisfied by a memory-side mapper that enforces the canonical-role invariant | Widening the contract with typed canonical fields (type-safe `entry_revision`, but leaks memory-specific concepts into a contract two other consumers share); dropping the fields (breaks `memory_read` selectors and live citation resolution) |
| `CanonicalIndexReconciler` moves onto the backend seam rather than being sqlite3-allowlisted (2026-08-14) | Canonical index rebuild must work on PostgreSQL under FR5/S09; allowlisting the 0.24 reconciler would leave PG deployments unable to rebuild their memory index | Adding it to the S06/S15 sqlite3 allowlist (structurally simpler, but silently makes canonical rebuild SQLite-only) |
| FR2 compatibility baseline rebased exact released 0.24 → exact released 0.25, orphan column tolerated (2026-09-02) | The release baseline gate fired again on 0.25.0: `workflow_step_executions.external_artifact_mount` was dropped with no migration, so fresh-0.25 and upgraded-from-0.24 stores differ in one nullable orphan column while every other SQLite DDL is byte-identical. The compatibility identity is one epoch plus backend-owned manifests of *required* tables, columns, and indexes, so the documented orphan is tolerated by construction. S02 writes the ADR-045 § Schema Bootstrap amendment recording both the 0.24 and the 0.25 rebase | Keeping the 0.24 manifest (refuses every store 0.25 created); fingerprinting the live table definition (rejects upgraded 0.24 stores that 0.25 accepts); supporting 0.24-plus-0.25 adoption paths (doubles the fixture/rollback matrix, the same reason the 0.23-plus-0.24 pair was rejected) |
| `PostgresBackend` lands in `dartclaw_core` beside `SqliteBackend`; `dartclaw_core` lib LOC ceiling raised as a recorded rebaseline (plan decision 2026-09-02) | `dev/tools/arch_check.dart` caps the workspace at 12 packages and all 12 are in use; ADR-056 bars the driver from `dartclaw_kernel`, `dartclaw_bridge`, and `dartclaw_client`, and `dartclaw_testing` may not take a driver. The ceiling raise is the reviewable act `arch_check.dart` frames it as, owned by S07 with a CHANGELOG note; S03/S09/S13 report their deltas to S07 | A new `dartclaw_postgres` package (breaks the saturated package ceiling and needs a tier entry); squeezing into the existing headroom (forces artificial splits); relaxing ADR-056 tiers (a topology decision this milestone does not own) |
| FR9 merge gate is `release_check.sh` gate-10 registration plus a new `ci.yml` PostgreSQL job; operator branch-protection activation stays external (2026-09-02) | GitHub `main` has no branch protection or ruleset and CI has no service container or tagged-test invocation; the only required-check registry is the named-job list in `dev/tools/release_check.sh` gate 10, which since 0.25.1 resolves the `Checks` run by exact SHA and treats a skipped job as no coverage. Registering `PostgreSQL contract` there makes the live suite a real release gate; the ruleset step is documented for the operator | Branch-protection confirmation as the sole gate (depends on a surface that does not exist); leaving the job unregistered (release check passes while the backend suite is red); repository-settings automation (out of product scope) |
| FR10 config reference is regenerated, never hand-edited (2026-09-02) | `docs/guide/configuration.md` is generated from `schemas/dartclaw.schema.json` and a drift gate fails on a hand edit (0.25); `database.*` clears the five 0.25 config gates – schema regeneration, reference regeneration, core-key list ≤ 90, declared `ConfigReloadTier.restart`, and a real consumer per leaf | Hand-editing the guide (fails the drift gate); an allowlist exemption for the section (defeats the gate's purpose) |
| Kernel `isLoopbackHost` adopted as the single MCP+DB loopback seam; `HttpMcpTransport`'s private duplicate retired; outbound-MCP TLS exemption narrows to `localhost`/`127.0.0.1`/`::1` (plan decision 2026-09-02, owner may veto) | The shared predicate FR7 asked to extract already exists in `dartclaw_kernel` (`network_guard.dart`) and is used by the server, harness wiring, and MCP router; `HttpMcpTransport` alone carries a private `InternetAddress.isLoopback` duplicate accepting all of `127.0.0.0/8`. One predicate is the ADR-045 decision #1 intent; the narrowing is recorded as a CHANGELOG line and security-doc correction | Keeping both predicates (two loopback definitions at one trust boundary); widening the kernel predicate to `127.0.0.0/8` (loosens every existing caller for the MCP transport's convenience) |
| `workflow_run_migrations` retained in the exact-0.25 manifest; dropping it deferred past 0.26 (2026-09-02) | After S05 nothing reads or writes the table, yet it is part of the released 0.25 structure S02's manifest requires; dropping it is a schema change with its own epoch, which would widen the bounded transition this milestone refuses to widen | Dropping it in S05 or S14 (a second transition step inside the same milestone); leaving it unrecorded (silent dead structure) |
| Former S14 split into S14 authoritative store rename (FR12) and S15 filesystem-backed instance-local state (FR13) (2026-09-02) | The combined story exceeded the single-session FIS size threshold; the two riders share an owner decision date but touch disjoint code (store open path vs. turn-state and webhook stores) and have different verification (rename fixtures vs. fault-injection parity) | One oversized FIS (fails the size gate); folding FR13 into S06 (mixes the census-closure refactor with a mechanism change) |
