---
name: dartclaw-exec-spec
description: Execute a Feature Implementation Specification by orchestrating execution groups, verification gates, and status updates.
argument-hint: "<path-to-fis>"
---

# dartclaw-exec-spec

Use this skill to execute a fully defined FIS as an orchestrator. Delegate implementation work to sub-agents and keep the main workflow focused on coordination, verification, and state updates.

## Operating Rules
- Treat the FIS as the source of truth.
- Read any companion `technical-research.md` for context, but verify its claims against the current codebase before relying on them.
- Do not write implementation code directly unless the workflow explicitly requires orchestration glue.
- Delegate every execution group to one sub-agent.
- Prefer rollback-friendly groups: add and wire first, remove old paths later.
- Scaffold failing tests from scenarios before implementation when scenarios exist.
- Update workflow state through `project_index` when the spec and project context support it.
- Use `../references/structured-output-protocols.md` for ambiguity handling with `CONFUSION`, `NOTICED BUT NOT TOUCHING`, and `MISSING REQUIREMENT`.

## Workflow

### 1. Resolve FIS
- Resolve `FIS_SOURCE` to a local FIS path.
- Read the FIS, its success criteria, scope, architecture, implementation plan, and final validation checklist.
- Read the companion technical research when present and extract only verified context for delegation.
- If the FIS is plan-backed, resolve the companion plan file and story identifiers from local project metadata and `project_index`.
- If active story state exists, mark the work `In Progress` through `project_index` before implementation begins.
- Build the group map: execution order, dependencies, parallel groups, and critical path.
- Read project learnings and any local implementation notes before coding starts.

### 2. Scaffold Tests
- If the FIS has scenarios or a testing strategy, create failing tests first.
- Group test scaffolding by execution group so each group has an acceptance gate.
- Use scenario tests to prove behavior, not just implementation shape.
- Skip only when the work is configuration-only or purely additive wiring with no branching logic.

### 3. Execute Groups
- Spawn one foreground sub-agent per execution group.
- Pass each group a focused prompt with the exact task text, prescriptive constraints, and required references.
- Use the templates below for every group.
- Keep groups rollback-friendly and small enough to verify independently.

#### Group Input Template
```markdown
## Execution Group: {GROUP_ID} - {Group Name}
Execute the following tasks sequentially. Verify each task's criteria before proceeding.

### Task: {TASK_ID} - {Task title}
{Task description and sub-items from the FIS}
**Verify**: {task verification criteria}

## FIS Reference
Path: {FIS_FILE_PATH}
{ADR decisions, key constraints, and relevant references}

## Key References
{File:line references relevant to any task in this group}

## Context from Prerequisite Groups
{Context for Dependent Groups from completed prerequisite groups}

## Scenarios to Satisfy
{Scenarios paired with tasks in this group}
Write and verify tests for these scenarios before implementing. They should fail first, then pass.

## Domain Language
{Key terms relevant to this group}

## Structured Output Protocols
Use `../references/structured-output-protocols.md` when ambiguity or missing requirements appear.

## Requirements
1. Execute tasks sequentially within this group.
2. Verify each task before proceeding.
3. Follow patterns in referenced files.
4. Report back with the Group Result format below.
```

#### Group Result Template
```markdown
## Group Result: {GROUP_ID} - {Group Name}

### Per-Task Status
- {TASK_ID}: complete | partial | blocked - {brief summary}

### Context for Dependent Groups
- APIs/interfaces introduced: {function signatures, class shapes}
- Naming conventions established: {patterns chosen}
- Key file paths created/modified: {path - brief role}
- Integration points exposed: {what subsequent groups hook into}

### Issues
{blockers, errors, concerns for orchestrator}
```

### 4. Validate
- Run a verification gate after every group before moving to the next dependency step.
- Use task verification criteria for structural checks, wiring checks, and file existence checks.
- If a task fails, stop dependent work and spawn a targeted fix sub-agent.
- For behavioral failures, apply the Prove-It Pattern: write a failing test that demonstrates the bug before fixing it.
- Re-run only the affected validation after a fix.
- Include a proof-of-work rhythm for scenario-backed work: red first, then green, then verification.
- Perform a spec compliance spot-check before marking complete:
  - verify prescribed format strings appear in source or output
  - verify required column names and ordering appear where specified
  - verify required file paths exist at the prescribed locations
  - verify exact error messages and required UI elements are present when the FIS prescribes them
- Use `rg` or equivalent checks to confirm no TODO, FIXME, placeholder, or not-implemented markers remain in the changed scope.

### 5. Update Status
- Mark completed task checkboxes in the FIS as soon as the group passes verification.
- Update success criteria and final validation checklist items as they are satisfied.
- If the FIS is plan-backed, update the source plan and associated story records through `project_index`.
- Mark the active story or story set `Done` when implementation is complete.
- Re-read the FIS and plan after status updates to confirm the final state is reflected in the source files.

## Validation Discipline
- Carry the context forward between groups using the previous group's context block.
- Keep the orchestrator role focused on coordination, verification, and state updates.
- Report unresolved ambiguity with `CONFUSION` or `MISSING REQUIREMENT` instead of improvising.
- Do not proceed with unresolved verification failures.
- Ensure the final completion state reflects the updated FIS, plan, and project status.

## Completion Protocol
- Verify all success criteria in the FIS are satisfied.
- Verify all task checkboxes and final validation checklist items are complete.
- Confirm all changed files are wired into the implementation or orchestration path.
- Confirm the FIS source and any plan source are updated in place.
- Return control only after the workflow is fully complete.
