# Project State

> **In-flight state only.** Shipped history lives in `CHANGELOG.md`. Session journals belong in git commit messages,
> not here. Keep this file lean – when in doubt, cut.

Last Updated: 2026-08-10 14:38 CEST

## Current Phase

**Phase 1: 0.24 milestone**

**Status**: Blocked

## Current Focus

- Reauthenticate Claude in the native Windows environment and complete its required allowed/denied guard matrix.
- Re-run the native Windows Codex 0.139.0 matrix after approval-path hardening.
- Complete the 0.24 pre-tag release gate and scope-frozen commit after compatibility qualification passes.
- Continue paired-device Signal and WhatsApp DM/group typing checks as non-blocking field validation.

## Active Stories

- None. The 0.24 plan's four stories are complete.

## Recently Completed

- **0.24 implementation** (2026-08-09): live logical-agent tool policy and provider-pinned sessions, the opt-in memory journal, and on-demand scheduled-job execution completed with final convergence review and full CI gates.

## Blockers

- Native Windows Claude compatibility is unqualified because Claude 2.1.207 OAuth refresh fails. Codex 0.139.0 passed
  before the final approval-path hardening and must be requalified against that change.

## Recent Decisions

- Design-system gaps are fixed canon-first in `dev/design-system/` and synced downstream; page-specific workarounds are
  not accepted.
- 0.25 uses current-schema bootstrap plus a compatibility gate; no migration runner is planned during pre-alpha
  (ADR-045, amended 2026-07-30).
