---
source: plugin/skills/exec-plan/references/execution-discipline.md
---

# Execution Discipline

Shared rules for orchestration and execution skills.


## Stop-the-Line

Borrowed from Toyota. A red **objective gate** — failing build, tests, lint, type-check, stub check, wiring check, task-level `Verify` — is work to finish, not a delivery caveat. Do not advance past a red gate, do not mark `Done` on a broken tree, do not report the broken state as completion.


## Diff Discipline

Keep diffs surgical. Format only the lines you are modifying and avoid opportunistic reformatting of unrelated code. If an edit cascades into whole-function or whole-file formatting churn, revert the cascade and keep only the semantic change unless the FIS explicitly requires a broader formatting pass.


## Gate Classes

Two failure classes with different persistence policies:

| Class | Examples | Policy |
|---|---|---|
| **Objective red gate** | Build, tests, lint, type-check, stub/wiring check, task `Verify` | **Iterate until green.** Fix → re-run → repeat. One-pass limits do **not** apply. |
| **Subjective finding** | Code-review CRITICAL/HIGH, visual-validation findings | **One pass max.** Focused remediation → re-run the relevant review lens → halt with a structured blocker in the step output if findings persist. |

Objective failures have binary answers and converge. Subjective findings drift and thrash — different policies on purpose.


## Real External Blockers

The only legitimate reasons to stop a run with unresolved work:

- Missing credentials or unavailable infrastructure
- Merge conflicts requiring human policy
- Missing or contradictory requirements the skill cannot resolve
- Repeated iteration failure on the *same* issue that resists bounded debugging

Partial sub-agent work, intermediate refactor state, and perceived scope overrun are **not** blockers — they are work to finish.


## Authoritative Status Writes

In orchestrated flows (e.g. `dartclaw-exec-spec` running under the `plan-and-implement` workflow):

- The **executing skill** writes its own story's status authoritatively via `dartclaw-update-state` (plan.md story row, FIS field, FIS checkboxes, `State` active-story).
- **Delegating sub-agents and teammates do NOT additionally call `dartclaw-update-state update-*`** on top of the executing skill — that duplicates writes.
- The **orchestrator** writes cross-story state only (phase transitions, overall status, session notes) plus *repair writes* when an executing-skill write is missing.
- After each delegated story, the orchestrator re-reads the target files to confirm writes landed, and calls `dartclaw-update-state update-*` exactly once if any is missing.
