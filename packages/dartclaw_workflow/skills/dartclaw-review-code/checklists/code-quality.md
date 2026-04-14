# Code Quality Checklist

Use this checklist when reviewing correctness, readability, performance, and maintainability in DartClaw code.

## Pre-Review

- [ ] Understand the feature's purpose, scope, and expected runtime path.
- [ ] Read the changed files and nearby code before judging any single hunk.
- [ ] Check project instructions and any local review guidance that applies.
- [ ] Separate implementation defects from style preferences.

## Correctness

- [ ] The implementation matches the explicit requirements and task verification criteria.
- [ ] Inputs, edge cases, and empty states are handled intentionally.
- [ ] Error handling is complete and produces actionable failures.
- [ ] Async code handles ordering, cancellation, and error propagation safely.
- [ ] Default behavior is deliberate, documented, and not surprising.
- [ ] Data flow stays consistent across callers, adapters, and storage.
- [ ] Tests cover the behavior that matters, not just a happy path.

## Readability

- [ ] Names are accurate, domain-aware, and consistent with nearby code.
- [ ] Functions and classes are sized for fast comprehension.
- [ ] Control flow is easy to follow without hidden state or clever tricks.
- [ ] Repeated patterns are extracted only when the abstraction is real.
- [ ] Comments explain non-obvious intent, not obvious mechanics.
- [ ] Magic numbers, literals, and flags are replaced with named constants where useful.
- [ ] Formatting and structure make the code easy to scan in review.

## Performance

- [ ] There are no obvious algorithmic regressions or avoidable hot-path costs.
- [ ] Query patterns avoid N+1 behavior, repeated I/O, and unnecessary allocations.
- [ ] Resource use is reasonable for memory, CPU, network, and file handles.
- [ ] Caching, batching, streaming, or pagination are used where they materially help.
- [ ] Expensive work is not performed repeatedly when a cached or shared result is available.
- [ ] Concurrency is used only when it improves throughput or responsiveness.

## Maintainability

- [ ] Responsibilities are separated so the code is easy to change in one place.
- [ ] Layer and module boundaries are respected.
- [ ] The code follows established project patterns unless there is a clear reason not to.
- [ ] Public APIs, extensions, and helpers are testable and have a stable shape.
- [ ] The change does not introduce avoidable duplication or abstraction debt.
- [ ] Logging, metrics, and error messages support future debugging.
- [ ] Technical debt is explicit when it cannot be removed immediately.
- [ ] Regression risk is low because the smallest effective change was used.

## Additional Checks

- [ ] Integration points are wired end-to-end and not just defined locally.
- [ ] New code is imported, referenced, or invoked by a real path.
- [ ] Existing flows continue to work after the change.
- [ ] Stubs, TODOs, and placeholder logic are not mistaken for finished behavior.
- [ ] Cleanup tasks and follow-up work are called out clearly when needed.

## Issue Classification

### CRITICAL

- Broken core behavior that blocks the feature or corrupts data.
- Incorrect async handling that can lose work, duplicate work, or deadlock a flow.
- A defect that will fail in normal use, not just in an edge case.
- A regression that changes the contract in a way callers cannot safely absorb.

### HIGH

- Major logic mistake that affects the main user journey or integration path.
- Maintainability problem that will quickly turn into repeated defects.
- Performance regression that will be visible in regular use.
- Missing test coverage for an important branch or interaction.

### MEDIUM

- Readability or organization issues that slow future changes.
- Unnecessary duplication that is not yet causing a correctness defect.
- Minor performance issues that matter only under heavier load.

### LOW

- Cleanup opportunities, naming polish, or documentation improvements.
- Nice-to-have refactoring that does not change behavior.
