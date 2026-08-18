# Project State

> **In-flight state only.** Shipped history lives in `CHANGELOG.md`. Session journals belong in git commit messages,
> not here. Keep this file lean – when in doubt, cut.

Last Updated: 2026-08-18 09:10 UTC

## Current Phase

**0.24.2 release-ready, awaiting tag**

**Status**: On Track

## Current Focus

- The 0.24.2 subscription-default provider authentication milestone is fully executed on branch `feat/0.24.2`: all 9
  stories merged, S09 having been added mid-execution to close an operator credential-ingestion gap. The public
  bundle is wound down; the canonical record is `dartclaw-private/docs/specs/0.24.2/prd.md`.
- Gap review stands at 8/8/8 with no CRITICAL or HIGH. A fourth pass closed 22 of 30 OPEN ledger entries; owner review
  then ratified four (override reasons recorded), withdrew the shared-`CODEX_HOME` entry on vendor-source evidence,
  closed the ACP one by making ACP registrations credential-isolated, and proved Codex subscription auth live.
- The Claude raw-Bearer gate ran 2026-08-17 and returned ACCEPTED, so container-mode Claude ships subscription-default
  and the `x-api-key` revert is not needed; the gate itself was fixed to get there (it sent no `anthropic-version`).
- Four OPEN entries remain, all ratified with recorded override reasons (gate-clear). `auth claude` now masks typed
  input and handles Ctrl-C in-band (mode restored, exit 130), which closed the SIGINT entry as fixed.
- 0.24.1 is merged into the branch (2026-08-18) and version pins, CHANGELOG, and ROADMAP are at 0.24.2.
- Nine defects from the private Lean Runtime handoff's 0.24.2 candidate list are fixed on the branch (2026-08-18),
  including two security bypasses: content carrying a Cloudflare-challenge marker skipped classification, and the
  default classifier forced content-guard fail-open silently. `guards.content.fail_open` now defaults to **false** —
  breaking for any deployment that relied on the implicit pass-through. Rows 8 and 9 were unverified reports; both
  confirmed. Row 8 (workflow one-shot steps bypass the guard chain) is not patch-fixable and is now TD-122.
- Remaining before the tag: the owner-run manual gates below, then squash-merge per
  `dev/guidelines/RELEASE_PREPARATION.md`.
- Continue paired-device Signal and WhatsApp DM/group typing checks as non-blocking field validation.

## Active Stories

- None.

## Recently Completed

- **0.24.1 patch** (tagged 2026-08-17): knowledge-inbox correctness (merge-safe atomic wiki writes, honest
  coverage, retry scope, wiki-lint fixes) and same-session turn admission in arrival order. Detail in
  `CHANGELOG.md`; private record `dartclaw-private/docs/specs/0.24.1/prd.md`.
- **0.24 Memory Model plan** (2026-08-12): S01–S12 shipped; gap remediation converged at 10/10, gates green.

## Blockers

- **Pre-tag gates** (`dev/guidelines/RELEASE_PREPARATION.md` § Pre-tag gates). This release changes provider protocol
  and the credential boundary, so the 0.24 evidence is not inheritable as it was for 0.24.1.
  - Container conformance, **Docker Desktop 29.4.2 / macOS arm64, 2026-08-18: 56/56 PASS** on commit `0b25f394`.
  - Container conformance, **Linux Docker 29.7.2 / Ubuntu 24.04.4 LTS aarch64 (as root), 2026-08-18: 55/56 PASS,
    1 skipped, exit 0.** Three setup traps had to be cleared first, all documented in
    `dev/guidelines/PARALLELS_LINUX_AGENT_VM.md`: native assets must be materialized once via `dart run` in a fresh
    checkout (a bare directory-scoped `dart test` does not do it, and 33 tests then fail on an unresolved
    `sqlite3_initialize`); `build/` must be `chmod -R a+rX` **after** `build_bridge.sh`, or the container's uid-1000
    user cannot traverse to the root-built `0700` bridge and 23 mediated fixtures fail on `Bridge pipe revoked`; and
    `crash_recovery_smoke_test`'s readiness poll was sized to a fast host (10s) while its nested `dart run` blocks on
    the parent's hook cache — widened to 30s inside the unchanged 60s test timeout.
  - **Live workflow profile, 2026-08-18: 51/51 PASS** (`--full`, 39 min, real Codex turns) on commit `0b25f394`.
  - UI smoke: **partial**. Verified on 2026-08-18 at 1280px and 375px — TC-01, TC-04, TC-05, TC-08, TC-09
    (including the 0.24.2 provider-card credential block: mode, source, last-checked, and the remediation naming
    `claude setup-token` / `dartclaw auth claude` and the searched store path), TC-12, TC-13, TC-14, TC-17, plus the
    tasks/memory/workflows/projects/scheduling renders and R-01, R-03, R-05, R-08, R-10, R-11. No console errors.
    Health reports Version 0.24.2. **Not run**: the interaction-dependent cases — TC-02/03 (login), TC-06/07/07A
    (chat/composer), TC-11, TC-15, TC-16, TC-18, TC-19, TC-21, TC-23…TC-28, TC-31, and R-02, R-04, R-06, R-07,
    R-09, R-12, R-13, R-14.
- **Four ratified ledger entries** carry recorded `override-close` reasons and no longer block the gate: serve
  admit-path negative control, `_tearDownAuthority` coverage, the `Re-authentication Required` alert title, and
  library-level diagnostics naming `dartclaw auth`. They are accepted unresolved work, not pending tasks; the entries
  survive in the private PRD and the follow-ups in the private `PRODUCT-BACKLOG.md`.

## Recent Decisions

- Recorded in `dev/state/DECISIONS.md` § Still Current (2026-08-16): `providers.<id>.auth` per-provider scoping with
  alias inheritance – now uniform across container, host, and workflow lanes; the Claude-only vendor-login health
  exemption; container-mode Claude ships behind a caveat rather than a runtime `x-api-key` downgrade.
- The "resolve without family" trap stays prose in `dev/state/LEARNINGS.md` rather than a fitness check: a grep cannot
  scope `.resolve(` to `CredentialRegistry` receivers and an analyzer-backed check is not worth its weight for a
  four-site trap that is now closed. (2026-08-16)
- Design-system gaps are fixed canon-first in `dev/design-system/` and synced downstream (see DECISIONS.md).
- 0.25 uses current-schema bootstrap plus a compatibility gate; no migration runner during pre-alpha (ADR-045).
