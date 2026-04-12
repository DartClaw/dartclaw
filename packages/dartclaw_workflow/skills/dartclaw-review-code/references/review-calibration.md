# Review Calibration

Use this reference to keep findings specific, evidence-based, and properly calibrated.

## Severity Guide

- **Critical**: security bypass, data loss, or a broken core path that makes the feature unsafe or unusable.
- **High**: major correctness, integration, or performance failure that will surface in normal use.
- **Suggestion**: a worthwhile improvement, cleanup, or hardening item that is not blocking.

## Common Over-Flags

- style-only differences
- missing optional features
- theoretical issues without a realistic execution path
- framework conventions mistaken for missing code

## What Good Findings Include

- a concrete location
- the specific failure mode
- why the issue matters in this project
- the minimum fix required

## What Not to Do

- escalate nits into blockers
- treat test fixtures as production code
- call a gap critical when the code is merely inconsistent

