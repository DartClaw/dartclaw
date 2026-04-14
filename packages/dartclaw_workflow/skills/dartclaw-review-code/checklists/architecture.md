# Architecture Checklist

Use this checklist when a review needs to judge structure, boundaries, and long-term system shape.

## Pre-Review

- [ ] Identify the architectural scope and the changed boundaries.
- [ ] Read nearby design guidance, ADRs, and implementation patterns before reviewing.
- [ ] Determine whether the change is local, cross-cutting, or foundational.
- [ ] Separate intentional architecture choices from accidental structure.

## CUPID

Assess the change against CUPID principles and record concrete evidence.

### Composable

- [ ] Dependencies are small, explicit, and easy to swap.
- [ ] Interfaces are clear and support reuse without leaking internals.
- [ ] Components compose without hidden coupling or shared mutable assumptions.

### Unix Philosophy

- [ ] Each module does one thing well.
- [ ] Responsibilities are narrow enough that changes stay local.
- [ ] The feature does not grow into a grab bag of unrelated behavior.

### Predictable

- [ ] Behavior is consistent and unsurprising across similar code paths.
- [ ] Failure modes are explicit and handled in one place where possible.
- [ ] Data flow and state transitions are easy to follow.

### Idiomatic

- [ ] The design follows project conventions and the language's normal patterns.
- [ ] The code does not fight the framework or the runtime.
- [ ] Configuration and extension points are natural instead of contrived.

### Domain-Aligned

- [ ] Names, modules, and boundaries reflect the business domain.
- [ ] Technical structure supports the way the domain is actually used.
- [ ] The model does not flatten important domain distinctions.

## Dependency Direction and Layer Boundaries

- [ ] Dependencies point in the intended direction.
- [ ] Lower-level infrastructure does not leak into higher-level policy code.
- [ ] Shared abstractions are justified and not introduced too early.
- [ ] Layer boundaries are explicit enough that future changes do not cross them casually.
- [ ] Cross-module calls are the minimum required for the feature to work.
- [ ] The change avoids circular dependencies and bidirectional ownership.

## Anti-Pattern Detection

- [ ] No god object or god service accumulates unrelated responsibilities.
- [ ] No circular dependency or tangled import graph appears.
- [ ] No tight coupling makes two modules change together unnecessarily.
- [ ] No feature envy, inappropriate intimacy, or chatty interface is introduced.
- [ ] No primitive obsession hides domain meaning in raw values.
- [ ] No shotgun surgery is created by scattering logic across many files.

## Issue Classification

### CRITICAL

- Architecture that breaks core guarantees, data integrity, or security boundaries.
- A dependency direction problem that makes the design unsafe to extend.
- A structural flaw that will force repeated invasive changes across the system.

### HIGH

- Clear layer violation or boundary leak.
- Coupling or abstraction choices that will quickly block future work.
- Anti-patterns that make the feature difficult to reason about or test.

### MEDIUM

- Architectural polish, naming, or decomposition issues that are worth correcting.
- Local structural concerns that do not yet create a functional defect.

### LOW

- Style-only architectural preferences or optional cleanup.
