# ADR-060: PostgreSQL-only database storage

## Status

Accepted – 2026-09-20, for implementation in 0.27. The owner approved PostgreSQL-only storage, native local setup,
optional pgvector and a separate temporary migration tool as one additional story before final qualification.
Implementation is pending; released 0.26.1 still supports both databases.

For 0.27, this supersedes ADR-045's SQLite-default/dual-backend policy, ADR-048's requirement to bundle SQLite,
and ADR-050's SQLite vector-storage branch. Their other contracts remain unless explicitly changed below.

## Context

The 0.26 release retained SQLite for installation without a database server and added PostgreSQL as an opt-in.
The implementation maintains two schema gates, full-text implementations and vector implementations, plus database
selection, SQL compatibility, tests and native SQLite packaging. Shared repositories reduce duplication but do not
remove backend verification or deployment differences.

The owner now prioritizes removing this ongoing cost. PostgreSQL already implements authoritative relational storage,
language-aware full-text search and optional pgvector search. Native PostgreSQL operation avoids a container prerequisite;
ordinary lexical search does not require the vector extension or embeddings.

## Decision

1. **One database engine.** PostgreSQL is the sole supported engine for DartClaw-owned authoritative relational records
   and derived database indexes. Remove runtime SQLite paths, dependencies and assets, including legacy-store probes.
   Database-dependent commands fail clearly when PostgreSQL is unavailable; there is no SQLite fallback.
2. **Native default setup.** Document and qualify native PostgreSQL on supported operating systems. The OS service
   manager owns its lifecycle. Reuse existing PostgreSQL installations where possible; local containers and remote
   databases remain optional deployment choices. Do not add a bundled server or DartClaw process supervisor.
3. **Optional vectors.** Fresh lexical-only setup needs plain PostgreSQL. Existing hybrid search remains opt-in and
   requires administrator-provisioned pgvector plus the selected embedding provider. Enabling hybrid without its
   prerequisites retains an explicit refusal; it must not silently claim semantic search is active.
4. **Existing file authorities.** Retain filesystem storage for sessions/messages, canonical memory/wiki, config,
   credentials, project metadata, logs and instance-local recovery/deduplication. This is not a move of all state into SQL.
   The database and authoritative files remain separate backup targets. External harness-owned databases are out of scope.
5. **Existing security and ownership.** Preserve connection/TLS posture, credential references/redaction, restricted
   runtime credentials, the PostgreSQL serving interlock and current-schema compatibility gate. Native database setup
   changes neither harness placement nor agent container-isolation policy.
6. **Bounded removal.** Reuse the PostgreSQL implementation and useful domain/transaction/search interfaces. Remove
   abstractions or branches that only serve engine selection when their callers can be simplified together. Do not
   introduce an ORM, generic migration framework or a permanent SQLite compatibility mode.

## Consequences

- Database schema/search changes have one engine to implement and qualify. Runtime releases stop carrying SQLite
  native assets; other native dependencies, including optional embedding support, are separate concerns.
- Database-backed operation loses the zero-server setup. Operators need a PostgreSQL service, credentials, backups
  and a major-version upgrade procedure. Platform guidance and `init`/`doctor` checks reduce, but do not erase, that cost.
- Storage integration tests need real PostgreSQL. Existing domain fakes remain useful for unit tests; SQLite cannot
  stand in for PostgreSQL behavior after removal. Reuse disposable PostgreSQL test infrastructure.
- Optional pgvector remains an installation/upgrade consideration only for operators enabling hybrid search. It adds
  an extension inside PostgreSQL, not a second database service.
- File-backed records still require separate preservation and backup. Removing SQLite is not a single-backup-target claim.

## Alternatives Considered

- **Keep both engines:** preserves zero-server installation but retains the maintenance surface being removed.
- **Change the default only:** smaller immediate edit, but does not remove either backend or its verification burden.
- **Require containerized PostgreSQL:** simplifies one provisioning recipe but adds container tooling to native setups.
- **Require pgvector everywhere:** unnecessary for built-in PostgreSQL full-text search; makes optional search a setup dependency.
- **Remove semantic search:** discards working functionality without being necessary to make vector installation optional.
- **Move every file store into SQL:** expands the change into conversation, memory and configuration persistence without
  being needed to remove SQLite. Keep this a separate product decision.

