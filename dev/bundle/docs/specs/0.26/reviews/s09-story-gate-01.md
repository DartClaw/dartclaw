Intent Context: /Users/tobias/Repos/Libs/dartclaw/dartclaw-public/dev/bundle/docs/specs/0.26/s09-language-aware-postgresql-memory-and-kg-search.md

Verdict: FAIL. The PostgreSQL implementation is coherently wired and the inspected SQL preserves tenant scope, bound language parameters, transactional rebuild rollback, and direct KG authority. Three bounded proof/documentation defects remain.

Coverage: Checked S01–S08 and SC01–SC06 against the 32-path frozen change set and the immediate `FullTextIndex`, `DatabaseBackend`, schema-identity, runtime composition, Knowledge Hub, and reconciler callers. Falsifiers covered cross-tenant reads and mutations, malformed natural-language queries, language validation before construction, language changes, missing vector/index objects, failed rebuild transitions, post-commit projection, degraded startup, SQLite publication parity, backend cleanup, generated config artifacts, exports, file caps, and stale backend-specific claims. Reused reported focused evidence: config/governance 53/11, exception 3, KG 26, reconciler 17, runtime 17, CLI 11, analyzer 0 diagnostics, architecture 16/16, and integration tags 5/5. Actual PostgreSQL execution and the broad/platform suites remain deferred to the owner-directed combined final gate and are not claimed here.

## Fix

### Runtime live proof duplicates and bypasses the required PostgreSQL fixture seam

- reviewer: reviewer-s09-gate
- severity: MEDIUM
- confidence: 100
- location: `packages/dartclaw_runtime/test/runtime/storage_wiring_postgres_search_live_test.dart:289`
- scope_relation: primary
- finding: The new runtime suite reads `DARTCLAW_TEST_POSTGRES_URL`, rewrites the DSN, creates/drops a namespace, and tracks backend cleanup in its own `_withPostgresNamespace`/`_PostgresNamespace` implementation instead of using S07's `postgres_live_support.dart` helper.
- threatened_assumption_or_invariant: SC06 requires every new live suite to read the PostgreSQL URL through the shared helper, and the project rule requires reuse before adding a second boundary implementation.
- evidence: The runtime file directly reads the environment at lines 290–295 and implements namespace lifecycle at lines 296–328; the existing helper owns the same URL normalization and namespace lifecycle at `packages/dartclaw_core/test/storage/postgres_live_support.dart:8–36`. The other new live suites import that helper.
- impact: Changes to the canonical live-test connection or cleanup posture will not reach this suite, so it can drift or leak schemas while the shared helper remains correct; the frozen change set does not satisfy SC06.
- suggested_fix: Drive these three tests through `withPostgresBackend`, reusing its supplied backend and namespace; remove the duplicate DSN/schema helper and direct environment read, or extend the shared helper once if a second concurrent connection is truly required.
- verification_needed: Analyze the runtime live test, confirm its only PostgreSQL URL access comes through the shared helper, then run that tagged suite in the deferred PostgreSQL campaign.
- Class: code-defect
- Routing: Fix – SC06 names the required seam and the correction is bounded to test infrastructure.

### The S01 live test does not prove `listRecent` tenant isolation

- reviewer: reviewer-s09-gate
- severity: MEDIUM
- confidence: 100
- location: `packages/dartclaw_core/test/search/postgres_fts_index_live_test.dart:52`
- scope_relation: primary
- finding: The shared-id fixture puts a row for `other` in the table, but the `listRecent(userId: 'owner')` assertion checks only the first chunk and zero scores. Removing the production `user_id = ?` predicate would still satisfy those assertions because the newest owner chunk remains first.
- threatened_assumption_or_invariant: S01 requires every read, including `listRecent`, to return only the requested tenant, and proof falsifiers must fail when the protected filter is removed.
- evidence: Lines 45 and 52–54 seed the foreign row and inspect only `recent.first`/scores; there is no exact result-set or foreign-content assertion for `listRecent`. The production filter is at `packages/dartclaw_core/lib/src/search/postgres_fts_index.dart:189`.
- impact: A tenant-isolation regression in the recency path can pass the story's owning live suite and expose another user's memory chunks.
- suggested_fix: Assert the exact ordered owner chunk list (or exact length plus every expected chunk) and explicitly prove `other secret` is absent, while retaining the same-timestamp stored-row ordering assertion.
- verification_needed: Run the focused tagged FTS suite in the deferred PostgreSQL campaign; in an isolated copy, removing the `listRecent` user predicate must make this test fail.
- Class: code-defect
- Routing: Fix – the missing assertion is uniquely determined by S01 and changes no production behavior.

