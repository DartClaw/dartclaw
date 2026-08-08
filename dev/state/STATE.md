# Project State

> **In-flight state only.** Shipped history lives in `CHANGELOG.md`. Session journals belong in git commit messages,
> not here. Keep this file lean – when in doubt, cut.

Last Updated: 2026-08-08 18:22 CEST

## Current Phase

**Release ready**

**Status**: The 0.23 release is scope-frozen and release-ready on `feat/0.23`, awaiting squash merge and the `v0.23.0`
tag. The automated release check, full workflow-live, complete UI smoke, and exact-SHA GitHub CI pass; 0.24 remains next.

## Current Focus

- Squash-merge the release branch to `main` and tag the squash commit `v0.23.0`.
- Audit release assets and Homebrew/Scoop publication after the tag workflow completes.
- Continue paired-device Signal and WhatsApp DM/group typing checks as non-blocking field validation.

## Active Stories

- None. All 16 planned stories are complete; the transient public implementation bundle has been removed.

## Recently Completed

- **0.23 implementation** (2026-07-30): all 16 planned stories completed at `b08941af`; subsequent session,
  deployment, onboarding, channel, and visual refinements remain unreleased.
- **0.22**: Afterglow design-system overhaul, tagged `v0.22.0`.

## Blockers

- None.

## Recent Decisions

- Design-system gaps are fixed canon-first in `dev/design-system/` and synced downstream; page-specific workarounds are
  not accepted.
- 0.25 uses current-schema bootstrap plus a compatibility gate; no migration runner is planned during pre-alpha
  (ADR-045, amended 2026-07-30).
