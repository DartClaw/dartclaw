Intent Context: dev/bundle/docs/specs/0.26/s11-dual-backend-contract-suite-and-ci-integration.md

Fix

1. Manifest omission can remain invisible to both entries and the exact-set checker
   - reviewer: reviewer-s11-gate
   - severity: HIGH
   - confidence: 100
   - location: packages/dartclaw_core/test/storage/contract/database_backend_contract.dart:77-133; representative declaration guard at lines 167-169
   - scope_relation: primary
   - finding: The manifest is validated against the separate hard-coded `declaredContractGroups` set, while each real contract group is declared only when its id is already present in `enabledGroups`. Adding the normal `if (enabled.contains('new.id')) { group('[contract:new.id] ...') }` shape without also changing the manifest and duplicate constant makes the group disappear from both test entries and their JSON reports, so the checker still sees the old exact expected set and passes.
   - threatened_assumption_or_invariant: FIS SC01/TI07 requires adding a contract group without its manifest classification to fail CI by construction.
   - evidence: `enabledGroups` is derived from the manifest at lines 120-133 and passed to every concern; all 20 declarations are guarded before `group(...)`; `validate()` sees only the manually maintained constant, never the actual declaration tokens. The current manifest and constant agree, but the omission path the mechanism exists to reject is not coupled to either.
   - impact: A new backend contract can be authored yet never execute on SQLite or PostgreSQL, while both exact-set checks remain green. Backend drift can therefore masquerade as covered.
   - suggested_fix: Bind registration to each actual declaration through one helper that records or validates the declaration id before deciding whether that backend enables it, or add a source-token check that compares every contract declaration to the manifest without relying on `declaredContractGroups`. Add an omission falsifier that inserts a guarded group token without a manifest entry and asserts failure.
   - verification_needed: In an isolated copy, add one normal guarded `[contract:new.id]` group without changing the manifest or any registry and prove the SQLite/default path or registered checker test fails.
   - Class: code-defect
   - Routing: Fix – primary, deterministic proof wiring defect that contradicts SC01 and OC02.

2. The schema groups do not prove the exact fresh schema or a write-free compatible reopen
   - reviewer: reviewer-s11-gate
   - severity: HIGH
   - confidence: 100
   - location: packages/dartclaw_core/test/storage/contract/schema_contract.dart:7-29; packages/dartclaw_core/test/storage/contract/postgres_backend_contract_test.dart:96-115
   - scope_relation: primary
   - finding: `schema.fresh_bootstrap` asserts only that an empty snapshot changes and the second prepare is idempotent. It never asserts the required object set or marker row `(1, 1)`. `schema.compatible_reopen` starts from the entry's empty prepared store and compares snapshots without seeding a durable row; the PostgreSQL snapshot contains only catalog metadata and the marker, so application-row writes or deletion cannot be observed.
   - threatened_assumption_or_invariant: FIS S03/OC01 requires one authored cross-backend contract to prove every required object plus marker `(1, 1)` and that a current store reopens with no write.
   - evidence: Lines 11-17 compare `empty`, `prepared`, and the second snapshot only by equality/inequality. Lines 25-29 compare a current but data-empty store. The PostgreSQL adapter serializes catalog rows and `dartclaw_schema` only; no independent required-object expectation or application sentinel is checked.
   - impact: Removing a required object from the production bootstrap definition, creating the wrong marker identity, or mutating current application data can leave the contract green on one or both backends.
   - suggested_fix: Give the adapter an independent assertion for the pinned released required-object manifest and exact marker row, invoke it after fresh preparation, and seed at least one application row before compatible reopen so the before/after proof covers durable data as well as catalog shape.
   - verification_needed: Mutate an isolated bootstrap to omit one required object and to write/delete a seeded current row; each mutation must fail its owning shared schema group on both entries.
   - Class: code-defect
   - Routing: Fix – primary, bounded contract-strength correction required by S03.

3. The workflow-run family is only partially round-tripped
   - reviewer: reviewer-s11-gate
   - severity: HIGH
   - confidence: 100
   - location: packages/dartclaw_core/test/storage/contract/repository_contract.dart:102-121
   - scope_relation: primary
   - finding: The workflow-run fixture supplies non-default `definitionName` and `definitionJson`, but the assertions check only `id`, `contextJson`, `variablesJson`, and `startedAt`. `updatedAt` and the remaining persisted fields are either not checked or left at defaults.
   - threatened_assumption_or_invariant: FIS S05/TI05 requires every returned domain value for every seam-backed repository family to equal the written value on PostgreSQL.
   - evidence: `WorkflowRun` has persisted status, updated/completed times, error, token count, step index, definition snapshot, execution cursor, and worktree bindings in addition to the four asserted fields; the repository serializes these individually. The contract would still pass if `definition_name`, `updated_at`, or `definition_json` hydration were broken.
   - impact: A PostgreSQL-specific mapping defect in one of the required repository families can ship while its named contract group reports success.
   - suggested_fix: Populate every persisted `WorkflowRun` field with a distinguishable non-default value and compare the loaded `toJson()` with the written `toJson()`.
   - verification_needed: Break one currently unchecked field mapping in an isolated copy and prove `[contract:repository.workflow_run]` fails.
   - Class: code-defect
   - Routing: Fix – primary, mechanical assertion completion directly required by S05.

