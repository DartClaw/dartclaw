---
name: dartclaw-review-gap
description: Compare implementation against requirements and produce a remediation-focused gap analysis.
argument-hint: "<requirements-baseline>"
user-invocable: true
---

# dartclaw-review-gap

Use this skill to compare an implementation against a requirements baseline, identify observable gaps, and return a strict PASS or FAIL verdict with a remediation plan.

## Operating Rules
- Read the requirements baseline and identify the implementation target before reviewing.
- Treat the implementation as the target, not the spec document itself.
- Reuse `../dartclaw-review-code/references/review-calibration.md` for severity calibration.
- Delegate the implementation review lens to `dartclaw-review-code` when possible.
- Keep conclusions grounded in observable evidence, not speculation.

## Requirements Discovery
- When the input is a directory, search the directory and its parent for sibling `prd.md`, `plan.md`, and FIS files.
- When the input is a plan file, extract all FIS paths from the Story Catalog table and the Phase Breakdown sections.
- When the input is a specific file, review that file as the baseline and note the narrower scope.
- When no sibling files are found, proceed with the single input and call out the limited baseline in the report.
- Identify the implementation target paths before quality review begins.

## Workflow

### 1. Resolve Target
- Determine the requirements baseline and the implementation target.
- Explicitly map which files or directories are being compared.
- Stop if there is still no implementation target to evaluate.

### 2. Compile Requirements
- Build a concise view of expected behavior, constraints, success criteria, and non-functional requirements.
- Confirm any external technical claims against authoritative sources when needed.
- Preserve direct quotes only when they are needed to pin down a requirement.

### 3. Inspect Implementation
- Inventory the relevant implementation files and affected components.
- Understand the codebase structure, integration points, and current patterns.
- Scan for stubs, placeholders, partial flows, and missing wiring.

### 4. Quality Review
- Review solution quality and gather evidence before gap scoring.
- Run checks that matter here: static analysis, linting, type checks, and tests when applicable.
- Delegate a focused implementation review to `dartclaw-review-code`.
- Use `../dartclaw-review-code/references/review-calibration.md` to calibrate severity and reduce leniency drift.

## Evidence Requirements
- Record the smallest file set that proves each gap.
- Prefer exact lines, explicit symbols, and concrete runtime behavior over broad summaries.
- If a gap cannot be demonstrated from the implementation, downgrade it or withdraw it during challenge.
- Separate missing capability from incomplete wiring so the remediation plan can target the right fix.
- Keep note of any verification command that failed and what it failed to prove.

### 5. Gap Analysis
Record findings in these six gap categories:
- Functionality
- Integration
- Requirement mismatches
- Consistency
- Domain language
- Verification depth

### 6. Adversarial Challenge
- Challenge the findings using `../references/adversarial-challenge.md`.
- Use the generic findings-challenger template with the implementation target context.
- Include the review-code calibration reference in the challenge context.
- Filter out findings that are downgraded or withdrawn before scoring.

### 7. Dimensional Scoring & Verdict

| Dimension | Threshold | Scoring Guide |
|-----------|-----------|---------------|
| Functionality | >= 7 | 10: all required behavior works; 7: core behavior works with minor gaps; 4: major paths broken; 1: does not function |
| Completeness | >= 9 | 10: no stubs, placeholders, or missing features; 9: only trivial gaps; 7: meaningful missing pieces remain; 1: mostly incomplete |
| Wiring | >= 8 | 10: all critical paths are wired end to end; 8: critical paths work with minor integration gaps; 5: some components are disconnected; 1: major wiring is absent |

**Verdict rule**: any dimension is below threshold: **FAIL**

**Verdict rule**: all dimensions meet or exceed threshold: **PASS**

**Verdict rule**: no conditional verdicts

## Severity Notes
- Use the calibration file to avoid inflating minor omissions into high-severity findings.
- Treat obvious stubs, missing wiring, and broken core flows as stronger evidence than stylistic concerns.
- When a gap spans more than one category, record it once and note the secondary effect rather than duplicating the finding.
- Keep the scoring table aligned with the written verdict so the report is internally consistent.

#### Verdict Table Markdown Format
```markdown
| Dimension | Score | Threshold | Status |
|-----------|-------|-----------|--------|
| Functionality | X/10 | >= 7 | PASS/FAIL |
| Completeness | X/10 | >= 9 | PASS/FAIL |
| Wiring | X/10 | >= 8 | PASS/FAIL |
| Overall | PASS/FAIL | - | Final verdict |
```

### 8. Report
Write a markdown report with these sections:
- Executive Summary
- Requirements Analysis
- Implementation Overview
- Quality Review Findings
- Over-Engineering Analysis
- Gap Analysis Results
- Remediation Plan
- Appendix when needed

The Executive Summary must include the verdict table and a short statement of the final verdict.

## Gap Review Focus
- Missing functionality
- Missing integration or wiring
- Requirement mismatches
- Inconsistent behavior or naming
- Domain language drift
- Weak verification depth or unproven behavior

## Report Discipline
- Keep the report grounded in concrete file paths, line references, and observable behavior.
- Use the calibration file to separate real issues from low-signal noise.
- If the review scope is limited, say so explicitly.
- Avoid any GitHub publishing workflow in this skill.
- Call out remediation dependencies in the same order they should be fixed.
- Prefer one crisp finding per gap instead of compound prose that hides the root cause.
- If a gap is borderline, explain why the threshold is not met rather than hedging.

## Completion Protocol
- State the final verdict explicitly as PASS or FAIL.
- Include the dimensional scores and the verdict table in the final report.
- Include a remediation plan for every non-trivial gap.
- If no implementation target or requirements baseline can be established, report that as a blocking gap.
