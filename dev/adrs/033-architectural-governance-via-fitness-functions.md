# ADR-033: Architectural Governance via Fitness Functions in CI

## Status

Accepted — 2026-05-31 (implemented in 0.16.5; recorded retroactively during an ADR-gap review of 0.16.4–0.16.6)

**Related:** [ADR-034](034-enforced-package-dependency-direction.md) (the dependency-direction rule is one of the checks this mechanism enforces), [ADR-010](010-package-split-models.md) and [ADR-020](020-package-decomposition-phase-2.md) (the package structure these checks defend).

## Context

The Dart pub workspace had grown to ~12 packages. Architectural drift — package cycles, ballooning barrel exports, oversized files, cross-package code duplication, unguarded `Process` usage, and dependency-direction violations — was caught only by manual review, inconsistently and after the fact. 0.16.4 had already introduced numeric ceilings in `dev/tools/arch_check.dart` (LOC, barrel-export counts) as a stopgap; 0.16.5 needed a durable, first-class governance mechanism. The constraint: the codebase carried pre-existing violations, so a hard "zero violations or fail" gate would force a big-bang refactor before any new work could land.

## Decision

Encode architectural invariants as **executable fitness functions** — plain Dart tests under `packages/dartclaw_testing/test/fitness/` — run as CI gates, governed by a **frozen-baseline ratchet**:

- **Two levels of checks.** The suite (14 files) covers barrel `show`-clause hygiene and export ceilings (`barrel_show_clauses_test.dart`, `barrel_export_count_test.dart`), file and method size (`max_file_loc_test.dart`, `max_method_count_per_file_test.dart`), package cycles (`package_cycles_test.dart`), constructor parameter counts (`constructor_param_count_test.dart`), cross-package env-plan duplication (`no_cross_package_env_plan_duplicates_test.dart`), safe `Process` usage (`safe_process_usage_test.dart`), dependency direction (`dependency_direction_test.dart`), `src/` import hygiene (`src_import_hygiene_test.dart`), testing-package dependency shape (`testing_package_deps_test.dart`), cross-consumer enum exhaustiveness (`enum_exhaustive_consumer_test.dart`), the workflow/task boundary (`workflow_task_boundary_test.dart`), and a `fitness_smoke_test.dart`. A `dart format --set-exit-if-changed` gate runs as a separate CI step.
- **Frozen-baseline ratchet.** Pre-existing violations are grandfathered via committed allowlists with mandatory rationale comments; CI fails only on *new* (regression) violations. Numeric ceilings live in `arch_check.dart` and are ratcheted downward over time (e.g. `dartclaw_core` LOC 13 000 → 12 500; barrel-export ceiling raised 80 → 82 only to admit intentionally-promoted interfaces).
- **Local runner + guidance.** `bash dev/tools/run-fitness.sh`; each check has "how to resolve a failure" guidance in `packages/dartclaw_testing/test/fitness/README.md`.

## Consequences

### Positive

- Architectural invariants are enforced continuously and at PR time, with resolution guidance.
- Allowlist rationale comments make every intentional exception auditable at review time.
- The progressive-improvement ratchet lets the codebase converge without a freeze; checks are Dart-native (no new toolchain).

### Negative

- Allowlists can rot if the rationale-comment discipline lapses; numeric ceilings need periodic re-ratcheting to stay meaningful.
- Heuristic checks (e.g. `safe_process_usage`) depend on allowlist escape hatches for legitimate exceptions.

## Alternatives Considered

1. **Manual code review only** — rejected: inconsistent and does not scale across ~12 packages; no regression signal.
2. **Analyzer / linter rules only** — rejected: the Dart analyzer cannot express architecture-level invariants (cross-package dependency direction, barrel ceilings, package cycles).
3. **External tooling (`lakos`, `dependency_validator`) without CI gating** — rejected: useful for ad-hoc inspection but not enforced per PR, and adds tooling outside the Dart-native test chain.
4. **Hard zero-violation gate, no allowlist/ratchet** — rejected: blocks all new work behind a big-bang refactor of pre-existing violations.

## References

- `packages/dartclaw_testing/test/fitness/` (14 test files) + `README.md`; allowlists with rationale comments
- `dev/tools/run-fitness.sh`, `dev/tools/arch_check.dart`
- CHANGELOG `[0.16.5]` — Level-1 / Level-2 governance fitness suite; barrel ceiling 80 → 82; `dartclaw_core` LOC ratchet 13 000 → 12 500. CHANGELOG `[0.16.4]` — `arch_check.dart` ceiling ratchet origin
- Ford / Parsons / Kua, *Building Evolutionary Architectures* — fitness functions; the "frozen rules" progressive-improvement pattern
