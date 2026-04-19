---
description: "The default review skill – start here for all reviews. Runs code, doc, gap, or mixed review with selectable mode. Trigger on 'review this', 'review these changes', 'review this PR', 'review this spec', 'review this PRD', 'audit this', 'does this match the spec'."
user-invocable: true
argument-hint: "[target/files/PR/spec path] [--mode code|doc|gap|mixed] [--inline-findings] [--to-issue] [--to-pr <number>]"
workflow:
  default_prompt: "Use $dartclaw-review to review the provided target and route to the appropriate review mode (code / doc / gap / mixed)."
---

# Review

Unified review skill. Determine what is actually being reviewed, run the right lens inline, and produce one consolidated result.

Code, document, gap, and mixed reviews all run inside this skill using lens-specific references.


## VARIABLES
ARGUMENTS: $ARGUMENTS

### Optional Mode Flags
- `--mode code|doc|gap|mixed` → force the review lens. Absent → auto-detect per the routing heuristics in Step 2
- `--inline-findings` → return findings inline and skip report-file output. **Do not pass** when the caller depends on a report file (e.g. the `plan-and-implement` workflow skill's final gap gate, which feeds the `dartclaw-remediate-findings` skill).
- `--to-issue` → publish the consolidated report to a GitHub issue
- `--to-pr <number>` → publish the consolidated report to a PR comment


## INSTRUCTIONS

- Read the Workflow Rules, Guardrails, and relevant project guidelines before starting.
- Read-only analysis. Do not modify the reviewed artifacts.
- Default to the minimum correct lens for the target.
- One lens per call (except **Mixed**, which intentionally runs both doc and code lenses).
- Load the lens-specific reference before running the lens — it carries the rubric, calibration pointers, and report format.
- Use the unified severity scale and per-mode verdict definitions from `../references/review-verdict.md`.
- **Calibration-first**: Always load `../references/review-calibration.md` (universal) plus the lens-specific calibration (cited by each lens reference) before categorising findings.


## GOTCHAS
- Treating all review requests as code review
- Running `--mode gap` without a real requirements baseline
- Running `--mode mixed` when the real question is requirements fit — use `--mode gap` instead
- Passing `--inline-findings` when the caller will consume a report file (breaks the `dartclaw-remediate-findings` skill)
- Forgetting that the `dartclaw-remediate-findings` skill reads the canonical PASS/FAIL verdict block from gap reports — don't re-label, re-phrase, or re-order its columns


## WORKFLOW

### 1. Resolve Target and Context

Determine what the user wants reviewed, in priority order:
1. Explicit path, PR, issue, URL, or focus from `ARGUMENTS`
2. Explicit `--mode` flag
3. Current pending changes (`git diff --stat`, `git diff --name-only`) when no target is provided
4. Neighboring artifacts that clarify intent: plan/FIS/PRD/spec docs, changed implementation files, related issue/PR context

Apply an explicit `--mode` flag during discovery, not only during later classification:
- `--mode doc`: when no explicit target is provided, restrict discovery to changed document artifacts (spec/FIS/PRD/plan/ADR/design/prompt/docs) and ignore changed implementation files as primary review targets; if no document targets are found, stop and report that doc mode has no matching scope
- `--mode code`: when no explicit target is provided, restrict discovery to changed implementation/config/test files and ignore changed docs as primary review targets; if no implementation targets are found, stop and report that code mode has no matching scope
- `--mode gap`: when no explicit target is provided, resolve both a requirements baseline and an implementation target from the current changes plus neighboring artifacts; if either side cannot be resolved, stop and report that the missing side is required for gap review
- `--mode mixed`: resolve both a document target (for the doc sub-pass) and an implementation target (for the code sub-pass); if either side cannot be resolved, stop and report the missing side

When no explicit target is provided and no mode flag narrows the scope, build the target map from the dirty worktree by separating:
- changed document artifacts
- changed implementation artifacts
- nearby requirements artifacts that may serve as baselines

Use nearby requirements artifacts to clarify context, not to override explicit review intent.

Build a concise target map:
- **Review target**
- **Relevant artifacts**
- **Implementation scope** if any
- **Requirements baseline** if any
- **User intent**: code quality, doc readiness, requirements fit, or broad audit

**Gate**: Review target and available context are explicit


### 2. Classify the Review Surface

Choose one mode:
- **code**: implementation, config, tests, or current code changes
- **doc**: spec, FIS, PRD, plan, ADR, design doc, prompt, or other written artifact
- **gap**: requirements baseline plus implementation target, where the real question is "does this implementation satisfy the requirements?"
- **mixed**: both document artifacts and implementation artifacts are independently in scope and each needs its own review lens; this dispatches to **doc + code**, not to **gap**

Routing heuristics when `--mode` is absent:
- If the user explicitly asks whether implementation matches a spec, plan, PRD, issue, or requirements baseline, use **gap**
- If the user says "review implementation of [doc]" or similar phrasing where a requirements document is the object of "implementation of", treat [doc] as the requirements baseline and route to **gap** — the intent is requirements-fit validation, not a document review
- If the user explicitly asks for PR review, code review, change review, or an implementation audit, prefer **code** unless they also clearly ask for requirements-fit validation
- If only docs changed, default to **doc**
- If the target is a spec/FIS/PRD/plan path and no implementation target is explicit, default to **doc**
- If only implementation changed, default to **code**
- If there is a clear requirements baseline plus implementation scope and the user's core question is requirements fit, default to **gap**
- If both docs and code changed:
  - Use **gap** when the docs are acting as the requirements baseline for the implementation and the core question is whether the implementation matches them
  - Use **mixed** when the docs themselves need readiness review and the implementation also needs independent code review
- The mere presence of neighboring PRD/FIS/plan/spec artifacts is not enough to force **gap**. Nearby requirements docs provide context; they become the primary lens only when the user's question is actually requirements-vs-implementation fit

**Gate**: Review mode is selected and justified


### 3. Run the Selected Lens

Load the lens reference for the selected mode and run the lens inline. The reference carries the rubric, dimensions, calibration pointers, and report format:

| Mode | Lens reference |
|------|----------------|
| code | `../dartclaw-review/references/lens-code.md` |
| doc | `../dartclaw-review/references/lens-doc.md` |
| gap | `../dartclaw-review/references/lens-gap.md` |
| mixed | **doc sub-pass**: `lens-doc.md`; **code sub-pass**: `lens-code.md` (run both; see below) |

Unified severity and verdict: `../references/review-verdict.md` — CRITICAL / HIGH / MEDIUM / LOW; per-mode readiness/verdict rules defined there.

**Mixed mode**: run the doc sub-pass first, then the code sub-pass. Keep findings in distinct subsections in the final report. Overall readiness = worst of the two sub-modes (per `review-verdict.md`).

**Code mode** orchestration: when sub-agents are supported and the scope is broad, delegate parallel reviewers per `lens-code.md` (code quality, security, architecture, domain language, UI/UX). Otherwise run the lenses sequentially inline.

**Gate**: Primary lens complete


### 4. Synthesize One Final Result

Produce one final review output. Include:
- **Scope**
- **Review mode used**: code / doc / gap / mixed
- **Findings by severity** using the unified scale (CRITICAL / HIGH / MEDIUM / LOW)
- **Readiness / verdict** per `../references/review-verdict.md`:
  - `code`: severity counts + readiness label (`Ready` / `Needs Fixes` / `Blocked`)
  - `doc`: readiness label (`Ready` / `Needs Minor Updates` / `Needs Significant Rework` / `Not Ready`)
  - `gap`: PASS/FAIL verdict table (byte-level compatible — reproduce the canonical block verbatim)
  - `mixed`: per-sub-mode verdicts + overall readiness = worst of the two
- **Recommended next action**

Output conventions:
- If `--inline-findings` is present, present one consolidated inline result and state the mode(s) run. Do not write a report file.
- Otherwise, write one consolidated markdown report and follow `../references/report-output-conventions.md`:
  - **Report suffix**: `review` (for `mixed`) or the per-lens suffix from each lens reference (`code-review` / `doc-review` / `gap-review`) when running a single mode — whichever the consuming pipeline expects. Default to `review` for the unified mixed output.
  - **Scope placeholder**: `review-target`
  - **Spec-directory rule**: use the feature/spec directory when the review centers on a spec/FIS/plan
  - **Target-directory rule**: otherwise store next to the primary review target

For GitHub publishing (`--to-issue` / `--to-pr`):
- Publish the consolidated report with `artifact_type` matching the mode (`code-review` / `doc-review` / `gap-review` / `review`)
- Populate metadata with `report_path`, `plan_path`, `fis_path`, `requirements_baseline`, and `implementation_targets` when known
- The mode must be visible in the report summary so downstream remediation can interpret the findings correctly

For **Mixed** reviews, keep findings from the doc and code sub-passes in distinct subsections. Merge overlapping findings and use the strongest framing as canonical.

**Gate**: One consolidated result delivered


## FOLLOW-UP ACTIONS

After the report, ask whether the user wants to:
1. Update the reviewed artifact based on findings
2. Focus on a narrower area
3. Proceed to implementation
4. Escalate critical issues for clarification
5. For FAIL / `Needs Significant Rework` / `Not Ready` / CRITICAL outcomes — run the `dartclaw-remediate-findings` skill with the report path or URL
