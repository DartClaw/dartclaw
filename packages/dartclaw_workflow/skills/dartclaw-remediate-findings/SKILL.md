---
description: Use when the user wants review findings or review comments addressed. Implements actionable findings from a review report with minimal, guideline-aligned fixes across code, specs, plans, PRDs, and documentation, then re-validates the result and updates plan/FIS status. Trigger on 'address these review findings', 'fix review comments', 'remediate findings'.
user-invocable: true
argument-hint: <review-report-path | report URL>
---

# Remediate Findings

Implement validated findings from a review report. The goal is to clear real issues with the smallest safe change set across implementation and document artifacts, avoid over-engineering, re-run the right verification, and update workflow state when the reviewed work is now complete.


## VARIABLES

REPORT_SOURCE: $ARGUMENTS


## USAGE

```bash
/remediate-findings docs/specs/feature/feature-gap-review-codex-2026-04-10.md
/remediate-findings https://example.com/reviews/feature-gap-review.md
```


## INSTRUCTIONS

- Make sure `REPORT_SOURCE` is provided; otherwise stop with a missing-input error that states a review report source is required.
- Treat the review report as an input contract, not unquestionable truth. Re-validate findings against the current workspace before editing artifacts.
- Fix validated findings with the smallest coherent patch set that resolves them.
- Avoid scope creep. Do not "clean up nearby code" or rewrite nearby docs unless it is required to resolve a finding or prevent a regression.
- Prefer explicit, local fixes over broad rewrites, reorganizations, helpers, or framework layers.
- If external documentation is needed, use a documentation-lookup specialist when one is available.
- Invoke the `dartclaw-update-state` skill for deterministic plan/FIS/STATE updates instead of hand-editing those artifacts.


## GOTCHAS
- Fixing stale findings already resolved in the current workspace
- Expanding a narrow remediation into a broad refactor
- Marking artifacts done before re-validation passes
- Forcing a speculative edit when the real issue is an unresolved product decision


## WORKFLOW

### Phase 1: Resolve Report and Targets

1. Resolve `REPORT_SOURCE`:
   - Local report path or direct raw report URL: read the report content directly
   - GitHub issue URL or PR comment URL: follow `../references/resolve-github-input.md`. Compatible types: `review`, `gap-review`, `code-review`, `architecture-review`, `doc-review`, `council-review`. All others: stop with invalid-input error stating an actual review artifact is required.
2. Extract:
   - Review type (`review-gap`, `review-code`, `review-doc`, or other)
   - Report verdict (PASS/FAIL) when present
   - Findings, severity, remediation recommendations, and reviewed scope
   - Referenced implementation targets, requirements baseline, FIS path, `plan.md`, and story IDs when available
3. If the input URL does not contain the actual review report content or a valid typed GitHub review artifact, stop with an invalid-input error that states the report itself is required. Do not guess from an issue or PR shell page.
4. If the report has no actionable findings, stop and return that there are no actionable findings.

**Gate**: Actionable findings and the remediation target are explicit


### Phase 2: Re-Validate Findings

For each finding:
- Check whether it is still true in the current workspace
- Classify it as `valid`, `already fixed`, `superseded`, or `unclear`
- Classify the remediation surface as `implementation`, `document`, `workflow-artifact`, or `mixed`
- Keep only currently valid findings in scope

Severity policy:
- **Critical / High**: must fix
- **Medium**: fix when it affects requirements, correctness, maintainability, or report PASS/FAIL
- **Low**: fix only when it is cheap, low-risk, or explicitly requested

If all findings are already fixed or superseded, skip to Phase 5 and only update status artifacts when that is now justified.

**Gate**: Remediation scope is bounded to currently valid findings


### Phase 3: Plan Minimal Remediation

- Group findings by affected area to minimize conflicts and repeated verification
- Define the smallest change set that resolves the validated findings; favor boring, readable fixes over clever abstractions
- Choose the target artifact that owns the defect: code/config/tests for implementation, specs/plans/PRDs for requirements/design, product/user docs for explanation/usage
- If a finding reveals an unresolved product decision or ambiguous source of truth, stop and escalate instead of forcing a speculative edit
- Use parallel sub-agents only for independent fix groups

**Gate**: Minimal remediation plan is clear and bounded


### Phase 4: Implement and Re-Validate

1. Implement fixes by logical area and artifact type. Add or update tests when an implementation finding requires proof-of-work.
2. Run targeted verification after each fix group: tests/linting/type checks/builds for implementation fixes; terminology/cross-references/linked paths/consistency for document fixes; templates/status semantics for workflow artifact fixes.
3. Run final validation: tests/linting/builds when implementation changed, `dartclaw-quick-review` on touched scope, visual validation when UI changed.
4. **Findings re-check**: Walk through every finding from the original report and verify resolution against the current workspace. For each finding, state one of: `RESOLVED` (with evidence), `PARTIALLY RESOLVED` (what remains), `UNRESOLVED` (why), or `DEFERRED` (intentionally left open per severity policy, with justification). This is the primary close-the-loop validation.
5. If both implementation and document artifacts changed, verify the final state is consistent across them.

**Gate**: Every Critical/High finding is RESOLVED with evidence, Medium/Low findings are RESOLVED or DEFERRED with justification, quick-review on touched scope is clean, no new regressions


### Phase 5: Update Workflow State

The findings re-check and re-review results from Phase 4 are the evidence needed to update state. When all required findings are resolved and verification is clean, update state now — do not defer merely because the originating review was not re-run.

If the report is tied to a story or FIS and remediation passed validation: use `dartclaw-update-state update-fis {fis_path} all` when the FIS work is substantively complete, `dartclaw-update-state update-plan {plan_path} {story_id} Done` after confirming plan acceptance criteria, and update the `State` document (see **Project Document Index**) when the story is now complete. Re-read updated artifacts to verify.

If the remediation only fixes document artifacts: update only the workflow artifacts justified by the document remediation. Do not mark implementation complete unless implementation acceptance criteria are also satisfied.

If the report is a full-plan or workspace-wide review: update only status artifacts justified by the completed remediation. Do not mark individual stories done unless their acceptance criteria are clearly satisfied.

**Gate**: Status artifacts reflect the validated post-remediation state


## COMPLETION

Report:
- Findings re-check table (each finding → RESOLVED / PARTIALLY RESOLVED / UNRESOLVED with evidence)
- Findings intentionally left open and why
- Verification results (tests, lints, builds, review-code, review-doc, or other targeted checks as applicable)
- Which workflow artifacts were updated
