# Project State

> **In-flight state only.** Shipped history lives in `CHANGELOG.md`. Session journals belong in git commit messages,
> not here. Keep this file lean – when in doubt, cut.

Last Updated: 2026-08-13 08:48 CEST

## Current Phase

**Phase 4: Compatibility and release convergence**

**Status**: At Risk

## Current Focus

- Execute the supplemental 0.24 Memory Model plan from `dev/bundle/docs/specs/0.24/`, beginning with the canonical corpus.
- Execute the provider-neutral isolation plan from `dev/bundle/docs/specs/0.24-execution-isolation/`; the 0.24 tag remains
  blocked until its host/container, credential, capability, and conformance stories pass.
- Continue paired-device Signal and WhatsApp DM/group typing checks as non-blocking field validation.

## Active Stories

- None.

## Recently Completed

- **Production-feedback convergence** (2026-08-11): all SecondBrain findings were verified or explicitly closed,
  actionable review findings were remediated, full workspace gates passed, and a fresh whole-changeset review returned
  Ready with no surviving notable issue.
- **0.24 release qualification** (2026-08-10): release metadata, documentation, workflow-live, visual, and native
  Windows guard matrices passed. Claude 2.1.226 covered shell, file, web, and MCP interception; Codex 0.139.0 covered
  every claimed command, file-change, and MCP approval category after one-shot approval hardening.

## Blockers

- 0.24 execution-isolation: all 9 release-gating HIGH gates from the council mixed review
  (`0.24-execution-isolation-mixed-review-claude-2026-08-12.md`) are remediated and the four open decisions are
  ratified (ADR-052 accepted; fatal YAML parse; documented uid-1000/rootless posture; container scrub opt-out) —
  nothing committed yet. G-HIGH-6 now has its mediated-turn coverage: real containerized claude and codex turns complete
  through host mediation and write into the mounted workspace, green on Docker Desktop 29.4.2 (macOS 25.6.0) and Linux
  Docker 29.7.2 (Ubuntu 24.04.3 aarch64, as root) on 2026-08-13 — 37 passed on both engines, with one pre-existing
  unrelated failure (`crash_recovery_smoke_test.dart`, red at HEAD before this work).
- The two production defects that coverage surfaced are fixed and verified (2026-08-13): containerized Claude spawns
  translate the working directory (start-before-turn included), and containerized Codex forces `danger-full-access` on
  both lanes per the security-architecture sandbox matrix (read-only one-shots keep `read-only`, failing closed). The
  fixtures' workarounds are removed, so the mediated-turn suite now drives the true shipped lanes; dual-engine gate
  re-run green (Linux Docker as root and Docker Desktop: 37 passed each, sole failure the pre-existing
  `crash_recovery_smoke_test`). Remaining before the tag: triage `crash_recovery_smoke_test` (red at HEAD, predates
  this work) and the standard release-preparation gates.

## Recent Decisions

- The 0.24 execution-isolation correction remains a separate plan bundle from the existing 0.24 memory work; neither plan
  may silently absorb or invalidate the other.
- Design-system gaps are fixed canon-first in `dev/design-system/` and synced downstream; page-specific workarounds are
  not accepted.
- 0.25 uses current-schema bootstrap plus a compatibility gate; no migration runner is planned during pre-alpha
  (ADR-045, amended 2026-07-30).