## Implementation Notes

Extend existing `init` and `doctor` flows for connection setup and readiness. They must remain usable before the
database is configured; help/version and database-independent commands must not require a database. Administrative
installation/provisioning is explicit and separate from the runtime role. Preserve the normal config loader's authority.

Provide a separate bounded offline converter from the authoritative SQLite shape in released `v0.26.1`
(`ef24b3302e936c4ff6183158da8462b866dbd7d2`) into the current 0.27 PostgreSQL schema. Compatible in-flight SQLite
stores must match that supported source shape; unknown shapes refuse. Stop writes, take a consistent SQLite backup
including committed WAL data and preserve canonical files. Import only into a freshly bootstrapped target with no
application records, preserving identities, values, ordering, stored principals and relationships. Verify counts,
normalized values and integrity before committing the import transaction; failure must leave no partial records.
Refuse populated targets and repeat imports; there is no merge/overwrite mode. Keep source data untouched and rebuild
derived indexes from canonical files. Starting fresh is explicit; configuring a URL transfers no data.

The converter uses Python 3's standard-library SQLite support and the PostgreSQL `psql` client, outside production
dependencies. Its target uses inherited libpq environment/service/passfile settings for the database and runtime role
bootstrapped by doctor, preserving the existing TLS/loopback posture; it does not resolve DartClaw named credentials.
It consumes the existing PostgreSQL schema bootstrap authority instead of owning another copy of its
DDL. Package the tool and a bounded source fixture with the transition release. Treat stored text only as data, never
SQL or shell instructions. Keep passwords and record contents out of diagnostics and process arguments. Retain backups
and document rollback before accepting new PostgreSQL writes;
do not promise lossless rollback after new writes or introduce ongoing synchronization.

Remove SQLite-specific configuration/defaults, wiring, schema/search/vector implementations, dependencies, build hooks
and release assets together. Include standalone workflow and maintenance entry points, examples, test fixtures,
generated configuration schema and the existing SQLite-specific lexical-search name in the scope inventory.

Acceptance must demonstrate fresh native setup without a container engine or pgvector, ordinary lexical search,
optional hybrid behavior with pgvector, database failure diagnostics, serve/standalone/rebuild paths and restoration
of both database and file-backed state. Verify runtime dependency and release-asset absence of SQLite. Do not claim
unexecuted tests/platform checks or use SQLite to obtain a green storage test result.

The existing PostgreSQL 14+ support floor remains. Qualify concrete native macOS/Linux/Windows installation and
service recipes as implementation proofs, with optional pgvector setup separate. The 0.27 storage story consumes
the integrated workspace/search/temporary-retention behavior and precedes final integrated qualification. Rerun
affected storage, Q/W, platform and release gates against the PostgreSQL-only candidate; prior dual-engine evidence
is historical. Subsequent schema changes must use the released PostgreSQL-only baseline.

## Project Compliance

Applies PRODUCT's one-maintainer/prototype scope and smallest-sufficient-change rule by removing one production engine.
Preserves ADR-054's single authorities for configuration, schema validation and execution policy. Retains ADR-002's
file-backed authorities and ADR-055's independent container-isolation policy.

## References

- [ADR-045: dual database support](045-pluggable-database-backend.md)
- [ADR-048: SQLite release packaging](048-release-builds-dart-build-bundled-sqlite.md)
- [ADR-050: native hybrid search](050-native-hybrid-search.md)
- [ADR-002: file-based storage](002-file-based-storage.md)
- [ADR-054: one authority per concern](054-model-first-delegation-and-one-authority-per-concern.md)
- [ADR-055: container isolation posture](055-container-by-default-posture.md)
- [ADR-059: doctor preserves config refusals](059-doctor-preserves-config-load-refusals.md)
- [Product scope](../state/PRODUCT.md)
- [PostgreSQL operations and storage inventory](../../docs/guide/postgresql.md)
- [Current backend selection](../../packages/dartclaw_core/lib/src/storage/database_backend_selection.dart)
- [Runtime wiring](../../packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart)
- [Existing PostgreSQL test provisioning](../tools/postgres_contract.sh)
