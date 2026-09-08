Intent Context: /Users/tobias/Repos/Libs/dartclaw/dartclaw-public/dev/bundle/docs/specs/0.26/s14-authoritative-store-rename.md

## Fix

None.

## Note

### WAL-backed rename refusal leaves the legacy store mutated

- reviewer: reviewer_s14_gate
- severity: HIGH
- confidence: 100
- location: `packages/dartclaw_core/lib/src/storage/authoritative_store_adoption.dart:96-137`; `packages/dartclaw_core/test/storage/authoritative_store_adoption_test.dart:141-163`
- scope_relation: primary
- finding: Adoption checkpoints and closes a WAL-backed legacy store before attempting the rename. If that rename is then refused, the method throws but the legacy main file and sidecars have already changed. The rename-refusal test uses a clean-shutdown store without sidecars, so it cannot detect this failure-atomicity breach.
- threatened_assumption_or_invariant: FIS OC03 and scenario S05 require a failed rename to leave `tasks.db` and its sidecars byte-identical, with nothing partially adopted (`s14-authoritative-store-rename.md:16,65-68`).
- evidence: An isolated production-code falsifier created a committed row resident in `tasks.db-wal`, removed directory write permission, and called `adoptLegacyAuthoritativeStore`. The expected `AuthoritativeStoreAdoptionException` occurred, but `tasks.db` grew from 4096 to 12288 bytes and `tasks.db-wal` shrank from 20632 to 0 bytes (`unchanged=false`). The focused four-suite run still passed 49 tests, demonstrating the current proof misses the WAL-plus-rename-failure combination.
- impact: A failed migration reports that adoption aborted while durably changing the operator's legacy store layout. Data remained readable in the falsifier, but the explicit recovery-state guarantee is false and tooling or manual recovery cannot rely on the promised unchanged bytes and sidecars.
- suggested_fix: Decide and implement one failure contract across checkpoint and rename: either preserve and restore the exact pre-checkpoint files when rename fails, with a WAL-backed refusal regression, or explicitly revise OC03/S05 to permit a content-preserving checkpoint before rename refusal. The current intent requires preservation.
- verification_needed: Add a real-SQLite test combining a WAL-resident committed row and forced POSIX rename refusal; assert the selected recovery contract, including main/WAL/SHM bytes, directory entries, no `dartclaw.db`, and row readability after recovery.
- Class: code-defect
- Routing: Note – the defect is primary and proven, but choosing rollback mechanics versus revising the checkpoint-first failure contract requires owner judgment and is not a uniquely determined mechanical fix.

Guardrails Coverage: 12 checked, 0 findings
Files: CHANGELOG.md, apps/dartclaw_cli/lib/src/commands/cleanup_command.dart, apps/dartclaw_cli/lib/src/commands/workflow/workflow_status_command.dart, apps/dartclaw_cli/test/commands/cleanup_command_test.dart, apps/dartclaw_cli/test/commands/init/init_command_test.dart, apps/dartclaw_cli/test/commands/workflow/workflow_lifecycle_standalone_test.dart, apps/dartclaw_cli/test/commands/workflow/workflow_status_command_test.dart, dev/architecture/configuration-architecture.md, dev/architecture/data-model.md, dev/architecture/observability-operations-architecture.md, dev/architecture/system-architecture.md, dev/architecture/task-execution-architecture.md, dev/state/LEARNINGS.md, dev/state/STACK.md, dev/state/UBIQUITOUS_LANGUAGE.md, dev/testing/.gitignore, dev/testing/profiles/visual/data/dartclaw.db, dev/testing/profiles/visual/data/tasks.db, docs/guide/architecture.md, docs/guide/configuration.md, docs/guide/getting-started.md, docs/guide/workspace.md, packages/dartclaw_core/CLAUDE.md, packages/dartclaw_core/lib/dartclaw_core.dart, packages/dartclaw_core/lib/src/storage/authoritative_store_adoption.dart, packages/dartclaw_core/lib/src/storage/sqlite_backend.dart, packages/dartclaw_core/test/storage/authoritative_store_adoption_test.dart, packages/dartclaw_kernel/lib/src/dartclaw_config.dart, packages/dartclaw_kernel/test/dartclaw_config_test.dart, packages/dartclaw_runtime/lib/src/runtime/storage_wiring.dart, packages/dartclaw_runtime/test/runtime/storage_wiring_tasks_gate_test.dart, packages/dartclaw_testing/lib/src/prepared_task_backend.dart
Story-Gate: FAIL @ 589da3a9d214+8e8e64f258c3
