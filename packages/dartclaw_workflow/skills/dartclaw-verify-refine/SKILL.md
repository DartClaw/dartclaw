---
description: Verify the current implementation first, apply light cleanup only when the gates pass, then re-verify. Trigger on 'verify this', 'refine this safely', 'validate and clean up this code'.
argument-hint: <scope/description> | --path <dir/file>
workflow:
  default_prompt: "Use $dartclaw-verify-refine to verify the scoped implementation, refine it lightly only if the gates pass, and then re-verify. When the requirements baseline is provided as a workspace path such as `spec_path`, read the authoritative file from disk with file_read before judging coverage."
  default_outputs:
    validation_summary:
      format: text
      schema: validation-summary
    findings_count:
      format: json
      schema: non-negative-integer
      description: Number of remaining issues after validation; 0 means clean.
---

# Verify Then Refine

Run project verification first, stop immediately on gate failures, and only then apply small behavior-preserving cleanup before a final verification pass.

## VARIABLES

ARGUMENTS: $ARGUMENTS

## INSTRUCTIONS

- Preserve exact behavior. This skill is for proof and light cleanup, not redesign.
- Verify first. If analyze, test, format, or build gates fail, report the failures and stop without attempting refinement.
- Keep scope tight to the requested files or changed implementation.
- Refinement is optional and must stay light: simplify, remove tiny duplication, tighten naming, or delete obviously dead local code. Do not restructure subsystems.
- Always emit the structured output block, even when nothing changed.
- If the code is already clean after verification, say so and emit `findings_count: 0`.

### Edge Cases
- If the project has no runnable test surface, skip tests and note that explicitly — do not fail the verification for missing tests alone.

### Workflow Pipeline Role
This skill is the **validation gate** in DartClaw's built-in workflows. It runs after implementation (proving the code works) and after remediation (proving the fixes work). Upstream steps produce code changes; this skill proves the result. The structured output drives entry/exit gates on remediation loops.

## GOTCHAS

- Refining before establishing that the baseline passes
- Treating a failing verification pass as permission for speculative cleanup
- Expanding from local cleanup into architectural refactoring
- Returning prose-only output without the structured output contract

## WORKFLOW

### 1. Resolve Scope

- Use `--path` when present.
- Otherwise use the explicit description to locate the target files.
- If no scope is provided, default to the current change set.

### 2. Verify First

- Run the strongest relevant local checks for the scoped implementation:
  - static analysis / linting
  - tests
  - formatter or compile sanity
  - targeted build/package checks when relevant
- If any verification gate fails:
  - do not refine
  - report the failing checks plainly
  - emit `verdict: FAIL`

### 3. Refine Lightly

- Only if all verification gates passed.
- Apply light simplifications and cleanup inside the scoped files.
- Prefer deleting noise over adding abstraction.
- Keep edits small enough that a second verification pass is cheap.

### 4. Re-Verify

- Re-run the affected checks after refinement.
- If the re-verification fails, report it as a failure.

## Structured Output

- findings_count: <integer>
- verdict: <PASS|FAIL>
- critical_count: <integer>
- high_count: <integer>

Interpretation:
- `findings_count` is the number of unresolved verification or cleanup issues.
- `critical_count` is usually `0` for this skill unless verification exposed a release-blocking failure.
- `high_count` counts remaining must-fix verification failures.
