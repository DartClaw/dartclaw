# Project State

> **In-flight state only.** Shipped history lives in `CHANGELOG.md`. Session journals belong in git commit messages,
> not here. Keep this file lean – when in doubt, cut.

Last Updated: 2026-08-09 14:54 CEST

## Current Phase

**Phase 1: 0.24 milestone**

**Status**: On Track

## Current Focus

- Review and merge the completed 0.24 implementation bundle.
- Close the 0.24 provider-interception and audit-attribution follow-ups found during implementation reflection.
- Continue paired-device Signal and WhatsApp DM/group typing checks as non-blocking field validation.

## Active Stories

- None. The 0.24 plan's four stories are complete.

## Recently Completed

- **0.24 implementation** (2026-08-09): live logical-agent tool policy and provider-pinned sessions, the opt-in memory journal, and on-demand scheduled-job execution completed with final convergence review and full CI gates.
- **0.23 implementation** (2026-07-30): all 16 planned stories completed at `b08941af`; subsequent session,
  deployment, onboarding, channel, and visual refinements remain unreleased.

## Blockers

- None.

## Recent Decisions

- Design-system gaps are fixed canon-first in `dev/design-system/` and synced downstream; page-specific workarounds are
  not accepted.
- 0.25 uses current-schema bootstrap plus a compatibility gate; no migration runner is planned during pre-alpha
  (ADR-045, amended 2026-07-30).
