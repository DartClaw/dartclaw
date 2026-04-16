---
description: Unified review entrypoint that inspects the current changes or given input, then routes to code review, document review, or gap analysis and produces one consolidated result. Trigger on 'review this', 'review these changes', 'review this PR', 'audit this', 'does this match the spec'.
user-invocable: true
argument-hint: "[target/files/PR/spec path] [--deep] [--code-only] [--doc-only] [--gap-only] [--to-issue] [--to-pr <number>]"
---

# Review

Unified review entrypoint. Determine what is actually being reviewed, run the minimum correct review stack, and produce one consolidated result.

Use this as the default review skill. Reach for `dartclaw-review-code`, `dartclaw-review-doc`, or `dartclaw-review-gap` only when you explicitly need that specialist path.

## VARIABLES
ARGUMENTS: $ARGUMENTS

### Optional Mode Flags
- `--deep` → prefer more thorough review depth on implementation-facing reviews
- `--code-only` → force implementation/code review
- `--doc-only` → force document review
- `--gap-only` → force requirements-vs-implementation review
- `--to-issue` → publish the final report to GitHub issue when a single delegated review owns publishing, or publish the consolidated report if this skill writes it
- `--to-pr <number>` → publish the final report to a PR comment when a single delegated review owns publishing, or publish the consolidated report if this skill writes it

## INSTRUCTIONS
- Read-only analysis. Do not modify the reviewed artifacts.
- Default to the minimum sufficient review stack. More reviewers and more review types are only better when they improve signal.
- Own the final synthesis. If you delegate to specialist review skills, gather their results and present one clear conclusion rather than dumping disconnected outputs.
- Preserve clean boundaries: `review-code` for implementation, `review-doc` for requirements/design artifacts, and `review-gap` for implementation-vs-requirements comparison.

## GOTCHAS
- Treating all review requests as code review
- Running `review-gap` without a real requirements baseline
- Running both `review-doc` and `review-gap` when `review-gap` already covers the real question
- Letting delegated skills each write their own report file when this skill should own the combined output

## WORKFLOW

### 1. Resolve Target and Context

Determine what the user wants reviewed, in priority order:
1. Explicit path, PR, issue, URL, or focus from `ARGUMENTS`
2. Explicit mode flags (`--code-only`, `--doc-only`, `--gap-only`)
3. Current pending changes (`git diff --stat`, `git diff --name-only`) when no target is provided
4. Neighboring artifacts that clarify intent: plan/FIS/PRD/spec docs, changed implementation files, related issue/PR context

Apply explicit mode flags during discovery, not only during later classification:
- `--doc-only`: restrict discovery to changed document artifacts; stop if none found
- `--code-only`: restrict discovery to changed implementation/config/test files; stop if none found
- `--gap-only`: resolve both a requirements baseline and implementation target; stop if either side cannot be resolved

When no explicit target and no mode flag, build the target map from the dirty worktree by separating changed document artifacts, changed implementation artifacts, and nearby requirements artifacts. Nearby requirements artifacts clarify context but do not override explicit review intent.

Target map fields: **Review target**, **Relevant artifacts**, **Implementation scope** (if any), **Requirements baseline** (if any), **User intent** (code quality, doc readiness, requirements fit, broad audit, or deep review).

**Gate**: Review target and available context are explicit

### 2. Classify the Review Surface

Choose one of these modes:
- **Code**: implementation, config, tests, or current code changes
- **Doc**: spec, FIS, PRD, plan, ADR, design doc, prompt, or other written artifact
- **Gap**: requirements baseline + implementation target; core question is “does this satisfy the requirements?”
- **Mixed**: both doc and implementation artifacts independently in scope, dispatches to `Doc + Code` (not `Gap`)

`Mixed` is a final classification. Keep it through stack selection and synthesis unless explicitly reclassified as **Gap**.

Routing heuristics:
- Explicit mode flags override inference
- User asks whether implementation matches requirements → **Gap**
- User asks for PR/code/change review or implementation audit → **Code** (unless they also ask for requirements-fit)
- Only docs changed, or target is a spec/FIS/PRD/plan path without explicit implementation target → **Doc**
- Only implementation changed → **Code**
- Clear requirements baseline + implementation scope and core question is requirements fit → **Gap**
- Both docs and code changed: **Gap** when docs are the requirements baseline and question is implementation fit; **Mixed** when docs need readiness review and implementation needs independent code review
- Nearby PRD/FIS/plan/spec artifacts provide context but do not force **Gap** unless the user's question is actually requirements-vs-implementation fit

**Gate**: Review mode is selected and justified

### 3. Select the Review Stack

Run the minimum correct stack:
- **Code** → `dartclaw-review-code`
- **Doc** → `dartclaw-review-doc`
- **Gap** → `dartclaw-review-gap`
- **Mixed** → `dartclaw-review-doc` + `dartclaw-review-code`

Mixed-mode rule: use only when there are two independent review surfaces (document readiness + implementation quality). Not a synonym for uncertainty between Doc and Gap. If the real question is requirements fit, classify as **Gap**. Once selected, keep **Mixed** through execution and final reporting.

When delegating: instruct specialists to return findings inline (no separate report files). `review-gap` also returns PASS/FAIL verdict inline. This skill owns all file-writing and GitHub publishing.

**Gate**: Review stack is proportional to the review surface

### 4. Execute Delegated Reviews

Run the selected specialist reviews using sub-agents when supported. Each specialist returns its domain findings: `review-code` (implementation), `review-doc` (document readiness), `review-gap` (requirements fit + verdict + remediation priorities). If a delegated review cannot run, fall back to direct analysis using the same lens and note the fallback.

**Gate**: All selected review passes complete

### 5. Synthesize One Final Result

Produce one final review output. Include:
- **Scope**
- **Review mode used**: Code / Doc / Gap / Mixed
- **Review stack run**
- **Findings by severity**
- **Gap verdict** when `review-gap` ran
- **Recommended next action**

Output conventions:
- No file needed: present one consolidated inline result stating which sub-review(s) ran
- Report file or GitHub publishing: write one consolidated markdown report per `../references/report-output-conventions.md` (suffix: `review`, scope: `review-target`, spec-directory rule for spec/FIS/plan reviews, target-directory rule otherwise)

For GitHub publishing: publish as `artifact_type: review` with metadata (`report_path`, `plan_path`, `fis_path`, `requirements_baseline`, `implementation_targets` when known). Mention the review mode prominently when doc-only, code-only, or gap-only.

For **Mixed** reviews: keep doc-readiness and implementation-quality findings in distinct subsections. Merge duplicate findings, using the strongest framing as canonical.
