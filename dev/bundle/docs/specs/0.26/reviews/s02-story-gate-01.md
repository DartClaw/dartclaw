# S02 initial story gate

Intent Context: /Users/tobias/Repos/Libs/dartclaw/dartclaw-public/dev/bundle/docs/specs/0.26/s02-sqlite-schema-bootstrap-and-compatibility-gate.md

All four independent code/gap/Critic passes returned. Formal Findings Filter validated five families and narrowed F04 to the actual SQLite shared namespace. Root resolved F03 publication order and F05 source-availability representation; all six are bounded in-scope corrections.

## F01

- reviewer: Merged four independent passes
- severity: HIGH
- confidence: 100
- location: sqlite_schema_gate.dart:303
- scope_relation: primary
- finding: Expression-index terms have null index_info.name, causing a cast error instead of typed incompatibility.
- threatened_assumption_or_invariant: OC03/S04 typed refusal for differently-columned indexes
- evidence: Real SQLite lower(status) index yields NULL name; map as String throws.
- impact: The required compatibility/refusal proof or behavior fails for the cited input.
- suggested_fix: Compare raw/nullable names and add real-expression-index unchanged refusal test.
- verification_needed: Execute the cited falsifier and owning focused proof; root later replays full completion.
- Class: code-defect
- Routing: Fix

## F02

- reviewer: Merged four independent passes
- severity: HIGH
- confidence: 100
- location: schema_identity_test.dart:8; sqlite_schema_gate_test.dart:70
- scope_relation: primary
- finding: One-sided descriptor tests permit omitted required columns and removed comparison dimensions.
- threatened_assumption_or_invariant: SC01/TI01/TI02 exact manifest and incompatible properties
- evidence: Isolated removal of all column type/null/default/PK comparisons leaves13tests green; required descriptor omission is not asserted bidirectionally.
- impact: The required compatibility/refusal proof or behavior fails for the cited input.
- suggested_fix: Bidirectional raw-fixture sets and negative property/index/FTS declaration tests with isolated comparator mutations.
- verification_needed: Execute the cited falsifier and owning focused proof; root later replays full completion.
- Class: code-defect
- Routing: Fix

## F03

- reviewer: Merged four independent passes
- severity: HIGH
- confidence: 100
- location: sqlite_schema_gate.dart:224-256
- scope_relation: primary
- finding: Healthy evidence publication occurs after DB commit; publication failure refuses after replacing prior contents.
- threatened_assumption_or_invariant: OC03/S07 every failed rebuild preserves previous store
- evidence: Isolated writer failing healthy yields typed refusal, current DB/replacement row only, degraded evidence.
- impact: The required compatibility/refusal proof or behavior fails for the cited input.
- suggested_fix: Root pins healthy publication inside existing transaction before commit, outer degraded catch; writer fault and retry proof.
- verification_needed: Execute the cited falsifier and owning focused proof; root later replays full completion.
- Class: code-defect
- Routing: Fix

## F04

- reviewer: Merged four independent passes
- severity: HIGH
- confidence: 100
- location: sqlite_schema_gate.dart:119-134
- scope_relation: primary
- finding: A view, index, or differently-cased table occupying SQLite shared table/view/index namespace for dartclaw_schema is mistaken for marker absence. Same-named triggers are unrelated and must remain tolerated.
- threatened_assumption_or_invariant: OC03/S04 classify malformed markers before writes
- evidence: Isolated dartclaw_schema view classifies releasedUnmarked then CREATE TABLE leaks raw SqliteException; SQLite identifier collision is case-insensitive.
- impact: The required compatibility/refusal proof or behavior fails for the cited input.
- suggested_fix: Read-only case-insensitive reserved-name detection; refuse unsupported marker type/case and preserve snapshots.
- verification_needed: Execute the cited falsifier and owning focused proof; root later replays full completion.
- Class: code-defect
- Routing: Fix

## F05

- reviewer: Merged four independent passes
- severity: HIGH
- confidence: 100
- location: sqlite_schema_gate.dart:41-65,174-177
- scope_relation: primary
- finding: API cannot represent health context with unavailable complete source, so no-source refusal leaves stale healthy evidence.
- threatened_assumption_or_invariant: OC03/S07 unavailable inputs record degraded evidence
- evidence: Health store exists only in optional SqliteSearchRebuild whose populate/authenticate are required; null path throws before any evidence access.
- impact: The required compatibility/refusal proof or behavior fails for the cited input.
- suggested_fix: Make populate/authenticate optional; missing either records unavailable-source degraded evidence before any DB write. No wholly absent context can identify an evidence file; document this precondition without inventing manifest values.
- verification_needed: Execute the cited falsifier and owning focused proof; root later replays full completion.
- Class: code-defect
- Routing: Fix – root resolves the interface with optional complete-source callbacks on the existing health/manifest context; known health context must be supplied even when source is unavailable.

## F06

- reviewer: Merged four independent passes
- severity: HIGH
- confidence: 100
- location: sqlite_schema_gate.dart:205-215; index_reconciler.dart:246-260
- scope_relation: primary
- finding: Malformed optional health JSON fields throw TypeError instead of FormatException and escape gate typed refusal.
- threatened_assumption_or_invariant: OC03/S07 unparseable evidence refuses unchanged with recovery guidance
- evidence: Isolated valid JSON with failureStage:1 throws TypeError. Optional failureStage/reason/action casts unvalidated.
- impact: The required compatibility/refusal proof or behavior fails for the cited input.
- suggested_fix: Validate optional field types at existing IndexHealthStore decoder authority; malformed shape tests via gate preserve DB/evidence bytes.
- verification_needed: Execute the cited falsifier and owning focused proof; root later replays full completion.
- Class: code-defect
- Routing: Fix

Guardrails Coverage: 16 checked, 1 merged finding

Files: CHANGELOG.md, dev/adrs/045-pluggable-database-backend.md, dev/bundle/docs/specs/0.26/execution-strategy.md, dev/bundle/docs/specs/0.26/plan.json, dev/tools/arch_check.dart, packages/dartclaw_core/lib/dartclaw_core.dart, packages/dartclaw_core/lib/src/knowledge/temporal_knowledge_graph_service.dart, packages/dartclaw_core/lib/src/storage/memory_service.dart, packages/dartclaw_core/lib/src/storage/schema_identity.dart, packages/dartclaw_core/lib/src/storage/sqlite_schema_gate.dart, packages/dartclaw_core/test/knowledge/temporal_knowledge_graph_service_test.dart, packages/dartclaw_core/test/storage/failing_database_backend.dart, packages/dartclaw_core/test/storage/schema_fixtures.dart, packages/dartclaw_core/test/storage/schema_identity_test.dart, packages/dartclaw_core/test/storage/sqlite_schema_gate_rollback_test.dart, packages/dartclaw_core/test/storage/sqlite_schema_gate_search_test.dart, packages/dartclaw_core/test/storage/sqlite_schema_gate_test.dart

Story-Gate: FAIL @ 2431111e5218+24cbd88f15cf
