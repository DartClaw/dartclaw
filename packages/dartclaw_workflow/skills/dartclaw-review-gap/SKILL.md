---
description: "Use when you explicitly want requirements-vs-implementation review rather than the general `review` router: compare the current implementation against a spec, PRD, or plan and produce remediation guidance. Trigger on 'gap analysis', 'review against the spec', 'compare implementation to the plan', 'compare implementation to the PRD'."
argument-hint: "[Requirements baseline: plan/spec/PRD/issue/directory/URL] [--inline-findings] [--to-issue] [--to-pr <number>]"
---

# Gap Analysis

Compare the current implementation in the workspace against requirements, then produce a remediation-focused report. The target is always the implementation, not the requirements document itself.

Most users should start with the `dartclaw-review` skill. Use this skill directly when the question is explicitly whether an implementation matches its requirements baseline.

## VARIABLES
ADDITIONAL_CONTEXT: $ARGUMENTS

### Optional Output Flags
- `--inline-findings` → return findings and PASS/FAIL verdict inline and skip report-file output (for delegated use by the `dartclaw-review` skill)
- `--to-issue` → PUBLISH_ISSUE
- `--to-pr <number>` → PUBLISH_PR

## INSTRUCTIONS
- Read-only analysis. The only file you write is the report.
- If `--inline-findings` is present, do not write a report file. Return findings plus verdict inline to the parent skill instead.
- Calibrate severity with `../references/review-calibration.md` and `../dartclaw-review-code/references/code-review-calibration.md`.
- Default to workspace-wide resolution when requirements and implementation may live in different repos.


## GOTCHAS
- Reviewing the wrong implementation target
- Treating the requirements document as the review target
- Losing the PASS/FAIL contract by writing a hand-wavy conclusion
- Using only the provided input as requirements when sibling PRD/plan/FIS files exist — always run discovery

### Helper Scripts
- `../scripts/check-stubs.sh <path>`
- `../scripts/check-wiring.sh <path>`
- `../scripts/run-security-scan.sh <path>`

## WORKFLOW

### 0. Resolve Review Target

#### Requirements Discovery
When `ADDITIONAL_CONTEXT` is a directory path or a plan file, discover the full requirements baseline rather than treating the single input as the only source.

**GitHub issue or URL** — follow `../references/resolve-github-input.md`. Compatible types: `plan-bundle` (extract and continue as directory/plan input), `fis-bundle` (extract and continue as specific FIS input). Route: `*-review` → invoke the `dartclaw-remediate-findings` skill; other typed → stop with redirect. Untyped: use as-is without further discovery.

**Directory path** — search the directory (and its parent, for cases where a subdirectory like `fis/` is given) for:
- `plan.md` — the implementation plan with story breakdown
- `prd.md` — the product requirements document
- FIS/spec files (`s01-*.md`, `s02-*.md`, etc.) co-located with the plan
- Also check the Project Document Index in the project `CLAUDE.md` for additional pointers

**Plan file** — read the plan and extract related requirements:
- Look for a sibling `prd.md` in the same directory
- Extract FIS file paths from the **Story Catalog** table (`FIS` column) and from `**FIS**:` fields in Phase Breakdown sections — these are typically relative paths in the same directory or under a `fis/` subdirectory
- Read all referenced FIS files that exist on disk (skip entries marked `–` or not yet created)

**Any other input** (specific file, issue, URL) — use as-is without further discovery.

#### State
- **Requirements baselines**: all discovered files, issues, PRDs, plans, or URLs that define expected behavior
- **Implementation target**: repo(s), package(s), directories, or changed files that contain the implementation
- **Mapping rationale**: why those paths are the right implementation target

If no implementation target exists yet, stop and report that gap analysis cannot run.

**Gate**: Requirements sources and implementation target are explicit

### 1. Compile Requirements
Gather the requirements baseline from docs, issues, comments, and `ADDITIONAL_CONTEXT`. Build a concise view of expected behavior, success criteria, constraints, and non-functional requirements. Verify external technical claims against authoritative docs when needed.

**Gate**: Requirements are understood

### 2. Inspect Current Implementation
Map the current implementation state:
- Identify relevant changed files and implementation inventory
- Understand codebase structure, affected components, and existing patterns
- Stop if there is still nothing implemented to compare

**Gate**: Implementation state is understood

### 3. Quality Review
Review solution quality and gather evidence:
- Run project checks directly: static analysis, linting, type checks, tests when applicable
- Scan for stubs/placeholders using `check-stubs.sh`
- Check substance and wiring using `../references/verification-patterns.md` and `check-wiring.sh`

