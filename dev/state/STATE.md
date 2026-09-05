# Project State

> **In-flight state only.** Shipped history lives in `CHANGELOG.md`. Session journals belong in git commit messages,
> not here. Keep this file lean – when in doubt, cut.

Last Updated: 2026-09-05 19:50 CEST

## Current Phase

**P1: 0.26 – Pluggable Database Backend & Multi-Language Search**

**Status**: Opened on `feat/0.26` from the 0.25.1 squash (`ccfd9fcf`) on 2026-09-05; no story started. 0.25.1 is tagged
(`v0.25.1`); its record is `CHANGELOG.md` § 0.25.1 and `dartclaw-private/docs/specs/0.25.1/prd.md`. Pins are still at
0.25.1 – bump `version.dart`, every publishable pubspec, both Homebrew formulas, both Scoop manifests and the schema
`$id` with the milestone's first work commit. Plan: `dartclaw-private/docs/specs/0.26/plan.json` (17 stories).

## Current Focus

- 0.26 planning is canonical in the private repo (`docs/specs/0.26/`); nothing is in flight here yet.
- Post-tag audits for v0.25.1 are the open work item (see § Open follow-ups).

## Active Stories

<!-- Active stories derive from the governing plan. Store rows here only for ad-hoc work outside that plan. -->

## Recently Completed

- **0.25.1 released** (tagged 2026-09-05, `ccfd9fcf`): release-process hardening, two batches of SecondBrain deployment
  feedback (credential strip, no-op prune, curation log, live scheduling seam; then the primary-agent hardening recipe
  and warning, channel identity in the composed prompt, announce continuity, `reset_hour: -1`), five operator quick wins
  incl. the lean `dartclaw-workflow` binary, and the 0.25 ledger cleanups. Record: the private 0.25.1 PRD.
- **0.25.0 released** (tagged 2026-09-01, `4419d252`): all five platform archives, their checksums and
  `SHA256SUMS.txt` published. Two Windows-only defects held the first three tag runs red — the FTS5 build probe
  (`dev/tools/build_windows.ps1`) and the runtime smoke (`dev/testing/profiles/windows-runtime/run.ps1`) each seeded
  the retained preview memory dialect that `MemoryPreflight` refuses by design. Both now reach the canonical corpus
  authority instead. Nothing had been published, so the tag moved rather than adding a commit to `main`.
- **0.25 close-out** (2026-09-01): 0.24.3 merged (`46222850`); publish-path fixes (`f37b02f0`, `37a20d68`, `d05b994e`);
  `simplify-code` and `architecture-review` steps removed from the built-ins after the AndThen 1.0 plugin split;
  LOC ceilings re-cut with a 1500 band (`933c6f9c`); planner test mapping on `gpt-5.6-luna` after `gpt-5.6-sol`
  ended the plan turn at its first sub-agent's answer (test mapping only; the recommended presets keep sol / `claude/opus`).
## Blockers

None.

## Open follow-ups

- **Residuals carried out of 0.25**: `d7e60dc6` (dedicated Codex home hardening, 792 lines) had no second-reader review;
  containerized workflow-step composition is unit-tested only; `gpt-5.6-sol` ends the `plan` turn when its first Codex
  sub-agent answers (`andthen:plan` fan-out); the workflows profile's Codex rollouts were seen under `~/.codex/sessions/`
  despite the dedicated home – unverified whether the mirror or the host home served that run.
- **Four diagrams this milestone invalidated are unedited and must be redone through the excalidraw skill from a
  main conversation** — repo rules require it, and a story executor cannot honour that, so attempting them would
  corrupt the format and the element bindings. They live in `dartclaw-private/docs/diagrams/`:
  `crowd-coding.excalidraw` and `recipe-crowd-coding.excalidraw` (the chat-grammar deletions),
  `inbound-message-pipeline.excalidraw` (the shared gating pipeline) and `package-dag.excalidraw` (the topology
  re-cut). Nothing under any `docs/diagrams/` was modified, in either repo.
