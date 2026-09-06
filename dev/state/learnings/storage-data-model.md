# Storage / Data Model

- **Durable knowledge graph facts belong in `tasks.db`, not `search.db`.** `search.db` is rebuildable from MEMORY.md and can be deleted/rebuilt; temporal KG facts are authoritative source-linked records and must use the durable task database connection.
- **Task sessions have multi-layer protection from maintenance pruning.** `_isProtected()`, `_pruneStale()` skip, `protectedTypes` set, `deleteSession()` throws, `listSessions()` excludes by default.
- **FTS5 MATCH has special operators.** Wrap user input in double quotes for literal matching.
- **Task persistence is schema-backed, not generic-JSON-backed.** New `Task` fields require schema, migrations, insert/update, hydration — not just `toJson()`/`fromJson()`.
- **Legacy task-table migrations must guard missing columns at every SQL touch point.** Branching only the backfill INSERT is insufficient; index creation and `INSERT ... SELECT` also need conditional column references.
- **Validate untrusted-ingestion payloads before the first durable write, and never treat LLM text as a control boundary.** Order all checks before any sink (else retries re-run committed writes); parse structured output from a delimiter-safe channel, not free text that source-embedded fences can forge.
- **Parse-then-rewrite makes a lenient parser destructive.** The parse result is written back, so unknown shapes are deleted, not ignored; unparseable must refuse. `_readPage`: CRLF, flow YAML.
- **A write that becomes read-modify-write needs `secureWriteFile`.** The file is the sole copy; truncating `writeAsString` turns any interruption into total loss. `storage/atomic_write.dart:13`.
- **A reachability category must count inbound links, not the page's own.** Wiki `orphan` read each page's outbound links, so a leaf-only corpus flagged every page every run – no signal.
- **A markdown link regex must split `#fragment`/`?query` off the path.** `](page.md#section)` matched `\]\(([^)]+\.md)\)` not at all: target never link-checked, page counted linkless.
- **Fingerprint the corpus replacement at the current revision, bump only on commit.** `MEMORY.md` carries its revision in its bytes, so a post-bump identity guard never fires.