**Gate**: Quality review complete

### 4. Gap Analysis
Record gaps in these categories:
- **Functionality**
- **Integration**
- **Requirement mismatches**
- **Consistency**
- **Domain language** when the `Ubiquitous Language` document (see **Project Document Index**) exists
- **Holistic sanity check**
- **Verification depth**: substance, wiring, and failing verification signals

### 5. Optional Retrospective
If it adds value, reflect on architectural trade-offs, simpler alternatives, process failures, and recurring knowledge gaps.

### 6. Adversarial Challenge
Only spawn the adversarial challenger when any finding is Critical OR total findings exceed 5. Otherwise apply an inline self-check: re-read each finding against the calibration examples and adjust severity. Note when the full challenge was skipped.

When spawning, use `../references/adversarial-challenge.md` (`Generic Findings-Challenger Template`) with:
- **Role**: `Adversarial Challenger reviewing gap analysis findings`
- **Shared calibration**: `../references/review-calibration.md` + `../dartclaw-review-code/references/code-review-calibration.md`
- **Context block**: `Review target context: {implementation target paths from Step 0}`
- **Questions**: (1) Real gap or acceptable in context? (2) Severity justified per calibration? (3) Existing mitigation missed? (4) Would a senior engineer flag this?
- **Verdicts**: `VALIDATED`, `DOWNGRADED`, `WITHDRAWN`
- **Optional extra rules**: `Normalize review-code severities as CRITICAL -> Critical, HIGH -> High, SUGGESTIONS -> Medium.`
- **Findings payload**: all findings from quality review, gap analysis, and optional retrospective

Apply verdicts before scoring.

**Gate**: Findings challenged and filtered

### 7. Dimensional Scoring & Verdict

| Dimension | Question | Threshold | Scoring Guide |
|-----------|----------|-----------|---------------|
| **Functionality** | Does it work correctly for specified requirements? | >= 7 | 10: all requirements met, edge cases handled. 7: core happy path works, minor gaps. 4: major functionality broken. 1: does not function. |
| **Completeness** | Are there stubs, TODOs, placeholders, or missing features? | >= 9 | 10: no stubs/TODOs, all features present. 9: trivial TODOs only. 7: non-critical features stubbed. 4: significant features missing. 1: mostly stubs. |
| **Wiring** | Is everything connected end-to-end? | >= 8 | 10: all components wired, verified via build/tests. 8: all critical paths wired, minor integration gaps. 5: some components exist but are not connected. 2: significant unwired code. |

**Verdict rules**
- If any dimension is below threshold: **FAIL**
- If all dimensions meet threshold: **PASS**
- No conditional verdicts

Include the verdict table (Dimension / Score / Threshold / Status rows for each dimension, plus Overall PASS/FAIL) in the Executive Summary.

## Structured Output

- findings_count: <integer>
- verdict: <PASS|FAIL>
- critical_count: <integer>
- high_count: <integer>

Use the final challenged findings set for these counts. Emit the block for both inline and report-backed runs.

### 8. Report
Write a markdown report with the following sections unless `--inline-findings` is present. When `--inline-findings` is present, return the same content inline in concise structured form, including the PASS/FAIL verdict and prioritized remediation guidance.

Standard report sections: Executive Summary, Requirements Analysis, Implementation Overview, Quality Review Findings, Over-Engineering Analysis, Gap Analysis Results, Retrospective & Reflection (when used), Remediation Plan (Critical/High/Medium/Low with dependencies, sequencing, acceptance criteria), Appendix (when needed).

**Report output conventions**: Follow `../references/report-output-conventions.md` with:
- **Report suffix**: `gap-review` / **Scope placeholder**: `feature-name`
- **Spec-directory rule**: requirements baseline is in a spec directory, or the feature has an associated spec directory from the Project Document Index
- **Target-directory rule**: implementation is localized to a specific directory, so report belongs next to the primary implementation target

If notable recurring traps emerge, append them to an existing learnings file.

#### Publish to GitHub
If PUBLISH_ISSUE is `true`: follow the GitHub publishing flow in `../references/report-output-conventions.md` with title template `[Review] {scope}: Gap Analysis Report`. Print the issue URL.

If PUBLISH_PR is set: follow the GitHub publishing flow in `../references/report-output-conventions.md`, publishing as a typed PR comment. If the posting command does not return a direct comment URL, resolve it via follow-up GitHub lookup. Print the direct comment URL.
