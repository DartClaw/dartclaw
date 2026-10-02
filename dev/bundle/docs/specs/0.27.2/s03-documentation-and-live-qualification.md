# Documentation and live qualification

**Plan**: dev/bundle/docs/specs/0.27.2/plan.json
**Story-ID**: S03

## Feature Overview and Goal

**Intent**: Let maintainers use the rc.4 workflows with accurate setup and process guidance, and know from real provider runs whether the renamed pipelines complete their promised paths.

**Expected Outcomes**:

- [OC01] Documentation names the one-story workflow and the single AndThen 1.0 plugin, and explains when plan completion runs simplification.
- [OC02] Maintainer guidance reflects current plan discovery, skill names, review flow, and the 0.27.2 change without retired terminology.
- [OC03] A real provider demonstrates one-story specification, PRD planning, and a custom inline workflow on disposable input, with an honest result and measured implement duration.

## Required Context

- `docs/specs/0.27.2/andthen-rc4-alignment.md#decisions-settled-with-the-maintainer-2026-10-02` – fixes the workflow identity, council removal, prerequisite, and inline flag.
- `docs/specs/0.27.2/andthen-rc4-alignment.md#changes` – assigns C5–C11 and remaining C1/C7 prose.
- `docs/specs/0.27.2/andthen-rc4-alignment.md#done-when` – defines the retired-term sweep and three real-provider runs.
- `docs/specs/0.27.2/andthen-rc4-alignment.md#not-in-this-change` – excludes four adjacent issues.

## Acceptance Scenarios

- **S01 [OC01] A maintainer selects the one-story path with the correct prerequisite**
  - **Given** an inline feature description or an existing FIS
  - **When** the maintainer follows the skills guide, workflow guide, CLI examples, package guide, or runner README
  - **Then** the route is `story-and-implement` or its `-inline` variant, the installed prerequisite is the single `andthen` plugin at version 1.0 or later, and the unchanged `spec` step/output terminology is described as FIS terminology.

- **S02 [OC01] The simplification cost is clear before a one-story run**
  - **Given** `andthen:exec-plan` completes the last unfinished story of a plan and every story is `done`
  - **When** the maintainer reads the skills guide and workflow explanation
  - **Then** they learn that this run invokes `andthen:simplify-code` once for the completed plan inside the implement step; completing a newly authored one-story plan qualifies, while an existing FIS in an unfinished multi-story plan does not, and no separate built-in simplify step is implied.

- **S03 [OC02] Resume, review, and process guidance matches rc.4**
  - **Given** a plan with done, skipped, and dependent pending stories, or a maintainer following the review/decision process
  - **When** they read the workflow guide, decisions index, learnings, contributor rules, and testing references
  - **Then** only done dependencies are pruned, dependents of skipped stories are omitted from runnable discovery, an empty catalog means no story left to run, review examples use surviving `andthen:review` output, and ADR guidance names `andthen:decide` with current direct plan maintenance rather than retired commands.

- **S04 [OC02] Release history and scenario prose match the delivered workflows**
  - **Given** the renamed definitions from story S01 and runtime identity from story S02
  - **When** a reader checks the 0.27.2 changelog, workflow architecture, README files, and workflow smoke scenarios
  - **Then** they find the plan/exec skill change, blocked skipped dependents, one-story rename, council removal, AndThen 1.0 requirement, current scenario paths/commands, and the historical visual-session message names the current workflow while retaining its fixture shape.

- **S05 [OC03] [runtime] A terse one-line feature resolves honestly through the spec step**
  - **Given** the installed rc.4-or-later plugin, a real provider, and a disposable fixture repository with no public app change
  - **When** `story-and-implement` runs with a terse one-line FEATURE that contains no prewritten FIS or detailed artifact instructions
  - **Then** the `spec` step either writes a readable FIS and emits a nonempty `spec_path` consumed by `implement`, or explicitly fails; an empty `spec_path` never accompanies a successful spec step. Record the observed `implement` step duration, including its simplify pass.

- **S06 [OC03] [runtime] A small PRD traverses planning and execution**
  - **Given** a committed small PRD in a disposable fixture and the real provider
  - **When** `plan-and-implement` runs with that PRD path
  - **Then** discovery accepts it, `andthen:plan` produces a plan and FIS path, and a runnable story completes the implementation/review path successfully.

