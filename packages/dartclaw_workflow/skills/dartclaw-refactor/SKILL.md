---
name: dartclaw-refactor
description: Simplify code while preserving behavior, with baseline verification and Chesterton's Fence discipline.
argument-hint: "<scope/description> | --path <dir/file>"
---

# dartclaw-refactor

Use this skill to improve structure without changing behavior.

## Operating Rules
- Preserve behavior exactly unless the request says otherwise.
- Understand why code exists before removing it.
- Favor readability, explicitness, and deletion over abstraction.
- Keep the refactor bounded to the requested scope.
- Do not widen the scope to nearby cleanup, even if it looks convenient.

## Scope & Baseline
- Determine scope from the path, the description, or the recent diff fallback.
- If no arguments are provided, use `git diff --name-only HEAD~5` to discover the active surface area.
- Establish a passing baseline before editing: tests, linting, and type checks should already be green or have an explained pre-existing failure.
- Record the baseline state so regressions can be separated from old issues.
- If the baseline is red, fix the baseline first or stop and explain why the refactor cannot proceed safely.
- If the scope is ambiguous, reduce it before touching code.
- Keep the verified baseline artifacts close to the refactor scope so they are easy to compare later.

## Analysis
- Look for unnecessary complexity, over-abstraction, duplication, dead code, and naming issues.
- Prefer the simplest change that makes the code easier to understand and change.
- Before removing any code, apply Chesterton's Fence.
- Check callers, tests, and git history to understand why the code exists.
- If the fence still does not make sense after that review, stop and ask before deleting it.
- Use `git diff` to keep the analysis focused on what is actually changing.
- Prefer small dependency-order improvements over large structural rewrites.
- Trace the call path so you know whether a candidate simplification is actually dead.
- Treat existing tests as evidence about intent, not as decoration.
- Prefer deletions that remove repeated logic over new abstractions that hide it.

## Refactoring
- Make changes file-by-file or by a clearly bounded logical unit.
- Use parallel sub-agents only when the changes are independent and the scope will not overlap.
- Keep individual edits small enough to verify immediately.
- Remove dead code only when the analysis shows it is safe.
- Avoid introducing new helpers unless they reduce real maintenance burden.
- Preserve public behavior, signatures, and observable outputs unless the request explicitly changes them.
- Re-run the narrowest useful tests after each logical edit block.
- If a simplification requires a bigger rewrite, split it into smaller steps.
- Leave clear seams if a future cleanup would need a separate review.

## Verification
- Re-run tests and static checks after each meaningful edit group.
- Re-check the baseline assumptions if a change unexpectedly alters behavior.
- Use `dartclaw-review-code` on the touched scope to catch regressions and style drift.
- Confirm the diff still matches the intended refactor and does not contain unrelated cleanup.
- If verification fails, stop and repair the regression before continuing.
- Compare the final diff against the baseline so you can explain every meaningful change.
- If the code review finds a behavioral risk, treat it as a refactor defect, not a cosmetic note.

## Safety Rules
- Do not remove code you do not understand.
- Do not broaden the refactor into adjacent tasks.
- Do not trade simple code for clever code.
- Do not stop at "looks cleaner" if the behavior or tests have not been rechecked.
- If a change risks semantic drift, back out and choose a smaller edit.
- When in doubt, keep the fence and simplify somewhere else.
- Make the smallest change that survives the baseline and verification gates.

## Baseline Notes
- Save the baseline command set before editing.
- Re-run the same commands after refactoring.
- If a new failure appears, decide whether the refactor caused it or exposed a pre-existing issue.

## Fence Checks
- When callers disagree with the intended simplification, trust the callers.
- When tests disagree, trust the tests and re-check the fence.
- When git history shows a revert or follow-up, treat that as a signal to preserve the code until proven otherwise.
- If the remaining evidence is still inconclusive, keep the code and leave a note for future work.

## Diff Hygiene
- Review the final diff for incidental formatting or unrelated edits.
- Keep the diff small enough that the review can focus on the actual structural change.
- Do not mix refactoring with feature work.
- If the change needs more than one conceptual move, split it and verify each move separately.
- Prefer leaving a clearly named seam over forcing a risky deletion.
