---
name: dartclaw-validate
description: Validate a completed implementation with build, tests, static analysis, and simplification checks.
user-invocable: true
argument-hint: "[optional scope, package, or validation focus]"
---

# DartClaw Validate

Post-implementation validation for buildability, test health, static analysis, and simplification opportunities.

## VARIABLES
FOCUS: $ARGUMENTS

## INSTRUCTIONS
- Determine the smallest safe validation scope from `FOCUS`, changed files, and current task context.
- Run the strongest available build/package check that fits the scoped change.
- Run existing tests when a test runner exists; if the project has no runnable test surface, record the skip explicitly.
- Run static analysis or linting for the scoped change and capture concrete failures.
- Perform a simplification pass over changed files to identify unnecessary complexity, duplication, dead code, or over-abstraction.
- Keep findings concrete and tied to commands, files, or observable behavior.
- Always return a `## Context Output` JSON object with top-level `findings_count` and `validation_summary`.
- `findings_count` must be an integer, including when all phases pass or some phases are skipped.
- When the calling workflow prompt asks for step-scoped aliases such as `validate.findings_count` or `re-validate.findings_count`, emit those keys verbatim in the same `## Context Output` JSON alongside the top-level values.

## WORKFLOW

### 1. Determine Scope
1. Use explicit `FOCUS` when provided.
2. Otherwise infer the likely scope from pending changes, recent edits, and nearby package boundaries.
3. Choose the narrowest build/test/analyze commands that still validate the changed surface honestly.

Gate: scope is explicit enough to run validation without guesswork.

### 2. Build Check
1. Identify the relevant build or package-validation command.
2. Run it and capture pass/fail plus the high-signal error summary.
3. If no meaningful build step exists for the scope, record that fact instead of inventing one.

### 3. Test Check
1. Detect the available test runner for the scope.
2. Run the targeted suite that best covers the changed behavior.
3. If there is no test infrastructure, mark the phase as skipped and explain why in the summary.

### 4. Static Analysis
1. Run the appropriate analyzer, linter, or type checker for the scope.
2. Capture only actionable failures or warnings.
3. Treat new violations in changed files as findings even when the command exits successfully.

### 5. Simplification Pass
1. Inspect changed files for needless complexity, duplicate logic, dead branches, stand-in logic, or abstractions that do not pay for themselves.
2. Prefer concrete, minimal simplification observations over stylistic preferences.
3. Only count clear improvement opportunities that materially reduce maintenance burden.

### 6. Report
Return:
- phase outcomes for build, tests, static analysis, and simplification
- a concise summary of what passed, failed, or was skipped
- concrete findings with file/command references when applicable

End with:

```json
{
  "findings_count": 0,
  "validation_summary": "Build passed, targeted tests passed, static analysis passed, no simplification findings."
}
```

When issues exist, increment `findings_count` for each concrete failure or simplification finding.
