# Feature Implementation Specification

## Feature Overview and Goal

{{1-2 sentences describing what needs to be built and why. Keep this outcome-focused.}}

{{If a companion technical research file exists, include the link here. Remove this line only if no research doc exists.}}
> **Technical Research**: [technical-research.md](./technical-research.md) _(codebase patterns, architecture analysis, API research)_

## Success Criteria (Must Be TRUE)

> Each criterion must have a defined proof path. Use at least one Scenario for behavioral criteria or a task verification criteria line for structural criteria.

- [ ] {{Observable user-facing or system-facing truth}}
- [ ] {{Verifiable behavior with an explicit proof path}}
- [ ] {{Measurable technical requirement}}
- [ ] {{Integration or compatibility requirement}}

### Health Metrics (Must NOT Regress)

- [ ] {{Existing tests continue to pass}}
- [ ] {{Existing API contracts remain intact unless explicitly scoped}}
- [ ] {{Performance or resource use does not regress}}

## Scenarios

> Write concrete examples that double as proof-of-work. Use Given/When/Then and actual domain terms.

### {{Scenario Name}}

- **Given** {{precondition or system state}}
- **When** {{trigger or event}}
- **Then** {{observable outcome}}

### {{Edge Case / Error Scenario Name}}

- **Given** {{boundary or failure precondition}}
- **When** {{boundary condition or rejection trigger}}
- **Then** {{expected handling behavior}}

_Write 3-7 scenarios. Cover the happy path, important edge cases, and at least one failure or rejection case. Apply the negative-path checklist from the authoring guidelines after drafting._

## Scope & Boundaries

### In Scope

_Every scope item must be covered by at least one scenario or a task with a task verification criteria line._

- {{Core functionality}}
- {{Required integrations}}
- {{Expected outputs or user-visible surfaces}}

### What We're NOT Doing

_Keep this to 3-5 explicit exclusions or deferrals. Each item should name the exclusion and why it is excluded now._

- {{Out of scope item}} -- {{reason}}
- {{Existing behavior not being changed}} -- {{reason}}

### Agent Decision Authority

- **Autonomous**: {{Decisions the executing agent can make}}
- **Escalate**: {{Decisions that require human input}}

## Architecture Decision

**We will**: {{chosen approach}} -- {{one-line rationale}} (over {{rejected alternative(s)}})

For genuine trade-offs, use a short alternatives list:

1. **{{Alt 1}}** -- rejected: {{reason}}
2. **{{Alt 2}}** -- rejected: {{reason}}

If an ADR already covers the choice, reference it here.

## Technical Overview

> Keep this at the level needed to execute the spec. Put deep research in the companion document.

### UI/UX Design

{{Describe the user-facing flow, screens, or interaction model if applicable.}}

### Data Models

{{Describe natural-language field shapes, relationships, and lifecycle notes.}}

### Integration Points

{{List the systems, packages, APIs, or workflows this feature must connect to.}}

### Key References

- {{file:line reference to a comparable pattern}}
- {{file:line reference to a dependency or constraint}}
- {{doc or ADR reference}}

## References & Constraints

### Documentation & References

```
# type | path/url | why needed
file | src/path/example.dart:12-34 | pattern to follow
doc  | docs/adrs/001-example.md    | architecture constraint
```

### Constraints & Gotchas

- **Constraint**: {{known limitation}} -- Workaround: {{specific solution}}
- **Avoid**: {{common mistake}} -- Instead: {{correct approach}}
- **Critical**: {{framework or library limitation}} -- Must handle by: {{approach}}

## Implementation Plan

Tasks are organized into **Execution Groups**. Groups marked **[P]** can run in parallel with sibling groups at the same dependency level. Tasks within a group execute sequentially.

> **Vertical slice ordering**: first group produces a thin but working path; later groups widen and harden it.

### Execution Groups

_Examples below show outcome-first task wording, dependency declarations, and task verification criteria._

#### G1: Core Path <- [depends: none]

- [ ] **TI01** {{Outcome that must be true when done}}
  - {{Context: pattern reference, constraint, or dependency}}
  - **task verification criteria**: {{observable check that fails if the outcome is missing}}

- [ ] **TI02** {{Outcome that extends TI01}}
  - {{Context: shared abstraction or constraint}}
  - **task verification criteria**: {{observable check}}

#### G2: Expansion [P] <- [depends: G1]

- [ ] **TI03** {{Outcome}}
  - {{Context for this parallel branch}}
  - **task verification criteria**: {{observable check}}

- [ ] **TI04** {{Outcome}}
  - {{Context}}
  - **task verification criteria**: {{observable check}}

## Testing Strategy

> Derive tests from the Scenarios section. Each scenario should map to one or more tests, tagged by execution group.

- [G1] Scenario: {{scenario name}} -> {{test description}}
- [G2] Scenario: {{scenario name}} -> {{test description}}
- [edge] Scenario: {{scenario name}} -> {{edge-case or rejection test}}

## Validation

> Standard validation (code review, testing, quality review, remediation) is handled by exec-spec. Add only feature-specific validation here.

- {{Feature-specific validation requirement}}
- {{Additional runtime or visual check, if applicable}}

## Final Validation Checklist

- [ ] **All success criteria** are met
- [ ] **All tasks** are complete and verified
- [ ] **All scenarios** have corresponding tests or observable checks
- [ ] **No regressions** or breaking changes were introduced
- [ ] **References and constraints** were followed
- [ ] **Task verification criteria** covered any prescribed formats, paths, or strings
