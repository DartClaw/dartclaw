# Project State

> **In-flight state only.** Shipped history lives in `CHANGELOG.md`. Session journals belong in git commit messages,
> not here. Keep this file lean – when in doubt, cut.

Last Updated: 2026-09-04 14:10 CEST

## Current Phase

**P1: 0.25.1 – release-process hardening and deployment-feedback fixes**

**Status**: Release-ready on `feat/0.25.1`, awaiting tag. Pins at 0.25.1 across `version.dart`, all thirteen
publishable pubspecs, both Homebrew formulas, the Scoop manifest and the schema `$id`. 0.25.0 is tagged and published
(`4419d252`). Bug fixes from the 2026-09-02 deployment-feedback review and five owner-driven operator quick wins ride
this patch alongside the release-process work; the 0.25 verdict table below is retained as the shipped record.

## Current Focus

- Release-process hardening carried out of the 0.25.0 tag: landed at `d818bf5b`. `release_check.sh` gate 10 resolves
  `Checks` by full HEAD SHA and requires `Check`, `Container boundary` and `PowerShell scripts` green by name;
  `Release Binaries` gained a `workflow_dispatch` dry run with `publish` gated on `github.ref_type == 'tag'`; CI gained
  a `windows-latest` job that parses every tracked `.ps1` and runs PSScriptAnalyzer at Error severity;
  `RELEASE_PREPARATION.md` requires the pushed branch green before the squash and forbids follow-up commits on `main`.
  Evidence: gate 10 flipped FAIL → PASS across `Checks` run 33594460721 on the same commit, and dispatch run
  33595119483 built all five targets and skipped every publishing job.
- Deployment-feedback fixes (2026-09-02 review of the second-brain findings): the Bash-env credential strip now covers
  `CLAUDE_CODE_OAUTH_TOKEN` (`27ea2afc`); refused `memory_apply` change sets log at WARNING so an inert curation run is
  visible (`0112c02c`); a byte-identical corpus replacement no longer bumps `Collection-Revision`, so the nightly prune
  stops committing empty revisions (FIS `memory-corpus-noop-commit`, executed at `5423ac84`); seam-written
  `scheduling.jobs` apply live and one-time `at` jobs are writable (FIS `live-scheduling-jobs`, executed at `4bb5fc46`). The channel→agent binding request was reframed in the private backlog around single-owner
  multi-persona; no code. The 2026-09-01 items closed at `53a84e60`: `ConfigWriter` writes through a symlinked config,
  the tolerated `guards.input_sanitizer` key names its replacement, and the `tasks.execution` map-to-scalar break is
  recorded under 0.25.0 instead of the retro-edited 0.24.0 section (the suggested tolerated rewrite was declined as a
  silent placement weakening). The second-brain feedback file has no open items.
- Operator quick wins (owner, 2026-09-03), five standalone FIS, all executed: the lean workflow-only binary
  `dartclaw-workflow` with a flat command tree (`5f6a8057`…`3852c7f9`; a `Release Binaries` dispatch dry run built all
  ten archives on 2026-09-04, run 33861257861); `dartclaw doctor` with `--fix` and `--json` (`8f4c6027`); labelled
  reclamation of containers leaked by an abnormal exit, closing TD-121 (`0fc21078`); release-pinned config JSON schema
  with the `init` modeline and offline `dartclaw config schema --out` (`9213e0d8`); and the CLI quick wins – a
  server-probing `status`, stderr with distinct exit codes 3–6, and `--yes` on destructive deletes (`288bc8c8`).
  The bundle is consolidated into `dartclaw-private/docs/specs/0.25.1/prd.md` and removed from this repo.
- Second SecondBrain feedback batch (2026-09-05, analysed and executed the same day): the primary-agent hardening
  recipe and its startup warning (`7fb1e5dd`, `86994030`), the originating channel named in the composed prompt
  (`e6139fc3`, `TurnDispatcher` break for embedders), announced results recorded in the DM sessions they reach and in the
  daily log (`9e55248d`), and `sessions.reset_hour: -1` (`fd178dc0`). Seam-write approval and a model-free `type: shell`
  job are spec candidates in the private product backlog; per-agent workspaces and channel → agent binding stay on the
  roadmap. Record: private 0.25.1 PRD § Deployment feedback, second batch.

- 0.25 close-out record (unchanged): `dartclaw-private/docs/specs/0.25/prd.md` § Implementation Record (canonical),
  `CHANGELOG.md` § 0.25.0, `dev/state/DECISIONS.md` § Still Current.

## 0.25 success-metric verdicts

Measured at `ea678de2` against the merge base `a3eccab2` (`*.dart` under `lib/` and `test/`, generated `*.g.dart`
excluded, `wc -l`). No PRD figure is quoted as a baseline or an achievement.

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

- **0.25.0 released** (tagged 2026-09-01, `4419d252`): all five platform archives, their checksums and
  `SHA256SUMS.txt` published. Two Windows-only defects held the first three tag runs red — the FTS5 build probe
  (`dev/tools/build_windows.ps1`) and the runtime smoke (`dev/testing/profiles/windows-runtime/run.ps1`) each seeded
  the retained preview memory dialect that `MemoryPreflight` refuses by design. Both now reach the canonical corpus
  authority instead. Nothing had been published, so the tag moved rather than adding a commit to `main`.
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

## Release gates – 0.25.1

- **Live integration tests skipped by owner decision (2026-09-04).** `bash dev/testing/profiles/workflow-live/run.sh --full`
  was not run for this patch. The release-blocking evidence is the automated gate set: `release_check.sh --version 0.25.1`
  all green, `Checks` green on the pinned commit with `Check`, `Container boundary` and `PowerShell scripts` by name, and
  a `Release Binaries` `workflow_dispatch` dry run building all ten archives and running the Windows installer test.
- Homebrew and Scoop render both artifacts. Both formulas were rendered locally against fixture checksums before the tag;
  the tag-time render is the first real execution of the publication jobs.

## Blockers

None. 0.25.0 Homebrew and Scoop publication completed – every job in `Release Binaries` run 33546071918 is green.

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
