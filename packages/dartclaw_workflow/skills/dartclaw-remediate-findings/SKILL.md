---
name: dartclaw-remediate-findings
description: Revalidate review findings against the current workspace and apply the smallest safe fixes with evidence.
argument-hint: "<review-report-path | report URL>"
---

# dartclaw-remediate-findings

Use this skill to clear actionable review findings without broadening scope.

## Operating Rules
- Treat the review report as input, not authority.
- Recheck every finding against the current workspace before editing anything.
- Classify findings as `RESOLVED`, `PARTIALLY RESOLVED`, `UNRESOLVED`, or `DEFERRED`.
- Prefer minimal fixes over cleanup or refactoring beyond what the finding requires.

## Remediation Discipline
- Triage by severity first.
- Fix critical and high issues first, then medium when they affect correctness or maintainability.
- Keep changes local and readable.
- Add or adjust tests when a finding needs proof-of-work.

## Evidence Requirements
- State why each finding is still valid or no longer applicable.
- Tie each fix to concrete evidence from code, tests, or lints.
- Re-run the smallest useful verification set after each fix group.
- Update workflow state only after the findings are actually closed.