- **S07 [OC03] [runtime] An inline custom workflow preflights without council**
  - **Given** one of the maintained `*-inline` definitions and the single installed AndThen plugin
  - **When** it runs against a disposable fixture
  - **Then** skill preflight passes with no council requirement, the remaining review result reaches the existing aggregation/remediation path, and the workflow completes successfully.

## Structural Criteria

- **SC01** Remaining prose and historical fixture edits are limited to the S03 ownership in the plan; workflow skill payloads remain story S01's responsibility, and prose scenario renames use `git mv`.
- **SC02** The source's eight retired literal patterns have no matches on the plan's Implementation scan surface; historical `dev/state/DECISIONS.md` `spec-ready` prose and negative fixtures are included in the coverage by their owning stories.
- **SC03** The four source non-goals remain untouched: `technical_research`, `plan.md` paths, `STACK.md`/agents provisioning, and code-review argument syntax. Live runs create no PR and make no change to the public app checkout.

## Scope & Boundaries

### Work Areas

- Public top-level and package Markdown: `CLAUDE.md`, `README.md`, `packages/dartclaw_workflow/{CLAUDE.md,README.md}`, `CHANGELOG.md`.
- `docs/guide/{andthen-skills,workflows,cli-operations,cli-reference,web-ui-and-api}.md`; relevant `dev/architecture/`, `dev/guidelines/`, `dev/state/`, `dev/testing/profiles/`, `dev/testing/scenarios/`, and `dev/tools/dartclaw-workflows/README.md` prose identified by the inventory and final sweep.
- `dev/testing/profiles/visual/data/sessions/52222222-2222-4222-8222-222222222222/messages.ndjson` historical literal only.
- Disposable live fixture and existing workflow CLI/profile/test tooling for the three recorded real-provider runs.

### What We're NOT Doing

- Workflow definitions, skill payloads, non-prose tests/fixtures, CLI code, and runners – story S01 owns them; runtime code, UI templates, and runtime tests belong to story S02.
- The source's four non-goals – unrelated to rc.4 alignment.
- A new live-test harness, model behavior repair, or publication of a PR – qualification uses existing seams and reports external prerequisite or model failure as observed.

## Architecture Decision

**Approach**: Correct the existing documentation in place, rename prose scenario paths with `git mv`, change only the named historical fixture literal, and qualify the assembled workflows through existing disposable-fixture and CLI seams.
**Why this over the floor**: Existing prose still directs maintainers to retired skills and the old workflow, while the existing E2E reuse test skips `spec` and cannot demonstrate the source's terse one-line requirement (C5–C11; Done when).

## Constraints & Gotchas

- **Constraint**: Stories S01 and S02 supply the shipped names and behavior first; this story documents and qualifies their assembled result, without reimplementing their code.
- **Constraint**: `.agent_temp/andthen-rc4-rename-inventory.md` is a starting inventory only; rescan the final public tree, including the historical `DECISIONS.md` status mention and equivalent negative fixtures from stories S01/S02.
- **Constraint**: The `workflow_e2e_integration_test.dart` one-story case seeds a reusable FIS and skips `spec`; `workflow_step_isolation_test.dart` uses a richer feature sentence. Neither alone proves S05. Use a genuinely terse FEATURE through the actual workflow/spec gate, and inspect step outputs before claiming success.
- **Constraint**: Source C5's documentation-accuracy intent is carried by S02's installed `andthen:exec-plan` § Simplify condition: the run completes the plan and every story is `done`. The source's shorthand that every one-story workflow run pays does not apply to an existing FIS in an unfinished larger plan.
- **Constraint**: Built-ins can publish a branch/PR. Use a disposable fixture with a local bare remote or disabled publication through an existing configuration seam; verify no PR creator is active. Do not run a canary against the public app checkout.
- **Constraint**: The private FIS and plan are canonical; execution consumes exported `dev/bundle/` paths in the public checkout. The plan's Implementation scan surface owns the temporary-record exclusion.
- **Constraint**: The live result can fail because of plugin version, provider credentials, fixture, or model output. Record the exact failed step and prerequisite; never treat a skipped canary or partial trace as a successful run.

