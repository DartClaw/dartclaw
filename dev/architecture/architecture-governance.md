# Architecture Governance

Canonical reference for how DartClaw keeps package boundaries and structural
constraints from drifting after a milestone ships.

**Current through**: 0.27.1 LOC target amendment.

---

## Purpose

DartClaw uses two kinds of architectural documentation:

- descriptive documents that explain how the system is designed
- executable governance that fails when the code stops matching agreed
  structural boundaries

The executable part is the architecture fitness-function script:

- Public repo source of truth: [`dev/tools/arch_check.dart`](../tools/arch_check.dart)

This document explains what that script is for, what it currently enforces,
what it does not enforce, and how to evolve it.

## Why This Exists

The 0.16.3 package-decomposition milestone introduced new structural boundaries:

- SQLite persistence moved out of `dartclaw_core` into `dartclaw_storage`
- typed config loading moved into `dartclaw_config`
- workflow parsing/validation/execution moved into `dartclaw_workflow`
- server-only container orchestration moved into `dartclaw_server`

The 0.16.3 decisions are recorded in
[`ADR-020`](../adrs/020-package-decomposition-phase-2.md). The 0.25
consolidation formed `dartclaw_kernel` from the models, config, and security
packages, then absorbed `dartclaw_storage` back into `dartclaw_core`, as
recorded in [`ADR-056`](../adrs/056-package-topology-consolidation.md). ADRs
alone do not stop drift. The executable checks below protect the current
topology mechanically instead of relying on memory or review luck.

## Governance Layers

Architecture governance is intentionally layered:

1. `dart analyze`
   Catches unresolved imports, stale re-exports, type mismatches, and a large
   class of migration mistakes.

2. `dart run dev/tools/arch_check.dart`
   Enforces structural rules that the analyzer does not know about: per-package
   LOC targets, the package-count ceiling, the core barrel's shape, and Claude
   provider option ownership. Dependency direction is not here — it belongs to
   the tier order and its fitness gate.

3. Architecture docs and ADRs
   Explain why the boundary exists and when it is acceptable to change it.

`arch_check.dart` is not a replacement for the analyzer or tests; it is a
boundary-governance layer that complements them.

## Current Fitness Functions

Dependency direction is **not** one of them. It is governed by the declared tier
order in [`dev/package_tiers.txt`](../package_tiers.txt), enforced by
`dev/fitness/test/dependency_direction_test.dart`. That gate derives the allowed
edges from tier position, reconciles each member's declared pubspec dependencies
against what its libraries actually import, and fails on a workspace member with
no tier. There is no per-edge table and no exception entry in either place: an
edge that cannot be expressed as a downward step is resolved by splitting a tier.

[`arch_check.dart`](../../dev/tools/arch_check.dart) enforces what is left:

### L1: Fast Structural Boundaries

1. `dartclaw_core` barrel does not launder the kernel
   A full re-export of the kernel barrel would make every kernel symbol look
   core-owned; targeted `show`-scoped re-exports stay allowed.

2. Claude provider option ownership
   Keeps direct `inherit_user_settings` lookups centralized in `dartclaw_kernel`
   instead of re-parsing provider options ad hoc.

Cross-package `src/` imports are **not** here either. That rule belongs to
`dev/fitness/test/src_import_hygiene_test.dart`, which owns the allowlist the
exceptions are recorded in.

### L2: Shape Constraints

3. Per-package `lib/` LOC targets
   One recorded target per workspace member with a `lib/`. Growth fails when
   measured lines reach at least 110% of that target. Shrinkage never fails the
   size check. A member with no recorded target fails rather than going unmeasured.

4. Workspace package-count ceiling
   Prevents premature decomposition and pubspec sprawl. It counts directories
   under `packages/` only; the root `workspace:` list holds two more members
   (`apps/dartclaw_cli` and `dev/fitness`).

`dev/tools/fitness/run_all.sh` is the broader CI fitness-suite entry point. It
adds the workflow-private-config, framework-coupling, prose-parsing, CSS-comment,
external-origin and task-executor boundary scripts, the config-schema drift
check, the config-reference render self-test and its guide-drift check
(`test_render_config_reference.sh`, `check_config_reference_drift.sh`), plus the
Dart fitness tests under `dev/fitness/test/`.

Two of those gates hold the defect classes the 0.25 milestone is named for:

- **`check_no_prose_parsing.sh`** — the prose-parsing, repair-ladder and sentinel
  constructs the milestone deleted stay deleted: the retired workflow-output
  recovery and review-count derivation symbols, the retired `@advisor` mention
  and review chat grammars, and the literal `'null'` path sentinel on the
  artifact-claim path. It ships **no allowlist**, deliberately. It does not ask
  "is this a prose parser?" — that question needs an exemption list larger than
  the defect, because code-fence and prefix handling is legitimate in the
  chunking and Markdown paths. It asks whether a named retired construct is
  back, and every pattern in it was measured at zero before it was added. A
  pattern that already matches is a finding against the story that owned the
  deletion, never an exemption. Its reach is exactly that named set: it catches
  the listed constructs returning, not the defect class in general.