- **0.25 ledger residue routed (2026-09-05)**: the raw gap analyses behind the 0.25 consolidation were verified folded
  and deleted. Decision-class code facts are `TECH-DEBT-BACKLOG.md` TD-143–TD-146; fixable-now ones landed on this
  branch (RP5–RP9 in the private 0.25.1 PRD): foreach iteration coverage `ebec577f`, the `HttpClient` seam moved to
  kernel with UTF-8 bodies `6cfb216a`, one health badge mapping plus `WorkerState` in the enum gate `ce38735c`, the
  worker-discard pin `48dfa718`, and manual-start retry reset `b860a1a1`.
  Boy-scout cleanups from the same ledgers followed on 2026-09-05 (dead `SafeProcess.gitStart`, third-copy CLI
  helpers, duplicate channel parse, the merge-resolve outcome sentinel, per-package changelogs as pointers, and more) –
  the itemised table with commits is the private 0.25.1 PRD § Release-preparation defect fixes. Two stay recorded only in the private 0.25 PRD § Open items: the workflow e2e
  remediation loop is no longer deterministically exercised (needs a production-shaped substitute for a provider run),
  and the shared runtime test support composes a flat guard chain where production layers it (left as is: layered
  inheritance is pinned by three other suites, and the non-reuse property now has its own test).
- **One glob-dialect follow-through**: `guards.file.extra_rules` patterns are now compiled by the shared
  `globToRegex`, which changes `**` to segment-anchored. Any operator rule relying on the old partial-segment match
  needs rewriting; the CHANGELOG carries the migration line.

- **v0.25.1 post-tag audits**: approve the `homebrew` job in the `distribution-publication` environment, confirm the
  ten archives plus `SHA256SUMS.txt` on the release, run the Scoop install/version/update/uninstall audit on Windows x64.
- **Live-gate evidence at the 0.25.1 tag**: Claude half of `workflow-live --full --skip-e2e` green except the
  plan-and-implement `plan` step – the AndThen `plan` skill dispatches its FIS-authoring subagent in the background
  under current Claude Code and the headless step turn ends before it reports, so no FIS is written (fix belongs in the
  AndThen skill: `run_in_background: false` for that fan-out, or a host prompt line pinning synchronous subagents). The
  Codex half was not re-run (host-side quarantine attribute on the Codex cask's bundled `rg`; clear with `xattr -d
  com.apple.quarantine`). The suite itself was validating stale user-scope skill copies until `ae5a0b26`.

## Recent Decisions

- Recorded in `dev/state/DECISIONS.md` § Still Current (2026-08-16): `providers.<id>.auth` per-provider scoping with
  alias inheritance – now uniform across container, host, and workflow lanes; the Claude-only vendor-login health
  exemption; container-mode Claude ships behind a caveat rather than a runtime `x-api-key` downgrade.
- The "resolve without family" trap stays prose in `dev/state/LEARNINGS.md` rather than a fitness check: a grep cannot
  scope `.resolve(` to `CredentialRegistry` receivers and an analyzer-backed check is not worth its weight for a
  four-site trap that is now closed. (2026-08-16)
- Design-system gaps are fixed canon-first in `dev/design-system/` and synced downstream (see DECISIONS.md).
- 0.25 uses current-schema bootstrap plus a compatibility gate; no migration runner during pre-alpha (ADR-045).
- `0.24.3` validates schema-bound logical-agent output host-side only; provider-enforced structured output remains
  deferred until refusal-rate evidence justifies provider-specific plumbing. The 0.25 harness-level
  `requireStructuredOutputSupport` refusal is the complementary capability gate for provider-native structured
  output; the two do not overlap.
- Named credentials are an owner-permission store, not an encrypted vault. Encryption at rest needs a threat-model ADR.
