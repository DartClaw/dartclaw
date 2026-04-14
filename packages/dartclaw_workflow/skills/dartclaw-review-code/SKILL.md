---
name: dartclaw-review-code
description: Perform a structured DartClaw review with code quality, security, architecture, domain language, and optional UI/UX lenses.
argument-hint: "[scope/files]"
user-invocable: true
---

# DartClaw Review Code

Structured, evidence-based code review for DartClaw work. Analysis only. Do not modify files.

## Scope

- Start by defining the exact review scope: files, package, route, workflow, or change set.
- Read the project instructions, nearby implementation, and any relevant ADRs or guidance before evaluating findings.
- Exclude generated assets, vendored code, lockfiles, and other noise unless the review explicitly depends on them.
- Calibrate candidate findings against `references/review-calibration.md` before assigning severity.
- Use `../references/verification-patterns.md` when judging whether something merely exists or is actually substantive, wired, and functional.
- Treat the review as a proof exercise, not a preference exercise.

## Review

Follow this gate-structured workflow in order:

1. Scope
1. Review
1. Findings and Report

### Scope Gate

- Confirm the changed behavior, entry points, and blast radius.
- Decide which lenses apply before forming conclusions.
- Note whether the change is local, cross-cutting, or foundational.
- Separate implementation defects from style preferences and intentional trade-offs.

### Review Gate

Use the applicable lenses below. Do not force a lens where it does not belong.

#### 1. Code Quality

Use `checklists/code-quality.md` for correctness, readability, performance, maintainability, wiring, and stub detection.

#### 2. Security

Use `checklists/security.md` when the scope can affect secrets, trust boundaries, privileged actions, file or shell access, network calls, prompt handling, or agentic behavior.

Security review is most relevant for Web, API, and LLM or agentic surfaces. Skip the security checklist for Mobile-only or CI/CD-only changes unless the change also touches a privileged trust boundary, credential flow, or runtime policy.

#### 3. Architecture

Use `checklists/architecture.md` when the change affects module shape, dependency direction, layer boundaries, coupling, or long-term system structure.

#### 4. Domain Language

Use `checklists/domain-language.md` when the project has `UBIQUITOUS_LANGUAGE.md` or the change introduces new terms, states, actions, or bounded-context language.

#### 5. Optional UI/UX

Apply a UI/UX lens when the change affects templates, pages, interaction flow, accessibility, copy, or visual structure.

- Check consistency with project UI guidance and adjacent screens.
- Verify labels, states, and interactions are clear and intentional.
- Check that empty states, errors, and responsive behavior are handled deliberately.
- Do not invent UI findings when there is no user-facing surface.

### Review Order

1. Establish scope and entry points.
2. Check code quality and wiring first.
3. Check security when the scope can reach trust boundaries or privileged operations.
4. Check architecture and dependency direction.
5. Check domain language against the glossary and adjacent terminology.
6. Check optional UI/UX if the change is user-facing.
7. Re-evaluate candidate findings with calibration and verification references before reporting.

## Findings and Report

Record only findings that are real, reproducible, and supported by evidence.

### Severity Expectations

| Severity | Meaning |
| --- | --- |
| Critical | Security bypass, data loss, broken core behavior, or a flaw that makes the feature unsafe or unusable in normal operation. |
| High | Major correctness, integration, architectural, or security failure that will affect real use. |
| Suggestion | Useful cleanup, hardening, or clarity improvement that is not blocking. |

- Do not inflate severity for style nits or hypothetical issues without a concrete failure mode.
- If the evidence shows the path still works, keep the finding out of the report.
- If a file exists but is not wired, substantive, or reachable, treat that as a real defect, not a cosmetic gap.

### Report Rules

- Use file and line references where possible.
- Explain the failure mode, not just the symptom.
- State why the issue matters in DartClaw terms.
- Keep suggestions separate from blocking defects.
- If the scope is clean, say so directly instead of padding the report.

### Required Report Template

Produce the report with these exact sections and in this order:

## Summary

## CRITICAL ISSUES

## HIGH PRIORITY

## SUGGESTIONS

## Cleanup Required

## Compliance

## Next Steps

### Compliance Notes

- Mention which lenses were used and which were skipped.
- Note whether `references/review-calibration.md` was used to calibrate severity.
- Note whether `../references/verification-patterns.md` was used to judge existence, substance, wiring, and function.
- Call out any stubs, TODOs, placeholder logic, or dead wiring that remain.
- If a checklist file was not applicable, explain why.

### Next Steps Guidance

- If blocking issues exist, list the smallest credible fix path.
- If only suggestions remain, label them as non-blocking follow-up work.
- If the review is clean, say what was verified and what residual risk remains.

## Checklist References

- `checklists/code-quality.md`
- `checklists/security.md`
- `checklists/architecture.md`
- `checklists/domain-language.md`
- `references/review-calibration.md`
- `../references/verification-patterns.md`

## Output Contract

Summarize findings with evidence, then present the report using the required sections above.
Keep the review strict, specific, and calibrated.
