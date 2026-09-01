# ADR-033: Architectural Governance via Fitness Functions in CI

## Status

Accepted — 2026-05-31 (implemented in 0.16.5; recorded retroactively during an ADR-gap review of 0.16.4–0.16.6)

**Related:** [ADR-034](034-enforced-package-dependency-direction.md) (the dependency-direction rule is one of the checks this mechanism enforces), [ADR-010](010-package-split-models.md) and [ADR-020](020-package-decomposition-phase-2.md) (the package structure these checks defend).

## Context

The Dart pub workspace had grown to ~12 packages. Architectural drift — package cycles, ballooning barrel exports, oversized files, cross-package code duplication, unguarded `Process` usage, and dependency-direction violations — was caught only by manual review, inconsistently and after the fact. 0.16.4 had already introduced numeric ceilings in `dev/tools/arch_check.dart` (LOC, barrel-export counts) as a stopgap; 0.16.5 needed a durable, first-class governance mechanism. The constraint: the codebase carried pre-existing violations, so a hard "zero violations or fail" gate would force a big-bang refactor before any new work could land.

## Decision

Encode architectural invariants as **executable fitness functions** — plain Dart tests under `dev/fitness/test/` — run as CI gates, governed by a **frozen-baseline ratchet**:

- **Two levels of checks.** The suite covers barrel `show`-clause hygiene and export ceilings (`barrel_show_clauses_test.dart`, `barrel_export_count_test.dart`), file size (`max_file_loc_test.dart`; the companion method-count gate was retired in 0.25 — its line heuristic undercounted by roughly half), package cycles (`package_cycles_test.dart`), constructor parameter counts (`constructor_param_count_test.dart`), cross-package env-plan duplication (`no_cross_package_env_plan_duplicates_test.dart`), safe `Process` usage (`safe_process_usage_test.dart`), dependency direction (`dependency_direction_test.dart`), `src/` import hygiene (`src_import_hygiene_test.dart`), testing-package dependency shape (`testing_package_deps_test.dart`), cross-consumer enum exhaustiveness (`enum_exhaustive_consumer_test.dart`), the workflow/task boundary (`workflow_task_boundary_test.dart`), memory architecture (`memory_architecture_test.dart`), and the suite's own import-free dependency shape (`fitness_suite_deps_test.dart`). A `dart format --set-exit-if-changed` gate runs as a separate CI step.
- **Frozen-baseline ratchet.** Pre-existing violations are grandfathered via committed allowlists with mandatory rationale comments; CI fails only on *new* (regression) violations. Numeric ceilings live in `arch_check.dart` and are ratcheted downward over time (e.g. `dartclaw_core` LOC 13 000 → 12 500; barrel-export ceiling raised 80 → 82 only to admit intentionally-promoted interfaces).
- **Local runner + guidance.** `bash dev/tools/run-fitness.sh`; each check has "how to resolve a failure" guidance in `dev/fitness/README.md`.

## Consequences

## Amendment (2026-08-25) – reviewed numeric-ceiling raises remain possible

Per-package LOC ceilings ratchet down routinely, but the ratchet is not permission to distort code or reject required
product behavior when a ceiling proves infeasible. A ceiling may rise only after a maintainer explicitly accepts the
measured growth, safe behavior-preserving reductions have been exhausted, and the change records all three of:

- the post-reduction measured LOC;
- the new ceiling computed by the existing proportional-band rule; and
- a CHANGELOG rationale for the owned growth.

C2 applied that exception to `dartclaw_runtime`: server-rendered task, workflow, guard-editor, and channel-detail
surfaces measured 64,206 lines initially. Readable consolidation removed 381 lines, leaving 63,825. Further reduction
required count-driven formatting, moving decisions into templates merely to evade the Dart counter, or risky public
factory changes that still could not close the gap. The reviewed ceiling is therefore 64,225, exactly the existing
400-line band above the accepted tree. The slack-failure rule remains unchanged, so later shrinkage still ratchets the
ceiling down.

C5 applies the same exception to a package-boundary move rather than net growth. Google Chat's Space Events wiring,
subscription routes and OAuth mechanics must live in `dartclaw_google_chat`; keeping the old 5,746 ceiling would force
owned code back into `dartclaw_runtime` or compress it for the counter. The moved tree measures 6,009 lines, so the
reviewed Google Chat ceiling is 6,409. Runtime first falls to 63,214 lines, then to 63,203 when the sibling-channel
audit moves the WhatsApp JID helper to its owner; its ceiling ratchets from 63,956 to 63,603. Both packages retain
exactly the existing 400-line band; the workspace did not gain this implementation twice.

## Amendment (2026-08-20) – the suite is its own dev-rooted workspace member

The gates moved from `packages/dartclaw_testing/test/fitness/` to `dev/fitness/`, a pub workspace member declaring no
production dependencies. The governance mechanism is unchanged - same rules, same allowlists, same `bash dev/tools/run-fitness.sh` runner and
the same single `run_all.sh` call from CI. The one scanned-set change is that `testDartFiles` also yields the suite's own
`test/` tree, so the test-LOC and duplicate-fake gates keep covering the gates themselves. What changed is what the suite can
reach: hosting repo-wide gates inside a shipped package was one reason that package carried dependencies it did not
need, and a workspace member is exactly where a `package:dartclaw_*` import newly resolves. `fitness_suite_deps_test.dart`
pins the member's pubspec at no `dependencies:` and exactly `path` + `test` under `dev_dependencies:`, and fails on any
`package:dartclaw_` import under the member. A check that genuinely needs production types belongs in a `tool/` script in
the package that owns them, registered as a `dart run` step in `dev/tools/fitness/run_all.sh`.

The member sits under `dev/`, not `packages/`, because `arch_check.dart` keys both its package-count ceiling and its
expected-dependency contract map on directories under `packages/` and `apps/`: a dev-rooted member is invisible to both
while `dart pub workspace list` still finds it, so no CI file changed.

## Amendment (2026-08-12) – memory architecture zero baselines

The cheap Dart fitness suite now guards curation writes routed through `MemoryApplyService.apply`, reintroduction of a
durable curation lifecycle record, canonical or native locators, backend-owned FTS encoding, and retired public memory placeholders. Each scan has an in-memory negative
fixture and actionable remediation, excludes generated Dart, uses no allowlist, and leaves semantic collision and
single-wiki-traversal behavior to their focused integration suites.

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

- `dev/fitness/` – gates under `test/`, `README.md` at the member root; allowlists with rationale comments
- `dev/tools/run-fitness.sh`, `dev/tools/arch_check.dart`
- CHANGELOG `[0.16.5]` — Level-1 / Level-2 governance fitness suite; barrel ceiling 80 → 82; `dartclaw_core` LOC ratchet 13 000 → 12 500. CHANGELOG `[0.16.4]` — `arch_check.dart` ceiling ratchet origin
- Ford / Parsons / Kua, *Building Evolutionary Architectures* — fitness functions; the "frozen rules" progressive-improvement pattern
