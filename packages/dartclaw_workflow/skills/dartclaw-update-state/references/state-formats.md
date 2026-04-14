# State Formats

Use these conventions when updating project state.

## Operation Vocabulary

Use the same small set of operations across frameworks so downstream workflows can ask for state updates without inventing new verbs.

- `mark in-progress` — set the active story, task, or change to in-progress
- `mark complete` — mark the active story, task, or change complete
- `add blocker` — record a new blocker or blocked reason
- `add learnings` — append a short learning or session note when the framework supports it
- `update phase` — move the current phase or lifecycle marker forward
- `set overall status` — update the top-level project status such as On Track, At Risk, or Blocked

If a framework does not support one of these operations directly, translate it to the closest native action instead of inventing a new state artifact.

## AndThen

Canonical file: `docs/STATE.md`

Use a compact edit-in-place structure:

```markdown
# Project State

Last Updated: YYYY-MM-DD HH:MM

## Current Phase
Phase: ...
Status: On Track | At Risk | Blocked

## Active Stories
| Story | Status | FIS | Notes |
|-------|--------|-----|-------|
| ... | In Progress | ... | ... |

## Blockers
- ...

## Recent Decisions
- [YYYY-MM-DD] ...

## Session Continuity Notes
- [YYYY-MM-DD] ...
```

## GSD v1

Canonical file: root `STATE.md`

Use the same minimal edit-in-place pattern as AndThen, but respect the root-level project files used by GSD.

## GSD v2

Canonical file: `.gsd/STATE.md`

Update the state file in place and keep `.gsd/DECISIONS.md` append-only when the workflow records a new decision.

## Spec Kit

Canonical state lives in task lists:

- `specs/<id>-<feature>/tasks.md`
- optionally `specs/<id>-<feature>/plan.md`

Mark completed tasks directly in the task list. There is no separate `STATE.md` in the standard model.

## OpenSpec

Canonical state is structural:

- active work stays in `openspec/changes/<change-name>/`
- completed work moves to `openspec/archive/`

Use directory moves rather than a separate state log unless the local project has added one.

## BMAD

There is no universal state file. Prefer the project's role files, instruction files, or explicit workflow notes.

## none

Create a minimal `STATE.md` in the canonical docs root and keep it short. The file exists only to support workflow continuity.