## Implementation Plan

### Implementation Tasks

- **TI01** The skills and workflow guides state the one-plugin AndThen 1.0 prerequisite, current one-story identity, and S02's plan-completing simplify condition.
  - **Verify**: `inspect: ../dartclaw-public/docs/guide/andthen-skills.md:1` – S01/S02's prerequisite, one-story path, and simplify mechanism are explicit and agree with the current workflow guide.
  - **SATISFIES**: S01, S02

- **TI02** Workflow reference and operator examples describe done-only pruning, skipped-dependent omission, no-runnable-story resume, and surviving review aggregation.
  - **Verify**: `inspect: ../dartclaw-public/docs/guide/workflows.md:260` – compare aggregation example and both resume passages to S03; CLI/web examples use `story-and-implement`.
  - **SATISFIES**: S01, S03

- **TI03** Contributor and package process references use current direct plan upkeep and `andthen:decide`/`andthen:describe` or current skill names where applicable, without presenting retired branded provisioning as current.
  - **Verify**: `inspect: ../dartclaw-public/CLAUDE.md:49` – document-index instructions, built-in list, package guidance, and decisions maintenance reflect the current process; preserve unaffected ceilings and boundaries.
  - **SATISFIES**: S03, SC01

- **TI04** `dev/state/DECISIONS.md` and `LEARNINGS.md` carry accurate ADR/process/status terminology, including the historical `spec-ready` mention and nonexistent `validateStorySpecsContract(completedStoryIds:)` claim.
  - **Verify**: `inspect: ../dartclaw-public/dev/state/DECISIONS.md:1` – maintenance comments name `andthen:decide`, historical status prose is current, and the learnings bullet states only existing behavior or is removed.
  - **SATISFIES**: S03, SC02

- **TI05** The 0.27.2 changelog records all five source-required changes under a heading dated with `date +%Y-%m-%d`.
  - **Verify**: `inspect: ../dartclaw-public/CHANGELOG.md:1` – the entry covers plan/exec, skipped dependents, rename, council removal, and AndThen 1.0 without rewriting history.
  - **SATISFIES**: S04

- **TI06** Architecture, testing-profile, runner, README, and two prose scenario documents use the delivered workflow names and flow; the one-story scenario path is moved with `git mv`, and original smoke-test assertions remain recognizable.
  - **Verify**: `cmd: git diff --check` – renamed/edited prose has no whitespace errors.
  - **Verify**: `inspect: ../dartclaw-public/dev/testing/scenarios/workflow-story-and-implement-publish.md:1` – scenario command, heading, expected workflow identity, and cleanup path are consistent; compare the plan scenario's remaining old-name references.
  - **Verify**: `inspect: ../dartclaw-public/dev/state/PROMPT-SURFACES.md:108` – the renamed producer's declared nonempty path contract, nullable no-claim/capture projection, and shared schema-validation owners reflect story S01's contract fix; no separate simplify step is invented.
  - **SATISFIES**: S01, S04, SC01

- **TI07** The historical visual NDJSON fixture uses the current workflow literal without changing message structure, and the public retired-term inventory is exhausted by S01–S03 owners.
  - **Verify**: `inspect: ../dartclaw-public/dev/testing/profiles/visual/data/sessions/52222222-2222-4222-8222-222222222222/messages.ndjson:1` – only the workflow name inside the relevant message changed.
  - **Verify**: `cmd: ! git grep -n -i -e 'andthen-some:' -e 'andthen:ops' -e 'andthen:prd' -e 'andthen:quick-review' -e 'exec-spec' -e 'spec-and-implement' -e 'spec-ready' -e '--mode trade-off' -- ':!CHANGELOG.md' ':!dev/adrs/**' ':!dev/bundle/**'` – no tracked public match on the plan's Implementation scan surface; include untracked implementation changes in the manual inventory.
  - **SATISFIES**: S04, SC01, SC02

- **TI08** A real-provider `story-and-implement` run with a terse one-line FEATURE has a saved step trace showing either a readable nonempty emitted FIS path passed to `implement` or an explicit failed `spec` step, and records observed `implement` duration when reached.
  - **Verify**: `inspect: ../dartclaw-public/.agent_temp/andthen-rc4-live-qualification.md:1` – record exact FEATURE, plugin version, run ID, `spec` result/path, `implement` result/duration from task timestamps or `workflow_step_completed.durationMs`, and terminal status; inspect the referenced FIS/trace.
  - **SATISFIES**: S05, SC03

