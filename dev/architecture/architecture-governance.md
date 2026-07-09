# Architecture Governance

Canonical reference for how DartClaw keeps package boundaries and structural
constraints from drifting after a milestone ships.

**Current through**: 0.20

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

- `dartclaw_core` became sqlite3-free and returned to runtime primitives
- typed config loading moved into `dartclaw_config`
- workflow parsing/validation/execution moved into `dartclaw_workflow`
- server-only container orchestration moved into `dartclaw_server`

Those decisions are recorded in
[`ADR-020`](../adrs/020-package-decomposition-phase-2.md), but ADRs alone do
not stop drift. Architecture governance exists so boundary regressions are
detected mechanically instead of by memory or review luck.

## Governance Layers

Architecture governance is intentionally layered:

1. `dart analyze`
   Catches unresolved imports, stale re-exports, type mismatches, and a large
   class of migration mistakes.

2. `dart run dev/tools/arch_check.dart`
   Enforces structural rules that the analyzer does not know about, such as
   sqlite3 exclusion from core, barrel ceilings, package-count ceilings, and
   documented workspace dependency boundaries.

3. Architecture docs and ADRs
   Explain why the boundary exists and when it is acceptable to change it.

`arch_check.dart` is not a replacement for the analyzer or tests; it is a
boundary-governance layer that complements them.

## Current Fitness Functions

[`arch_check.dart`](../../dev/tools/arch_check.dart) enforces eight
checks:

### L1: Fast Structural Boundaries

1. Dependency graph and layering
   Verifies that the workspace resolves and that each workspace package/app
   matches the documented internal dependency DAG.

2. No sqlite3 in `dartclaw_core`
   Ensures `dartclaw_core` remains usable as the sqlite3-free runtime base.

3. No cross-package `src/` imports in production libraries
   Protects package public APIs and prevents boundary erosion through private
   internals.

4. Claude provider option ownership
   Keeps direct `inherit_user_settings` lookups centralized in `dartclaw_config`
   instead of re-parsing provider options ad hoc.

### L2: Shape Constraints

5. `dartclaw_core` LOC ceiling
   Guards against the core package returning to a god-module shape.

6. `dartclaw_workflow` LOC ceiling
   Keeps workflow-engine growth visible and forces a stop-or-justify decision
   before package size drifts silently.

7. Barrel export ceiling
   Prevents public API surfaces from growing without deliberate review.

8. Workspace package-count ceiling
   Prevents premature decomposition and pubspec sprawl.

`dev/tools/fitness/run_all.sh` is the broader CI fitness-suite entry point. It
adds the workflow-private-config and task-executor boundary scripts plus the Dart
fitness tests under `packages/dartclaw_testing/test/fitness/`.

## Current Thresholds

The current thresholds live in code because they are executable policy, but the
intent should remain documented here:

| Constraint | Current value | Why it exists |
|---|---:|---|
| `dartclaw_core` LOC ceiling | `<= 14900` | Preserve a lightweight runtime core (bumped 12500 → 14900 through 0.18 for the first-party ACP harness; see the rationale comments in `dev/tools/arch_check.dart`) |
| `dartclaw_workflow` LOC ceiling | WARN `>= 24600`, hard `<= 25000` | Preserve the post-simplification workflow-engine size as a ratchet: current baseline usage is about 23,311 LOC, the hard ceiling carries about two milestones of headroom, and the WARN threshold fires a few hundred LOC before the cap so growth is planned or justified |
| Barrel export ceiling | `<= 94` | Keep public package surfaces reviewable |
| Workspace package count | `<= 14` | Avoid package proliferation without real need |

If these thresholds change, update both this document and the script in the
same change.

## What Is Explicitly In Scope

Architecture governance should focus on stable, high-signal boundaries:

- package dependency direction
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

- a package moves above or below another package in the DAG
- a dependency becomes forbidden in a foundational package
- a new package is added with an agreed package-count ceiling impact
- a milestone introduces a boundary that would be easy to regress mechanically

Do not update the script just because a one-off cleanup happened. Fitness
functions should encode enduring constraints, not temporary implementation
details.

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

## Related Documents

- [System Architecture](system-architecture.md)
- [Data Model](data-model.md)
- [Workflow Architecture](workflow-architecture.md)
- [ADR-014: SDK Package Decomposition Strategy](../adrs/014-sdk-package-decomposition.md)
- [ADR-020: Package Decomposition Phase 2](../adrs/020-package-decomposition-phase-2.md)
