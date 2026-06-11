# ADR-002: File-Based Storage with Lightweight Search Index

**Status:** Accepted — fully implemented. File-based storage (NDJSON + JSON) is the production storage layer. Drift ORM fully removed.
**Date:** 2026-02-23 (accepted: 2026-02-27)
**Deciders:** DartClaw team

## Context

DartClaw's data layer uses Drift ORM (SQLite) for all persistent storage: sessions, messages, memory chunks (FTS5), and key-value state. After implementing S01–S11, the Drift dependency has proven to be the project's heaviest:

- **Codegen overhead**: `build_runner` + `drift_dev` required; generates 2,800-line `database.g.dart`. Schema changes require a codegen step before code compiles.
- **Version pin constraint**: Drift 2.31 pins `sqlite3` to v2, blocking the v3 native build hooks that would eliminate the system `libsqlite3` requirement for AOT distribution.
- **Architectural mismatch**: Sessions and messages are append-only, single-session-access data. They don't benefit from relational queries, joins, or ORM features. The access patterns are simple: create, append, list, delete directory.
- **Dual-storage friction**: Memory data lives in both `MEMORY.md` (human-readable) and `memory_chunks` (FTS5 index). The database is a derived index, but there's no rebuild path if the DB is lost while the file survives.

### What Actually Needs SQLite

The only feature that genuinely requires SQLite is **full-text search** (FTS5 with BM25 ranking) and the planned **vector search** (sqlite-vec). These are search indexes over data whose source of truth is `MEMORY.md` — they should be rebuildable, not authoritative.

Sessions and messages are simple structured data with append-only access patterns. Files handle this naturally: one directory per session, NDJSON for messages, JSON for metadata.

## Decision Drivers

- **Dependency minimalism** — eliminate codegen step, reduce build complexity
- **Source-of-truth clarity** — files are the source, search index is derived and rebuildable
- **AOT unblocking** — removing Drift removes the `sqlite3` v2 pin constraint
- **Developer experience** — no `build_runner` step, human-readable data on disk
- **Future vector search** — sqlite-vec integration is simpler with raw SQL than through Drift's codegen

## Decision

Replace Drift ORM with:

1. **File-based storage** for sessions, messages, and key-value state (NDJSON + JSON files)
2. **Raw `sqlite3` package** (no ORM) for the search index only (FTS5 + sqlite-vec stub)
3. **Remove** `drift`, `drift_dev`, and `build_runner` dependencies entirely

### Storage Layout

```
~/.dartclaw/
  sessions/
    <uuid>/
      meta.json           Session metadata (id, title, timestamps)
      messages.ndjson      One JSON object per line; line number = cursor
  kv.json                 Global key-value settings
  search.db               SQLite search index (FTS5 + vector), rebuildable
  MEMORY.md               (unchanged — source of truth for memory)
  memory/                 (unchanged — daily logs)
```

### Key Design Choices

**Cursor = line number**: Messages in NDJSON files have a natural cursor — the 1-based line number. This is monotonically increasing, survives crashes (partial last line is detectable and truncatable), and requires no autoincrement mechanism.

**Cascade delete = delete directory**: Deleting a session is `Directory.deleteSync(recursive: true)`. All messages go with it. No foreign key constraints needed.

**Search index is rebuildable**: `search.db` can be deleted and rebuilt from `MEMORY.md` at any time. The index is derived, not authoritative.

**sqlite-vec stub**: The vector search table schema is created alongside FTS5 (if the extension is available), with stub methods returning empty results. This prepares for Phase 4 hybrid search without adding runtime dependencies now.

**Atomic writes**: NDJSON append is naturally crash-safe (partial last line detectable). JSON metadata files use temp-file + rename (atomic on POSIX).

## Consequences

### Positive

- **No codegen step** — `build_runner` eliminated from development workflow
- **2,800 fewer generated lines** — `database.g.dart` deleted
- **Human-readable data** — sessions and messages are inspectable JSON files on disk
- **Rebuildable search index** — `search.db` loss is recoverable from `MEMORY.md`
- **Unblocks sqlite3 v3** — Drift's version pin removed; can adopt native build hooks when ready
- **Simpler dependency tree** — 3 fewer dev dependencies (drift, drift_dev, build_runner)
- **Service APIs unchanged** — all consumers use the same method signatures; only constructors change

### Negative

- **No relational queries** — cross-session queries (e.g., "find all sessions mentioning X") would require reading all files. Not needed today, but harder to add later.
- **O(n) session listing** — reading N `meta.json` files to list sessions. Acceptable for MVP scale (<1000 sessions, <10ms). May need an index file if session count grows significantly.
- **O(n) message reads** — `getMessagesAfterCursor` reads the full file and skips lines. Acceptable for MVP scale (<10K messages per session). Seek-based optimization possible later.
- **No SQLite WAL/locking** for session data — concurrent writes to the same NDJSON file could corrupt. Mitigated by single-process model and write serialization (existing pattern from `MemoryFileService`).
- **Test setup changes** — all tests that construct services need updated setUp/tearDown (temp directories instead of in-memory DB). Test logic and assertions unchanged.

### Neutral

- Raw `sqlite3` for search index is ~50-100 lines of SQL. No ORM complexity, but also no type safety on query results.
- `sqlite3` package remains as a dependency, but only for the search index.

## Alternatives Considered

### Keep Drift, fix the friction

Could update Drift, wait for sqlite3 v3 support, accept the codegen step. Rejected because the fundamental mismatch remains: Drift is an ORM for relational data, but sessions/messages are append-only logs.

### SQLite for everything, drop Drift only

Use raw `sqlite3` for all tables (sessions, messages, memory, kv) without Drift's codegen. Eliminates the codegen friction but keeps SQLite as primary storage for data that doesn't need it. Files are simpler and more inspectable.

### Embedded key-value store (Hive, Isar)

Alternative to both SQLite and files. Rejected: adds a new dependency for a problem that files solve naturally, and doesn't provide FTS5.
