---
name: dartclaw-remediate-findings
description: Revalidate review findings against the current workspace and apply the smallest safe fixes with evidence.
argument-hint: "<review-report-path | report URL | GitHub issue/comment URL>"
---

# dartclaw-remediate-findings

Use this skill to close actionable review findings without broadening scope.

## Operating Rules
- Treat the review report as input, not authority.
- Recheck every finding against the current workspace before editing anything.
- Classify every finding as `RESOLVED`, `PARTIALLY RESOLVED`, `UNRESOLVED`, or `DEFERRED`.
- Prefer minimal fixes over cleanup or refactoring beyond what the finding requires.
- Do not rely on legacy ops helpers or temporary artifact mirrors; update workflow state through `dartclaw-update-state` when the work is actually complete.

## Phase Workflow

### Resolve Report
- Identify the report source, reviewed scope, target files, and claimed findings.
- Separate actionable findings from commentary, suggestions, and non-goals.
- Read the report in the context of the current workspace state.
- Note any stale claims before touching code.
- If the report is missing required context, stop and call that out explicitly instead of guessing.
- Keep the remediation target narrow enough that the same review can be re-run cleanly.

### Re-Validate
- Recheck each finding against the current workspace and record concrete evidence.
- Decide whether the finding is still valid, already closed, partially closed, or intentionally deferred.
- Reassess severity based on impact, blast radius, and current behavior.
- Critical and High findings remain must-fix unless the report is stale or the finding is disproven.
- If a finding is no longer reproducible, explain the evidence that invalidated it.
- If a finding is only partly fixed, state the remaining user-visible or correctness risk.

### Plan Minimal Remediation
- Group only related findings so fixes stay local and easy to verify.
- Keep the patch set as small as possible while still fully addressing the valid findings.
- Prefer explicit edits over new abstractions, helper layers, or cleanup work.
- If the issue is really a requirements or spec defect, escalate that mismatch instead of papering over it in code.
- Favor one targeted fix per finding cluster over a broad "fix everything nearby" pass.
- Use the smallest test additions that still prove the behavior change.

### Implement
- Apply the smallest safe fix for each validated finding.
- Add or adjust tests when a finding needs proof-of-work.
- Keep the implementation readable and close to the current style.
- Run the narrowest verification set that proves the fix.
- Re-run the affected test subset before moving on to the next group.
- Do not continue editing once the finding is resolved just because a surrounding cleanup is tempting.

### Update State
- When the required findings are closed, update workflow state through `dartclaw-update-state`.
- Record why each finding is resolved, partially resolved, deferred, or unresolved.
- Re-read any updated artifacts if state files changed.
- Treat the state update as part of the remediation, not a postscript.
- If the artifact is not stateful, document that no state update was needed.

## Finding Status Semantics
- `RESOLVED`: the finding is no longer observable and the evidence is in the workspace.
- `PARTIALLY RESOLVED`: part of the impact is fixed, but a meaningful remainder still exists.
- `UNRESOLVED`: the finding is still valid and still needs work.
- `DEFERRED`: the finding is intentionally left open with a clear justification.
- Do not mark a finding resolved unless the code, tests, or lint output prove it.
- Do not mark a finding deferred just because it is inconvenient.

## Severity Policy
- Critical and High findings must be fixed unless the report is stale or the finding is disproven.
- Medium findings should be fixed when they affect correctness, maintainability, or the report verdict.
- Low findings are optional unless they are cheap, clearly useful, or explicitly requested.
- Do not convert one validated finding into broad cleanup.
- Do not let a low-severity label hide a correctness issue.

## Remediation Loop
- Run at most 2 remediation cycles.
- Cycle 1: re-validate, implement, and verify the valid findings.
- Cycle 2: only if new evidence, a regression, or a stale assumption changes the status.
- If the work still does not converge after 2 cycles, stop and report the blocker.
- Do not keep iterating past the bound in search of a perfect score.

## Evidence Requirements
- Tie every status decision to code, tests, or lints.
- Explain why each finding changed status.
- Re-run the smallest useful verification set after each fix group.
- Prefer proof that the reported problem is gone over broad validation that is unrelated to the finding.
- If a finding disappears because the report was stale, say so explicitly.
- When evidence is mixed, keep the stricter status and describe the residual risk.
- Never promote a finding to `RESOLVED` based only on intent or a planned follow-up.
- If the remaining evidence is ambiguous, keep the finding open.
- A clean status needs a concrete workspace signal, not a promise.
