---
name: dartclaw-plan
description: Decompose requirements into non-interactive implementation stories with assumptions, open questions, waves, and acceptance criteria.
argument-hint: "[requirements | file path | spec | issue]"
---

# dartclaw-plan

Use this skill to turn requirements into a workflow-safe implementation plan.

## Operating Rules
- Do not pause for human clarification in workflow mode.
- If information is missing, continue with the best supported assumption and label it explicitly.
- Surface uncertainty as structured `ASSUMPTION:` and `OPEN_QUESTION:` annotations instead of hiding it in prose.
- Keep the plan lightweight: enough structure to execute, not a full specification.

## Required Output
- Problem framing and scope boundaries
- Story breakdown with minimal vertical slices
- Dependencies and wave assignments for parallelism
- Acceptance criteria for each story
- Assumptions, open questions, and risks

## Planning Discipline
- Prefer fewer stories that are independently verifiable.
- Keep story text outcome-focused, not implementation-heavy.
- Preserve project terms and naming from the provided context.
- If a story cannot be fully grounded, say what is assumed and what remains unresolved.
