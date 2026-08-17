# Project State

> **In-flight state only.** Shipped history lives in `CHANGELOG.md`. Session journals belong in git commit messages,
> not here. Keep this file lean – when in doubt, cut.

Last Updated: 2026-08-17 07:20 CEST

## Current Phase

**Phase 4: Compatibility and release convergence**

**Status**: Release-ready, awaiting tag

## Current Focus

- Run the final clean-HEAD release check, squash-merge the scope-frozen 0.24.1 commit, and tag `v0.24.1`.
- Continue paired-device Signal and WhatsApp DM/group typing checks as non-blocking field validation.

## Active Stories

- None.

## Recently Completed

- **0.24.1 knowledge-inbox hardening** (2026-08-15): SecondBrain-reported wiki overwrite and lossy extraction fixed,
  then two review rounds and a mutation sweep over the result. Wiki writes merge instead of replacing and are atomic;
  unreadable pages are refused rather than rewritten; only the extraction turn is retried. Wiki lint's `orphan`
  category was inverted (read outbound links, so every inbox-written leaf was flagged every run) and is now inbound;
  anchored links are parsed. Three invariants the suite claimed but did not hold — the callback-only result log, the
  wiki-write-last ordering, and created-page permissions — survived mutation and are now pinned. 20+ mutants killed.
- **0.24.1 same-session turn admission** (2026-08-16): concurrent turn requests for one session could execute out of
  order (IO-pool completion order decided who took the session lock; measured 3–20%). `TurnManager.reserveTurn` now runs
  each session's reservations through a per-session `SessionMutationCoordinator` chain, so every `TurnManager` caller
  gets arrival order without per-caller serialization. Pinned by a test that fails deterministically without the chain;
  `andthen:review` (code+doc+security, four passes, devil's-advocate filter) found only doc-accuracy findings, all
  remediated; the coordinator gained its own unit test (three mutants killed). Private record:
  `dartclaw-private/docs/specs/0.24.1/prd.md`.

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

- No implementation blockers. The 0.24 execution-isolation correction is fully landed (2026-08-13): all 9 review gates
  remediated and
  committed, the four decisions ratified (ADR-052 accepted; fatal YAML parse; uid-1000/rootless posture documented;
  container scrub opt-out), mediated-turn conformance coverage in place, the two production defects it surfaced fixed
  (containerized Claude spawn cwd translation; containerized Codex `danger-full-access` on both lanes), and
  `crash_recovery_smoke_test` repaired (test-side defects: stale coordinator admission wiring + cwd-relative fixture
  paths — production crash recovery was intact). Dual-engine integration gate: **38/38 green** on Linux Docker 29.7.2
  (Ubuntu 24.04.3 aarch64, as root) and Docker Desktop 29.4.2 (macOS). Automated workspace, architecture, fitness,
  workflow-live (51/51), and UI smoke (TC-01–29, TC-31, R-01–14) gates are green. The scope-frozen release-prep snapshot
  is complete; `release_check.sh` must pass on that clean commit before the tag.
- 0.24.1 carries no execution-isolation, container, or provider-protocol change, so the 0.24 dual-engine, workflow-live,
  and Windows evidence still stands. Operator decision (2026-08-17): the 0.24.1 live-integration and UI-smoke gates are
  **not** re-run for this patch; the tag rests on the 0.24 manual evidence plus the automated gates (full workspace suite
  green on 2026-08-16 before three doc/test-only commits, each re-verified per file; `release_check.sh --quick` on the
  final commit).

## Recent Decisions

- The 0.24 execution-isolation correction and canonical-memory work retained separate requirement boundaries while their
  completed outcomes were consolidated into the private canonical PRD.
- Design-system gaps are fixed canon-first in `dev/design-system/` and synced downstream; page-specific workarounds are
  not accepted.
- 0.25 uses current-schema bootstrap plus a compatibility gate; no migration runner is planned during pre-alpha
  (ADR-045, amended 2026-07-30).