- **`no_second_implementation_test.dart`** (in the Dart suite, because that is
  where the consulted-key allowlist reader lives) — a public production type
  name declared in one workspace member's `lib/` may not be declared in
  another's, apps included. A `typedef X = other.X;` re-alias is a re-export and
  is skipped by the scan rather than exempted. Its allowlist is a ratchet pinned
  at its actual size, so it can shrink and not grow; it started from the ten
  cross-package duplicates the milestone began with and holds two. Every entry
  states in one line why it survives, and both are legitimate: a port and its
  adapter sharing the port's name. The four `PENDING` collisions the file carried
  through the milestone were closed by production rename rather than by an
  allowlist edit — `HarnessConfig`, `ReservedCommandHandler`,
  `WorkflowValidationError` and `WindowsProcessTreeKillCommand`. A gate that consults its allowlist by key also fails on a **stale**
entry — one it never looked up during the run, because the path, position or edge
it named is gone. (Three allowlists — `bridge_package_deps.txt`,
`testing_package_deps.txt` and `package_cycles.txt` — are mandated empty and
consult nothing; their gates assert emptiness instead.)

## Current Thresholds

The current thresholds live in code because they are executable policy, but the
intent should remain documented here:

| Constraint | Current value | Why it exists |
|---|---:|---|
| Per-package `lib/` LOC target | one recorded number per member in `_libLocCeilings` | Fail at measured LOC ≥ 110% of the target; smaller growth and shrinkage pass |
| Production and test file LOC targets | 1,500 and 1,300 respectively | Fail at 1,650 and 1,430; allowlisted test files use 110% of their recorded baseline |
| Workspace package count | `<= 13` | Keep the count under `packages/` exact, including `dartclaw_search` and `dartclaw_bridge` |

Targets are recorded in code because they are executable policy. A size change
below the ten-percent margin needs no target edit. When growth reaches the margin,
review decomposition or record a deliberate target change with measured rationale.
If the margin changes, update this document and the gates together.

## What Is Explicitly In Scope

Architecture governance should focus on stable, high-signal boundaries:

- package dependency direction (owned by the tier order, not by this script)
- forbidden production dependencies
- package/API surface size constraints
- public-vs-private import hygiene
- milestone-specific architectural seams that should not silently regress

These checks should stay cheap enough to run locally during normal development.

## What Is Explicitly Out of Scope

The script should not try to encode every quality rule in the codebase.

Examples that belong elsewhere:

- behavioral correctness
  Covered by tests.

- style and unused code
  Covered by formatter and analyzer.

- subjective refactoring preferences
  Covered by review and maintainers.

- complex semantic architecture inference
  Better handled by architecture review than a brittle regex-heavy script.

## When To Update `arch_check.dart`

Update the script when a shipped architectural decision introduces a boundary
that should remain true after the milestone closes.

Good candidates:

- a new package is added with an agreed package-count ceiling impact
- a package reaches 110% of its recorded `lib/` target and the target is deliberately changed
- a milestone introduces a boundary that would be easy to regress mechanically

Do not update the script just because a one-off cleanup happened. Fitness
functions should encode enduring constraints, not temporary implementation
details.

**A package LOC target changes only when its recorded number is intentionally
revised.** The size gate fails at exactly 110% of the target. A change below that
margin needs no rebaseline. A target change that admits growth beyond the margin
records the measured value and rationale in `arch_check.dart` and `CHANGELOG.md`,
as described in [ADR-033](../adrs/033-architectural-governance-via-fitness-functions.md).

## Change Process

When changing architecture governance:

1. Change the code
   Update [`dev/tools/arch_check.dart`](../../dev/tools/arch_check.dart).

2. Change the explanation
   Update this document and any affected ADR or architecture doc.

3. Re-run the baseline
   Run:
   - `dart analyze`
   - `dart run dev/tools/arch_check.dart`

4. Explain the reason
   If the boundary changed intentionally, document the rationale in the same
   change. Do not silently loosen thresholds.

## Operational Use

Run the fitness functions from the public repo root:

```bash
dart run dev/tools/arch_check.dart
```

Expected behavior:

- exit `0` when all checks pass
- exit non-zero when any check fails
- print one line per check plus a summary

The script is designed as local governance tooling first. CI integration is
useful, but not required for the governance model to be valid.

`.github/workflows/ci.yml` runs two jobs. **Check** runs format, analyze, the
workspace suite, `arch_check.dart` and `dev/tools/fitness/run_all.sh`.
**Container boundary** is separate so a container-runtime problem fails by name
rather than inside the test suite: it builds the in-container bridge and runs
`dev/testing/profiles/container/run.sh --ci`, which boots a config declaring no
`container:` section and asserts the posture resolved to container isolation. An
absent runtime fails that job rather than skipping — the server's advisory
downgrade exits zero and would otherwise read as a pass. It carries no fork-PR
condition because it needs no secret and issues no model turn.

## Related Documents

- [System Architecture](system-architecture.md)
- [Data Model](data-model.md)
- [Workflow Architecture](workflow-architecture.md)
- [ADR-014: SDK Package Decomposition Strategy](../adrs/014-sdk-package-decomposition.md)
- [ADR-020: Package Decomposition Phase 2](../adrs/020-package-decomposition-phase-2.md)
