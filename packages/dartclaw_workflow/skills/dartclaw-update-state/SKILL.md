---
name: dartclaw-update-state
description: Update project state using the framework-aware state protocol discovered earlier.
argument-hint: "<project-index | state instruction>"
user-invocable: true
workflow:
  default_prompt: "Update the project's state using the discovered protocol. Project index or state instruction: "
  default_outputs:
    state_update_summary:
      format: text
      schema: state-update-summary
---

# DartClaw Update State

Framework-aware state management for workflows. Consume a normalized project index or explicit state instruction, then update the project's state artifact using the detected convention.

## Instructions

- Use the project index from the `dartclaw-discover-project` skill when available.
- Prefer the framework-specific state protocol over ad hoc heuristics.
- Keep changes minimal and deterministic.
- If the project has no known state protocol, create or update a minimal `STATE.md` in the canonical location.
- Do not invent extra state files.

## Framework Behavior

- **AndThen / GSD**: edit the existing `STATE.md` in place and keep it compact.
- **Spec Kit**: update the relevant task list or spec checklist; state is implicit in task completion.
- **OpenSpec**: move the change directory through the framework lifecycle rather than maintaining a separate state log.
- **BMAD**: update the project instruction files or role boundaries if the workflow explicitly asks for it.
- **none**: create a minimal `STATE.md` with only the fields needed for workflow continuity.

## Minimal STATE.md Contract

When `state_protocol:none`, create or update a minimal state file with:

- current phase
- overall status
- active story or task
- blockers
- short session note
- last updated timestamp

Keep the file short and readable. Avoid turning it into a historical log.

## Method

1. Read the project index and resolve the state protocol.
2. Locate the canonical state target.
3. Apply the smallest valid update for the framework.
4. Preserve existing content that still matches the workflow.
5. Report the exact state target and the update performed.

