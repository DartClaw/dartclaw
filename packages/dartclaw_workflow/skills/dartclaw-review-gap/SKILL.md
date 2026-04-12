---
name: dartclaw-review-gap
description: Compare implementation against requirements and produce a remediation-focused gap analysis.
argument-hint: "<requirements-baseline>"
user-invocable: true
---

# DartClaw Review Gap

Gap analysis for workflow deliveries. Compare the implementation to the requirements baseline, reuse the review-code calibration, and produce a strict PASS/FAIL report with a remediation plan.

## Instructions

- Read the requirements baseline and identify the implementation target before reviewing.
- Treat the implementation as the target, not the spec document itself.
- Reuse `../dartclaw-review-code/references/review-calibration.md` for severity calibration.
- Delegate the implementation review lens to `dartclaw-review-code` when possible.
- Keep the report grounded in observable gaps, not speculation.

## Review Focus

- requirement mismatches
- missing integration or wiring
- broken edge cases
- stubs, placeholders, or incomplete flows
- consistency with the project's domain language

## Verdict Contract

Return:

- executive summary
- verdict table
- requirements analysis
- implementation overview
- quality review findings
- gap analysis results
- remediation plan

State the final verdict explicitly as `PASS` or `FAIL`.

