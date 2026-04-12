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

## Refactoring Flow
- Establish a passing baseline.
- Analyze complexity, duplication, dead code, and naming issues.
- Plan changes in dependency order.
- Apply small, verifiable edits.
- Re-run tests and static checks after meaningful changes.

## Safety Rules
- Do not broaden the scope to nearby cleanup.
- Do not remove code you do not understand.
- Stop if a change risks semantics drift.
