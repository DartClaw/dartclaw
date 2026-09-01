# Project State

> **In-flight state only.** Shipped history lives in `CHANGELOG.md`. Session journals belong in git commit messages,
> not here. Keep this file lean – when in doubt, cut.

Last Updated: 2026-09-01 19:04 CEST

## Current Phase

**P1: 0.25 Lean Runtime – release-ready, awaiting tag**

**Status**: Feature-complete, main (0.24.3) merged, live merge-gate verification green, transient bundle removed, pins at 0.25.0; three of seven success metrics not met. See the verdict table below.

## Current Focus

- 94 of 96 stories done. S63 and S64 are deferred to 0.30 (their FIS moved to `dartclaw-private/docs/specs/0.30/`).
  Branch `feat/0.25-lean-runtime`, squash-merge to `main` pending the owner's go.
- Close-out record: `dartclaw-private/docs/specs/0.25/prd.md` § Implementation Record (canonical; the public bundle
  copy is gone per `dev/state/SPEC-LIFECYCLE.md`), `CHANGELOG.md` § 0.25.0, `dev/state/DECISIONS.md` § Still Current
  (2026-08-31/09-01 bullets), `dev/state/LOC-BASELINE-0.25.md` § Reviewed margin rebaseline.
- Live merge-gate verification (2026-09-01): `spec-and-implement` and `plan-and-implement` publish scenarios green on
  real Codex turns (PR #84, #85 on the fixture repo, both closed). Two shipped-path defects found and fixed on the
  way: `github-pr` publishing never reached GitHub (IOSink encoding) and workflow step commits never reached the
  integration branch (detached shared worktree since `2be4a932`).
- After the tag: the Homebrew/Scoop publication audits in `dev/guidelines/RELEASE_PREPARATION.md`.

## 0.25 success-metric verdicts

Measured at `ea678de2` against the merge base `a3eccab2`, with the one recorded command block
([`LOC-BASELINE-0.25.md`](LOC-BASELINE-0.25.md)). No PRD figure is quoted as a baseline or an achievement.

| # | Target | Measured | Verdict |
|---|---|---|---|
| 1 | lib LOC ≤ 146,179 (−12K) and test LOC ≤ 211,592 (−25K); per-package ceilings downward-only | lib **156,183** (−1,996); test **244,112** (**+7,520**); 13 ceilings recorded, `arch_check` 16/16 | **NOT MET** on both LOC clauses; the ceiling clause holds |
| 2 | No prose parsers, repair ladders or string sentinels over model output outside the documented templates; fitness grep enforces it | `check_no_prose_parsing.sh` exits 0 with no allowlist. One surviving repair ladder (the knowledge-inbox envelope fallback) was found by the final gap review and removed at `2aee744b` | **MET** |
| 3 | Chat capabilities invocable as guarded MCP tools; hand-rolled chat grammars gone; the crowd-coding recipe describes only performable behaviour | All seven tools registered on the guarded dispatch seam. `TaskTriggerParser`, `ReviewCommandParser`, `TaskCreator`, `TaskLister` and the `MEDIA:` sentinel are deleted. `docs/guide/recipes/08-crowd-coding.md` names no retired grammar. All six orchestration and content tools gained `CanonicalTool` entries at `77663512`, so the container-default install reaches them too | **MET** |
| 4 | 100% of model-spawning execution paths pass the guard chain, evidenced by an integration test; one testing profile boots container isolation | Per provider: on **Claude**, unconditional at the host `PreToolUse` gate, proven by dispatch in `guard_coverage_path_parity_integration_test.dart` — the same blocked command refused on the interactive and workflow-step paths, one audit entry each. On **Codex**, bounded to the approval handler and inactive under `approval: never` ([codex#11816](https://github.com/openai/codex/issues/11816)). Three spawn classes are **not** covered: the content classifier's own provider spawn (no chain at all), inbound MCP `tools/call` dispatch (guard-evaluated and audited, but not a runner turn, so per-task policy and read-only mode do not reach it), and an ACP-backed provider (its own reverse-call mediation only). `dev/testing/profiles/container/` boots isolation and runs as its own CI job | **PARTIAL** — US03's acceptance is met; the unqualified 100% claim is **not established** |
| 5 | One composition root; the CLI app contains no runtime-assembly code and is ≤ 8K lib LOC | `DartclawRuntime.build` is the only assembly path; `ServiceWiring` and `CliWorkflowWiring` have zero references anywhere in `apps/dartclaw_cli/lib`. CLI lib is **10,491** against ≤ 8,000, down from 20,769 — the milestone's largest single reduction, and still 2,491 over. The retained families are the ones Q5/Q6 kept: connected commands, `init`, `service`, `status`, `rebuild-index`, `auth`, `workflow` | **PARTIAL** — the composition-root clause is MET, the LOC clause is **NOT MET** |
| 6 | One config schema source emitting a published JSON Schema; `ConfigNotifier` diffs every section; ≥ 40 dead/heuristic keys removed; a documented core subset ≤ 90 keys | Clause by clause: published schema **MET** (`schemas/dartclaw.schema.json`, generator `--check` and the reference-drift gate both green); section diffing **MET** (`config_section_tier_coverage_test`, one allowlisted section with no value equality); core subset **MET** (56 keys ≤ 90); key removal **NOT MET** — **~29 plus 2 uncounted**, a shortfall of ~11, quoted from S12's landed FIS § *Implementation Observations* → `FR12 metric deviation`, on the plan's own counting convention | **NOT MET** on the removal clause only; the other three hold |
| 7 | Re-processing a knowledge-inbox source produces no new wiki supplement; a shrinking merge with an empty `removed_content` is refused | Both pinned by name: `re-dropping a source already on the page adds no supplement and leaves the body alone` and `an integration that shrinks the page without declaring a removal is refused and quarantined` (`knowledge_inbox_service_test.dart`) | **MET** |

### Deviations, not misses

A story that found its dead premise falsified and preserved a live capability did what the milestone's binding
constraint required. These are recorded as deviations against metric 6's removal clause, with the premise that
failed:

- **`features.thread_binding` preserved** (two leaf paths). Premise: the capability was dead. Falsified — it is live,
  and the owner ruled no regressions.
- **`automation.scheduled_tasks` migrated, not deleted** (eight leaf paths leave the supported surface, the parser is
  retained). Premise: removal was safe. Falsified — an un-migrated config would silently lose its schedule.
- **The governance knob S25 found in use.** Premise: dead. Falsified by the finding.

No metric was re-baselined against a lowered target. Metric 1 depended on no descoped story — every Should story it
counted on landed — so there is nothing to re-baseline against, and the figure of record is the miss.

## Active Stories

<!-- Active stories derive from the governing plan. Store rows here only for ad-hoc work outside that plan. -->

## Recently Completed

- **0.25 close-out** (2026-09-01): 0.24.3 merged (`46222850`); publish-path fixes (`f37b02f0`, `37a20d68`, `d05b994e`);
  `simplify-code` and `architecture-review` steps removed from the built-ins after the AndThen 1.0 plugin split;
  LOC ceilings re-cut with a 1500 band (`933c6f9c`); planner test mapping on `gpt-5.6-luna` after `gpt-5.6-sol`
  ended the plan turn at its first sub-agent's answer (test mapping only; the recommended presets keep sol / `claude/opus`).
- **0.24.1 patch** (tagged 2026-08-17): knowledge-inbox correctness (merge-safe atomic wiki writes, honest
  coverage, retry scope, wiki-lint fixes) and same-session turn admission in arrival order. Detail in
  `CHANGELOG.md`; private record `dartclaw-private/docs/specs/0.24.1/prd.md`.
- **0.24.3 patch** (released 2026-08-27, merged into this branch 2026-09-01): schema-bound logical-agent output
  (`agent.agents.<id>.output_schema`), one content-scan authority covering `web_fetch` and `public` outbound MCP
  results, and the named credential store with `dartclaw secrets set|list|rm|audit` and
  `search.providers.<id>.credential`. Detail in `CHANGELOG.md`.

## Blockers

- None before the squash-merge. `dev/tools/release_check.sh --version 0.25.0` passes on the release candidate.

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
- **One glob-dialect follow-through**: `guards.file.extra_rules` patterns are now compiled by the shared
  `globToRegex`, which changes `**` to segment-anchored. Any operator rule relying on the old partial-segment match
  needs rewriting; the CHANGELOG carries the migration line.

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
