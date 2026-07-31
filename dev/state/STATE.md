# Project State

> **In-flight state only.** Shipped history lives in `CHANGELOG.md`. Session journals belong in git commit messages,
> not here. Keep this file lean – when in doubt, cut.

Last Updated: 2026-07-30 19:18 CEST

## Current Phase

**Phase 3: Adoption & glitch sweep**

**Status**: On Track. The 0.22.1 implementation plan is complete but not tagged or released. Post-completion visual
refinement is in progress on `feat/0.22.1`; 0.23 remains the next planned milestone.

## Current Focus

- Audit every served page and meaningful state against the refined design system. The three supplied screenshots are
  examples, not the audit boundary.
- Inventory routes and states before specifying or implementing another sweep, with art direction evaluated alongside
  consistency and correctness.

## Active Stories

- None. All 16 stories in `dev/bundle/docs/specs/0.22.1/plan.json` are `done`.

## Recently Completed

- **0.22.1 implementation** (2026-07-30): completed at `b08941af`; subsequent visual refinement remains unreleased.
- **0.22**: Afterglow design-system overhaul, tagged `v0.22.0`.

## Blockers

- None.

## Recent Decisions

- Design-system gaps are fixed canon-first in `dev/design-system/` and synced downstream; page-specific workarounds are
  not accepted.
- 0.23 uses current-schema bootstrap plus a compatibility gate; no migration runner is planned during pre-alpha
  (ADR-045, amended 2026-07-30).
