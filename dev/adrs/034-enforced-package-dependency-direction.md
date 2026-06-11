# ADR-034: Enforced Package Dependency Direction – Workflow Ports Outside Storage

## Status

Accepted — 2026-05-31 (implemented in 0.16.5; recorded retroactively during an ADR-gap review of 0.16.4–0.16.6)

**Related:** [ADR-033](033-architectural-governance-via-fitness-functions.md) (the fitness mechanism that enforces this rule via `dependency_direction_test.dart`), [ADR-010](010-package-split-models.md) (shared kernel), [ADR-020](020-package-decomposition-phase-2.md) (decomposition phase 2), [ADR-021](021-agent-execution-primitive.md) (consumer of the workflow-run repository).

## Context

`dartclaw_workflow` carried a production dependency on `dartclaw_storage`, coupling the workflow engine directly to a concrete SQLite persistence implementation. This inverted the intended layering (domain/runtime logic depending on a storage adapter), made the engine harder to test in isolation, and let an implementation package leak upward into a runtime package. The decision establishes the *rule*; [ADR-033](033-architectural-governance-via-fitness-functions.md) provides the *mechanism* that keeps it true.

## Decision

Repository **ports live in the package that owns the domain contract; concrete adapters live outside that domain package.** For workflow-run persistence and task-binding coordination, the owning domain package is `dartclaw_workflow`. Concretely:

- Keep `WorkflowRunRepository` and peers such as `WorkflowTaskBindingCoordinator` in `dartclaw_workflow`.
- Keep the concrete SQLite-backed `WorkflowRunRepository` implementation in `dartclaw_storage`; keep the production task-binding coordinator in `dartclaw_server`.
- Remove the `dartclaw_workflow` → `dartclaw_storage` production dependency; retype `TaskExecutor`'s workflow-run-repository dependency to the `dartclaw_workflow` interface (closes ADX-01).
- Enforce the rule going forward with the `dependency_direction_test.dart` fitness check (ADR-033).

The same direction governs the related 0.16.5 extractions (`ProcessEnvironmentPlan`, `ClaudeSettingsBuilder`) into their canonical packages.

## Consequences

### Positive

- The workflow engine is decoupled from any specific storage implementation; it depends only on ports.
- Engine and executor are testable against fakes/in-memory adapters.
- The direction is enforced by CI, not convention, so the inversion cannot silently return.

### Negative

- Port interfaces enlarge the `dartclaw_workflow` public surface; storage and server adapters now depend inward on workflow contracts.
- One extra layer of indirection between the engine and concrete persistence.

## Alternatives Considered

1. **Leave the direct `dartclaw_workflow` → `dartclaw_storage` dependency** — rejected: perpetuates the layering inversion and the test-isolation problem.
2. **Service-locator / global registry for repositories** — rejected: hides dependencies and defeats the fitness-function check.
3. **Duplicate repository interfaces per consuming package** — rejected: invites interface drift; a single port in the owning domain package is the shared contract.

## References

- CHANGELOG `[0.16.5]` — Changed/Architecture: `WorkflowRunRepository` lives in `dartclaw_workflow`; `dartclaw_workflow` storage dependency removed; `TaskExecutor` retyped to the interface (closes ADX-01)
- `packages/dartclaw_testing/test/fitness/dependency_direction_test.dart`
- 0.16.5 PRD.
