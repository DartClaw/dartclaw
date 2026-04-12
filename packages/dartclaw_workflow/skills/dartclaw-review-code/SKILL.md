---
name: dartclaw-review-code
description: Perform a structured, non-lenient code review with security, correctness, architecture, and domain checks.
argument-hint: "[scope/files]"
user-invocable: true
---

# DartClaw Review Code

Comprehensive code review for workflow code and adjacent implementation. Analysis only. Do not modify files.

## Instructions

- Read the project instructions and relevant guidelines before starting.
- Calibrate findings with `references/review-calibration.md`.
- Use the checklists in `checklists/` to keep the review systematic.
- Prefer concrete evidence over intuition.
- Exclude generated, vendored, and lockfile noise.
- Report only findings that matter to correctness, security, architecture, or maintainability.

## Review Order

1. Determine the exact scope.
2. Check correctness and wiring first.
3. Check security and data handling.
4. Check architecture and naming.
5. Check domain language when a glossary exists.
6. Summarize findings with severity and evidence.

## Severity Expectations

- **Critical**: security bypass, data loss, or broken core behavior.
- **High**: major correctness or integration failure, or a change that will not work in real use.
- **Suggestion**: worthwhile cleanup or hardening that is not blocking.

Do not inflate severity for style nits or hypothetical problems without an actual failure mode.

## Output Contract

Produce:

- summary
- critical issues
- high-priority issues
- suggestions
- cleanup required
- compliance notes
- next steps

Use file and line references for findings where possible.