- **TI09** A real-provider `plan-and-implement` run on a committed small PRD completes successfully and saves its plan/FIS paths and implementation/review trace.
  - **Verify**: `inspect: ../dartclaw-public/.agent_temp/andthen-rc4-live-qualification.md:1` – record PRD, run ID, generated paths, successful implementation/review outcomes, and completed terminal status from the disposable fixture; a failed or skipped run does not satisfy S06.
  - **SATISFIES**: S06, SC03

- **TI10** One maintained inline custom runs through skill preflight with the installed plugin and completes its review aggregation/remediation path.
  - **Verify**: `inspect: ../dartclaw-public/.agent_temp/andthen-rc4-live-qualification.md:1` – record custom definition, run ID, passing preflight, surviving review/aggregate steps, and completed terminal status; a failed or skipped run does not satisfy S07.
  - **SATISFIES**: S07, SC03

- **TI11** The final story diff contains only S03-owned prose/fixture changes and preserves the four explicit non-goals and no-PR/no-public-app live boundary.
  - **Verify**: `cmd: git diff --name-status` – owned edits, `git mv` scenario rename, and no non-goal or public app path are accounted for.
  - **Verify**: `inspect: ../dartclaw-public/.agent_temp/andthen-rc4-live-qualification.md:1` – local/disposable origin and no PR creation are evidenced for each run.
  - **SATISFIES**: SC01, SC03

## Implementation Observations

- **DRIFT (minimum required-gate fix, cross-package release pin):** TI05's dated 0.27.2 changelog heading must move with every workspace `version:` pin, `dartclawVersion`, both Homebrew formulas, both Scoop manifests and their install URLs, and the generated config schema `$id`. `check_versions.sh` runs in the per-push fitness gate and rejects the heading while those pins remain at 0.27.1. The pin was advanced as one source change; release publication remains outside this story.
- **DRIFT (minimum required-gate fix, S01 ownership):** The real provider's first one-story implementation tried `Agent` for the required fresh review but the task tool filter denied `claude:Agent`. The two built-in `andthen:exec-plan` step allowlists now grant that exact provider tool. `ClaudeSettingsBuilder` maps only this explicit grant to native `Agent` permission so supported host `dontAsk` mode does not discard it. A focused test failed before the mapping and passes after it. No guard was relaxed.
- **DRIFT (minimum required-gate fix, S01 ownership):** The maintained three custom inline workflows' `verify-all` and `verify-recheck` Bash steps used `bash script {{workflow.runtime_artifacts_dir}}`, which BashStepRunner rejected as shell re-parsing around substituted input. Their existing executable scripts now receive the substituted path as an ordinary argument. A BashStepRunner test executes that shape with a path containing spaces. The fourth custom `multi-agent-review-inline.yaml` has the same two occurrences; **NOTICED BUT NOT TOUCHING** because that definition is outside the named three and did not block a required gate.
- **DRIFT (minimum required-gate fixture cleanup):** The exact retired-term sweep found 12 old-name occurrences in tracked `dev/testing/profiles/visual/data/dartclaw.db`. The visual profile merely copied this SQLite seed, while its current config and runtime use PostgreSQL, so the proven-dead binary fixture was removed rather than rewritten. Its historical records were not used by the S02 visual qualification.
- **Live result:** The final one-line story fixture synthesized a readable FIS, consumed its path, invoked fresh review and simplify through real `Agent` calls, completed its one-story plan, and reached terminal completion. The custom inline fixture passed preflight, review aggregation, and its full verification gate. Two Claude PRD runs reported terminal completion while their implementers bypassed `andthen:exec-plan`; the meaningful run left its generated story `pending` and code uncommitted. A bounded Codex run of that same committed PRD used the installed rc.4 plugin, completed its story with fresh review/simplify, passed separate story and plan reviews, and reached terminal completion with a `done` plan row. The Claude false-positive traces remain part of the qualification record. Exact run IDs, step durations, and traces are in `.agent_temp/andthen-rc4-live-qualification.md`.
