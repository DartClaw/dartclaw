---
name: dartclaw-review-doc
description: Review specs, plans, PRDs, requirement documents, and FIS files for completeness, clarity, technical accuracy, and readiness.
argument-hint: "<spec-path-or-focus>"
---

# dartclaw-review-doc

Use this skill to review documentation before implementation starts.

## Discovery
- Locate the document or focus area from `SPEC_PATH_OR_FOCUS`.
- Determine the document type, project stage, surrounding artifacts, and intended audience.
- Read the surrounding project context only as far as it affects the document being reviewed.
- If the target is a FIS, confirm the document is actually a FIS and not a different planning artifact.
- If the document is a FIS, verify it still follows the `dartclaw-spec` structure and includes the expected implementation handoff material.
- Capture the document's purpose in one sentence before judging completeness or severity.
- Note any linked roadmap, plan, or architecture artifacts that define the review boundary.

## Review Pass
- Review the document for completeness, clarity, technical accuracy, scope, and stakeholder fit.
- Check for missing edge cases, missing testing guidance, and missing operational or integration detail when those are relevant to the artifact type.
- Use the project scale to decide how much detail is warranted.
- Apply the proportionality principle: prototypes, MVPs, and small tools should not be judged like enterprise platforms.
- Apply the over-engineering lens: flag complexity that does not pay for itself at the current stage.
- When the document names concrete frameworks, APIs, libraries, or version-bound patterns, verify the claims against authoritative sources when needed.
- Calibrate findings before writing them down so minor issues do not masquerade as blockers.
- Prefer gaps that would change implementation behavior over gaps that merely refine wording.
- Treat explicit exclusions as decisions, not omissions.
- Check that success criteria can actually be verified, not just read.

## Adversarial Challenge
- Challenge every finding before reporting it.
- Use `../references/adversarial-challenge.md` as the pressure-test template.
- Use `references/doc-review-calibration.md` to calibrate severity and false positives.
- Ask whether the finding is real, proportional, already addressed elsewhere, and likely to block or mislead implementation.
- Filter the findings to the ones that survive scrutiny.
- Prefer precise wording over dramatic wording.
- If a finding is downgraded, say why the lower severity is still meaningful.
- If a finding is withdrawn, keep the evidence trail so the review remains auditable.

## Report
- Produce a concise markdown report with only the surviving findings.
- Include an executive summary that states the overall readiness of the document.
- Include prioritized findings with severity and rationale.
- Include coverage for completeness, clarity, technical accuracy, edge cases, architecture, and over-engineering where relevant.
- Include a readiness assessment using `Ready`, `Needs Minor Updates`, `Needs Significant Rework`, or `Not Ready`.
- If the document is a FIS, call out structure problems explicitly so they can be fixed before implementation.
- After the report, ask whether the user wants the document updated, the review narrowed, implementation to begin, or critical issues escalated.
- Keep the report focused on decisions the author can act on.
- Do not bury the readiness call in a wall of commentary.

## Review Discipline
- Read the document in the context of the surrounding project.
- Stay proportional to the maturity of the artifact.
- Challenge findings adversarially before reporting them.
- Prefer concise, actionable findings over exhaustive commentary.
- Do not introduce implementation work into a read-only review.
- Do not escalate every omission into a blocker.

## Report Shape
- Executive summary
- Scope and context
- Prioritized findings
- Over-engineering analysis
- Readiness assessment
- Recommended follow-up actions
- Findings should be ordered from the most implementation-shaping issue to the least.
- If the document is ready, say what specifically is sufficient about it.
- If the document is not ready, say what class of gap remains.