### Backend-neutral publication left SQLite-only contract text in changed canonical surfaces

- reviewer: reviewer-s09-gate
- severity: MEDIUM
- confidence: 100
- location: `packages/dartclaw_core/lib/src/storage/index_reconciler.dart:291`, `dev/architecture/data-model.md:85`, `dev/architecture/data-model.md:858`, `dev/architecture/data-model.md:886`
- scope_relation: primary
- finding: The exported reconciler still describes itself as rebuilding an FTS5 index for one `search.db` target, while the architecture access-pattern, maintenance, and recovery inventories still describe the derived index only as SQLite `search.db` even though this change marks the document current through the PostgreSQL memory-index implementation.
- threatened_assumption_or_invariant: TI06/TI09 and the anti-rot rule require the public contract and canonical data-model document to describe both publication targets accurately.
- evidence: `CanonicalIndexReconciler` now accepts an `IndexRebuildTarget` and is used with `TransactionalRebuildTarget`, but lines 291–310 retain FTS5/`search.db` wording. The data-model prose at lines 364–376 documents PostgreSQL correctly, while the three cited inventory rows still state only SQLite files, SQLite prepared statements, and `search.db` rebuild/recovery.
- impact: API consumers and maintainers receive contradictory lifecycle guidance and can incorrectly infer that reconciliation, maintenance, and recovery are SQLite-only.
- suggested_fix: Make the reconciler dartdoc target-neutral and update the three canonical inventory rows to cover SQLite `search.db` and the PostgreSQL `memory_chunks.content_tsv` projection with their actual access, rebuild, and recovery mechanics.
- verification_needed: Re-read the complete changed data-model document for remaining SQLite-only restatements of the derived memory index and run the focused documentation scans from TI09.
- Class: code-defect
- Routing: Fix – the implementation and FIS already settle the wording, so reconciliation is mechanical.

Applied inline severity calibration (Findings Filter skipped: no Critical findings and <=5 total).

Guardrails Coverage: 17 checked, 3 findings
Files: apps/dartclaw_cli/lib/src/commands/rebuild_index_command.dart, apps/dartclaw_cli/test/commands/rebuild_index_command_postgres_live_test.dart, apps/dartclaw_cli/test/commands/rebuild_index_command_test.dart, dev/architecture/data-model.md, docs/guide/cli-reference.md, docs/guide/configuration.md, packages/dartclaw_core/lib/dartclaw_core.dart, packages/dartclaw_core/lib/src/knowledge/knowledge_fact_search.dart, packages/dartclaw_core/lib/src/knowledge/temporal_knowledge_graph_service.dart, packages/dartclaw_core/lib/src/search/postgres_fts_index.dart, packages/dartclaw_core/lib/src/storage/index_rebuild_target.dart, packages/dartclaw_core/lib/src/storage/index_reconciler.dart, packages/dartclaw_core/lib/src/storage/postgres_schema_gate.dart, packages/dartclaw_core/test/knowledge/postgres_fact_search_live_test.dart, packages/dartclaw_core/test/knowledge/temporal_knowledge_graph_service_test.dart, packages/dartclaw_core/test/search/postgres_fts_index_live_test.dart, packages/dartclaw_core/test/storage/index_reconciler_postgres_live_test.dart, packages/dartclaw_core/test/storage/index_reconciler_test.dart, packages/dartclaw_core/test/storage/postgres_schema_gate_live_test.dart, packages/dartclaw_kernel/lib/dartclaw_kernel.dart, packages/dartclaw_kernel/lib/src/config_meta/database_fields.dart, packages/dartclaw_kernel/lib/src/config_parser_providers.dart, packages/dartclaw_kernel/lib/src/database_config.dart, packages/dartclaw_kernel/lib/src/storage_exceptions.dart, packages/dartclaw_kernel/test/database_config_test.dart, packages/dartclaw_kernel/test/storage_exceptions_test.dart, packages/dartclaw_runtime/lib/src/config/config_serializer.dart, packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart, packages/dartclaw_runtime/test/config/config_serializer_test.dart, packages/dartclaw_runtime/test/runtime/storage_wiring_postgres_search_live_test.dart, packages/dartclaw_runtime/test/runtime/storage_wiring_search_gate_test.dart, schemas/dartclaw.schema.json
Story-Gate: FAIL @ 1254d5e7aad0+17af82b152be