4. The shared transaction test cannot detect dirty visibility of the in-flight row
   - reviewer: reviewer-s11-gate
   - severity: HIGH
   - confidence: 100
   - location: packages/dartclaw_core/test/storage/contract/database_backend_contract.dart:280-297
   - scope_relation: primary
   - finding: The transaction writes `uncommitted`, issues an outside insert of the unrelated value `outside`, releases the transaction, and checks only the final state after rollback. The outside operation performs no read and encounters no constraint involving the in-flight row, so it cannot reveal whether that row was visible outside the transaction.
   - threatened_assumption_or_invariant: FIS S02 requires the outside write issued mid-body to persist and never observe uncommitted rows on either backend.
   - evidence: `contract_records.value` has no unique constraint; the outside statement inserts a distinct value; the only query occurs after rollback. A backend exposing the in-flight row would produce the same final single `outside` row and pass.
   - impact: The central cross-backend transaction isolation assertion can green for an implementation that leaks uncommitted state.
   - suggested_fix: Make the outside operation observably depend on the in-flight value, such as a uniqueness-conflicting write that must wait for rollback and then succeed, while retaining the `Completer` handshake and SQLite-only completion-order assertion.
   - verification_needed: Introduce dirty visibility or premature commit in an isolated backend implementation and prove `[contract:backend.transaction]` fails.
   - Class: code-defect
   - Routing: Fix – primary, deterministic missing assertion for S02 transaction semantics.

5. The report checker accepts a semantically incomplete JSON report
   - reviewer: reviewer-s11-gate
   - severity: MEDIUM
   - confidence: 100
   - location: dev/tools/contract_groups_check.dart:34-80; dev/tools/contract_groups_check_test.sh:13-22
   - scope_relation: primary
   - finding: The checker does not require the reporter's terminal `done` event and does not reject unmatched `testStart` events. Once one visible test has completed successfully for a group, a later dangling start for the same group has no effect on that group's passing state.
   - threatened_assumption_or_invariant: FIS S07/TI07 requires missing or malformed reports to fail closed rather than be accepted as complete proof.
   - evidence: An isolated report containing a successful start/done pair for `[contract:a]` followed by a second unmatched `[contract:a]` start exited 0 with `Contract groups passed: a`. The checked-in success fixture itself has no terminal `done` event. The runner's `set -e` mitigates normal command failures, but the proof tool still accepts incomplete report bytes.
   - impact: A truncated, hand-produced, or otherwise incomplete report can be accepted as exact contract evidence when every expected id appeared before truncation.
   - suggested_fix: Require exactly one terminal `done` event with `success: true`, reject events after it, and reject every visible or contract-bearing start without exactly one matching done event. Add truncated-report and unsuccessful-terminal fixtures.
   - verification_needed: Extend `contract_groups_check_test.sh` with dangling-start, absent-terminal, and `done.success: false` cases and prove all exit non-zero.
   - Class: code-defect
   - Routing: Fix – primary, bounded fail-closed parser correction; normal runner exit propagation keeps severity below HIGH.

Applied inline severity calibration (Findings Filter skipped: no Critical findings and <=5 total).

Guardrails Coverage: 12 checked, 0 findings
Files: .github/workflows/ci.yml, dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md, dev/guidelines/RELEASE_PREPARATION.md, dev/guidelines/TESTING-STRATEGY.md, dev/tools/release_check.sh, dev/tools/release_check_test.sh, dev/tools/test_workspace.sh, packages/dartclaw_core/pubspec.yaml, dev/tools/contract_groups_check.dart, dev/tools/contract_groups_check_test.sh, dev/tools/postgres_contract.sh, packages/dartclaw_core/test/storage/contract/contract_groups.json, packages/dartclaw_core/test/storage/contract/fts_divergence_whitelist.json, packages/dartclaw_core/test/storage/contract/database_backend_contract.dart, packages/dartclaw_core/test/storage/contract/schema_contract.dart, packages/dartclaw_core/test/storage/contract/fts_contract.dart, packages/dartclaw_core/test/storage/contract/repository_contract.dart, packages/dartclaw_core/test/storage/contract/sqlite_backend_contract_test.dart, packages/dartclaw_core/test/storage/contract/postgres_backend_contract_test.dart
Story-Gate: FAIL @ e53e48cabb42+2fe025db1c57
