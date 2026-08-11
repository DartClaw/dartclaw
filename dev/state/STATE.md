# Project State

> **In-flight state only.** Shipped history lives in `CHANGELOG.md`. Session journals belong in git commit messages,
> not here. Keep this file lean – when in doubt, cut.

Last Updated: 2026-08-11 07:29 CEST

## Current Phase

**Phase 1: 0.24 milestone**

**Status**: Release-ready; awaiting tag

## Current Focus

- Preserve the verified 0.24.0 changeset for tagging.
- Continue paired-device Signal and WhatsApp DM/group typing checks as non-blocking field validation.

## Active Stories

- None.

## Recently Completed

- **Production-feedback convergence** (2026-08-11): all SecondBrain findings were verified or explicitly closed,
  actionable review findings were remediated, full workspace gates passed, and a fresh whole-changeset review returned
  Ready with no surviving notable issue.
- **0.24 implementation** (2026-08-09): live logical-agent tool policy and provider-pinned sessions, the opt-in memory journal, and on-demand scheduled-job execution completed with final convergence review and full CI gates.
- **0.24 release qualification** (2026-08-10): release metadata, documentation, workflow-live, visual, and native
  Windows guard matrices passed. Claude 2.1.226 covered shell, file, web, and MCP interception; Codex 0.139.0 covered
  every claimed command, file-change, and MCP approval category after one-shot approval hardening.

## Blockers

- None.

## Recent Decisions

- Design-system gaps are fixed canon-first in `dev/design-system/` and synced downstream; page-specific workarounds are
  not accepted.
- 0.25 uses current-schema bootstrap plus a compatibility gate; no migration runner is planned during pre-alpha
  (ADR-045, amended 2026-07-30).
