# Project State

> **In-flight state only.** Shipped history lives in `CHANGELOG.md`. Session journals belong in git commit messages,
> not here. Keep this file lean – when in doubt, cut.

Last Updated: 2026-08-04 10:31 CEST

## Current Phase

**Release close: review and validation**

**Status**: On Track. The 0.22.1 implementation and post-plan delivery record are complete but not tagged or released.
Council remediation and fresh validation are in progress on `feat/0.22.1`; 0.23 remains the next planned milestone.

## Current Focus

- Close the branch council with fresh code, documentation, security, requirements, and visual evidence.
- Complete the documented paired-device Signal and WhatsApp DM/group typing checks before release.

## Active Stories

- None. All 16 stories in `dev/bundle/docs/specs/0.22.1/plan.json` are `done`.

## Recently Completed

- **0.22.1 implementation** (2026-07-30): all 16 planned stories completed at `b08941af`; subsequent session,
  deployment, onboarding, channel, and visual refinements remain unreleased.
- **0.22**: Afterglow design-system overhaul, tagged `v0.22.0`.

## Blockers

- None.

## Recent Decisions

- Design-system gaps are fixed canon-first in `dev/design-system/` and synced downstream; page-specific workarounds are
  not accepted.
- 0.23 uses current-schema bootstrap plus a compatibility gate; no migration runner is planned during pre-alpha
  (ADR-045, amended 2026-07-30).
