---
name: dartclaw-exec-spec
description: Execute a Feature Implementation Specification by orchestrating execution groups, verification gates, and context handoffs.
argument-hint: "<path-to-fis>"
---

# dartclaw-exec-spec

Use this skill to implement a fully defined FIS as an orchestrator.

## Operating Rules
- Treat the FIS as the source of truth.
- Do not write implementation code directly unless the workflow explicitly requires local orchestration logic.
- Delegate work by execution group, one group at a time.
- Before each coding group, scaffold failing tests from the scenarios when scenarios exist.
- Verify each group before moving to the next dependency step.

## Required Orchestration
- Parse execution groups, dependencies, and critical path.
- Pass each group a focused prompt with task details, references, and relevant constraints.
- Require a handoff summary after every completed group.
- Run verification gates between groups and do not continue with unresolved failures.
- Update workflow state when the spec and project context support it.

## Handoff Format
Each completed group should produce:
- APIs and interfaces introduced
- Naming conventions established
- Key files created or modified
- Integration points exposed to later groups

## Validation Discipline
- Start with failing tests for scenario-backed behavior.
- Use verify lines for structural and wiring checks.
- Re-run only the affected validation when a group changes.
- Report unresolved ambiguity with structured confusion or missing-requirement output.
