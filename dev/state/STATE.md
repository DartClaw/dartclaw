# Project State

> **In-flight state only.** Shipped history lives in `CHANGELOG.md`. Session journals belong in git commit messages,
> not here. Keep this file lean – when in doubt, cut.

Last Updated: 2026-08-13 14:25 CEST

## Current Phase

**Phase 4: Compatibility and release convergence**

**Status**: On Track

## Current Focus

- Run standard 0.24 release-preparation gates after integrating the completed Memory Model and execution-isolation plans.
- Continue paired-device Signal and WhatsApp DM/group typing checks as non-blocking field validation.

## Active Stories

- None.

## Recently Completed

- **0.24 Memory Model plan** (2026-08-12): S01–S12 delivered the canonical corpus, atomic mutation and migration,
  bounded prompt/retrieval/resource paths, search/index recovery, explicit curation, lifecycle visibility, and governance.
  Plan-level gap remediation converged at 10/10 functionality, completeness, and wiring with full workspace gates green.
- **Production-feedback convergence** (2026-08-11): all SecondBrain findings were verified or explicitly closed,
  actionable review findings were remediated, full workspace gates passed, and a fresh whole-changeset review returned
  Ready with no surviving notable issue.
- **0.24 release qualification** (2026-08-10): release metadata, documentation, workflow-live, visual, and native
  Windows guard matrices passed. Claude 2.1.226 covered shell, file, web, and MCP interception; Codex 0.139.0 covered
  every claimed command, file-change, and MCP approval category after one-shot approval hardening.

## Blockers

- None. The 0.24 execution-isolation correction is fully landed (2026-08-13): all 9 review gates remediated and
  committed, the four decisions ratified (ADR-052 accepted; fatal YAML parse; uid-1000/rootless posture documented;
  container scrub opt-out), mediated-turn conformance coverage in place, the two production defects it surfaced fixed
  (containerized Claude spawn cwd translation; containerized Codex `danger-full-access` on both lanes), and
  `crash_recovery_smoke_test` repaired (test-side defects: stale coordinator admission wiring + cwd-relative fixture
  paths — production crash recovery was intact). Dual-engine integration gate: **38/38 green** on Linux Docker 29.7.2
  (Ubuntu 24.04.3 aarch64, as root) and Docker Desktop 29.4.2 (macOS). Remaining before the tag: standard
  release-preparation gates only.

## Recent Decisions

- The 0.24 execution-isolation correction remains a separate plan bundle from the existing 0.24 memory work; neither plan
  may silently absorb or invalidate the other.
- Design-system gaps are fixed canon-first in `dev/design-system/` and synced downstream; page-specific workarounds are
  not accepted.
- 0.25 uses current-schema bootstrap plus a compatibility gate; no migration runner is planned during pre-alpha
  (ADR-045, amended 2026-07-30).
