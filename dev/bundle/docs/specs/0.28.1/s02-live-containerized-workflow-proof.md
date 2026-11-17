# S02: Live containerized workflow proof

**Plan**: dev/bundle/docs/specs/0.28.1/plan.json
**Story-ID**: S02

## Feature Overview and Goal

**Intent**: A containerized coding workflow has never run live, so nobody knows what breaks between `implement-story` and a real project inside a `workspace` container. This story runs it, fixes what is broken on the container step path, records what only a toolchain or registry can fix, and settles where Codex rollouts land.

**Expected Outcomes**:

- [OC01] The maintainer runs `implement-story` with its agent steps in `workspace` containers against a Dart and a Node fixture, with Claude Code and with Codex, from one documented command that S05, S06 and S07 rerun unchanged.
- [OC02] Every provider and fixture run leaves a record of whether dependency install and the fixture's tests succeeded, with the failing command and its output, so stories S05 to S07 have a baseline.
- [OC03] No defect on the container step path other than a missing toolchain or missing registry access survives this story.
- [OC04] One recorded run says where DartClaw's Codex rollouts land with the stored-subscription dedicated Codex home in effect, host and container mode, and no Codex spawn ignores that home.


## Required Context

Paths are relative to the public repo root (`../dartclaw-public/` from the private repo), where this FIS executes from its exported copy and where `cmd:` proofs run; `docs/specs/` and `docs/research/` paths name this plan's private sources, exported to `dev/bundle/docs/`.

- `docs/specs/0.28.1/prd.md#fr3-live-containerized-workflow-step` – the live proof and its four acceptance criteria.
- `docs/specs/0.28.1/prd.md#fr4-codex-home-recheck` – the recheck and what may reach `LEARNINGS.md`.
- `docs/specs/0.28.1/plan.json#sharedDecisions` – "Containerized coding scenario": one command in the existing `container` profile, no new profile, no second scenario; stories S05 to S07 reuse it.
- `docs/specs/0.25/prd.md` (the "Containerized workflow-step composition is unit-tested only" and "workflows profile's Codex rollouts" bullets) – the two open items this story closes.
- `dev/testing/profiles/container/run.sh` – the server boot, credential gate, Postgres and teardown pattern the new command follows; `dev/testing/profiles/workflows/README.md` § Provider Setup – why that profile inherits `~/.codex`.
- `packages/dartclaw_workflow/test/fixtures/e2e_fixture.dart` – the one provider-to-role-model mapping (Claude and Codex presets) the scenario config reuses.
- `packages/dartclaw_kernel/lib/src/agent_execution.dart` (`containerJson`), `packages/dartclaw_runtime/lib/src/task/task_executor.dart` (the resolved `ExecutionPolicy` at task start) and `packages/dartclaw_runtime/lib/src/runtime/security_wiring.dart` (`acquireContainerAuthority` mints the container name) – the placement record.


## Acceptance Scenarios

- **S01 [OC01] [runtime] Claude Code runs both fixture stories in containers**
  - **Given** a container runtime answering, a host-held Claude credential, and a clean candidate
  - **When** the maintainer runs the scenario command for Claude Code on both fixtures
  - **Then** each `implement-story` run reaches a terminal state, every task the run created has an `agent_executions.container_json` naming the `workspace` profile (read through `GET /api/tasks/<id>`, `agentExecution.containerJson`) and none ran on the host, and the fixture's files under version control are unchanged afterwards

- **S02 [OC01] [runtime] Codex runs both fixture stories in containers**
  - **Given** a container runtime answering, a host-held Codex credential, and a clean candidate
  - **When** the maintainer runs the scenario command for Codex on both fixtures
  - **Then** each run reaches a terminal state with every task's `container_json` naming the `workspace` profile, as in scenario S01

- **S03 [OC01] [runtime] A missing credential or runtime fails the run instead of skipping it**
  - **Given** no host-held credential for the selected provider (or no container runtime)
  - **When** the scenario command runs for that provider
  - **Then** it exits non-zero, names the provider and the ways to supply a credential (or the missing runtime), and starts no workflow run, because an exit-0 skip would let an unproven run read as a pass
  - **Proof**: `cmd: env -u ANTHROPIC_API_KEY DARTCLAW_CONTAINER_DATA_DIR="$(mktemp -d)" bash dev/testing/profiles/container/coding.sh --provider claude; test $? -eq 1` – exit status 1, with the output naming Claude and `ANTHROPIC_API_KEY`

- **S04 [OC02] [runtime] Each provider and fixture leaves a result row, whatever the outcome**
  - **Given** a scenario run in which `dart pub get`, `npm install` or a test command fails inside the container (the expected state before stories S05 to S07)
  - **When** the run settles
  - **Then** the results file holds one row per provider and fixture with the install command and its exit status, the test command and its exit status, and for a failure the failing command and the tail of its output, taken from what the agent ran in the container; the same run exits 0 under `--baseline` and non-zero without it
  - **And** the Dart row records the fixture's `pubspec.lock` after the run against the committed one (the committed lock pins `test` below its latest version under `https://pub.dev`), so story S06 can show the documented lockfile consequence

- **S05 [OC03] [runtime] Only toolchain and registry failures remain**
  - **Given** the baseline from scenario S04
  - **When** the scenario is rerun after this story's fixes
  - **Then** every failing command in the results is a missing language toolchain binary or an unreachable package registry; any other cause (placement, worktree mount, authority, provider authentication, result capture, skill availability) was fixed with a regression test that fails on the pre-fix code

- **S06 [OC04] [runtime] A host Codex turn with the stored-subscription home leaves `~/.codex/sessions` alone**
  - **Given** a data dir holding a stored Codex subscription (without one, FR4 stays open and the report says so) and a host-mode server, so the dedicated home is in effect
  - **When** one Codex turn completes through DartClaw
  - **Then** no rollout with originator `dartclaw` first written after the run started appears under `~/.codex/sessions/`, and a rollout for that turn exists under the dedicated home while the server runs
  - **And** the check ran once, and its commands and both observations are in Implementation Observations under `Codex home recheck`
  - **Proof**: `cmd: grep -rq "Codex home recheck" dev/bundle/docs/specs/0.28.1` – the heading exists in the executed FIS copy

- **S07 [OC04] [runtime] Containerized Codex steps leave `~/.codex/sessions` alone**
  - **Given** a Codex run of the scenario (container mode); every Codex scenario run makes this check
  - **When** the run settles
  - **Then** no rollout with originator `dartclaw` first written after the run started appears under `~/.codex/sessions/`, and a Codex step that completed is the evidence the check was not vacuous
  - **Proof**: `cmd: bash dev/testing/profiles/container/coding.sh --provider codex --baseline` – exit 0


## Structural Criteria

- **SC01** The scenario command leaves nothing behind on any exit path, failure included: no container carrying its data-dir label (asserted by the command at teardown, failing the run otherwise), no temp data dir or fixture repo, and no change under the committed fixtures.
- **SC02** The command is the one documented entry point in the `container` profile: `dev/testing/README.md` names it, its port and its flags, and no new testing profile, config knob or second scenario exists.
- **SC03** The committed fixtures do not break the repository's own format and analyze gates.
- **SC04** A container step-path fix adds no writable mount beyond the task's own worktree: no writable `.git` directory, hooks directory or config mount to make a git command succeed in the container. An in-container git failure is recorded in the results, and the host-side commit sweep commits the work.


## Scope & Boundaries

### Work Areas

- `dev/testing/profiles/container/` – new `coding.sh`, a seed config for it under `data/`, and the two fixtures; the root `.gitignore` gains a negation for the Dart fixture's `pubspec.lock`.
- Container placement record on `agent_executions.container_json`: `packages/dartclaw_runtime/lib/src/task/task_executor.dart`, `task/task_service.dart` (`updateFields`), and `runtime/security_wiring.dart` / `runtime/harness_wiring.dart` for the container name.
- Whatever the live runs prove defective on the container step path (`packages/dartclaw_runtime/lib/src/task/task_executor.dart`, `runtime/harness_wiring.dart`, `container/`, `packages/dartclaw_core/lib/src/harness/`), each with a regression test.
- `dev/testing/README.md`, `dev/testing/profiles/workflows/README.md` (only if its Codex-home statement proves false), `CHANGELOG.md` (0.28.1 entry per user-facing fix), `dev/state/LEARNINGS.md` (only for a non-obvious trap).

### What We're NOT Doing

- A toolchain in the image, a `FROM dartclaw-agent` recipe, the missing-toolchain error (S05), the `registry` bridge surface and pub adapter (S06), the npm adapter (S07). Their absence is the baseline this story records; do not add network, mounts or tool binaries to make an install pass.
- Mounting or copying host `~/.claude`, `~/.codex` or a host plugin directory into a container to make a skill resolve – that breaks the credential boundary (ADR-055). A skill gap needing that is recorded, not built.
- The standalone lane (`workflow run --standalone`) and native Windows – the scenario covers `dartclaw serve`; standalone containers need a declared posture and are a separate proof.
- Showing container placement in the web UI – the record is read through the task API and the repository.
- A writable mount beyond the task's own worktree (a writable `.git` directory, hooks or config) to make an in-container git command succeed – it hands the agent hooks and config outside any reviewed diff. A git failure in the container is recorded; the host-side commit sweep commits.
- A GitHub remote, token or pull request: the workflow's publish lands on a local git remote.
- Changing the `workflows` profile's Codex setup. It keeps inheriting `~/.codex`; only a false sentence about it is corrected.


## Architecture Decision

**Approach**: One new script, `dev/testing/profiles/container/coding.sh`, in the existing `container` profile, modelled on `run.sh`: it boots `dartclaw serve` with a seed config declaring `container.enabled: true`, `tasks.execution: container` and the `workspace` profile, registers a per-run git copy of a fixture as a project whose publish target is a local bare remote, drives `dartclaw workflow run implement-story` through the connected CLI, and writes a results file. `--provider`, `--fixture` select a subset (default: both providers, both fixtures); `--baseline` makes install and test failures non-gating. The Codex home recheck (S06) is a one-off run recorded in this FIS, not a mode of the command.
**Why this over the floor**: the floor is extending `run.sh`, which already carries two modes and a chat-turn flow, or running the existing `workflow-live` canaries. Neither runs a workflow step in a container, and FR3 needs a command later stories rerun by name, with per-provider results.
**Flow**: materialize fixture into a temp git repo with a local bare origin → boot server (Postgres from `postgres.sh`) → `workflow run implement-story -p <project> -v FEATURE=<story text> --json` → read the run's tasks and their turn traces (`dartclaw traces show --json`) for each task's commands and results → read each task's `agentExecution.containerJson` through the task API → compare rollout files → teardown, assert nothing left → write results.


## Constraints & Gotchas

- **Root gates see the fixtures.** `dart format --line-length=120 .` and `dart analyze --fatal-infos` run over the whole repo (CI `Check` job). The Dart fixture's stub must compile and be formatted, or be excluded in `analysis_options.yaml`; its tests fail by assertion, not by compile error. `dev/testing/.gitignore` strips `tasks/`, `sessions/`, `**/projects/` and `*.key`-style names, so confirm with `git status` that every fixture file is tracked. The Dart fixture commits a `pubspec.lock` pinning `test` (and its transitive set) below the latest version, hosted at `https://pub.dev`; the root `.gitignore` ignores `pubspec.lock`, so add `!/dev/testing/profiles/container/fixtures/dart/pubspec.lock` beside its existing negations.
- **A fixture needs a public-registry dependency its tests cannot run without** (Dart: `test`; Node: one small pinned package the story's solution imports, tests on `node --test`), otherwise install is never exercised and stories S05 to S07 prove nothing.
- **Credentials per provider.** Claude: a stored setup-token under `DARTCLAW_CONTAINER_DATA_DIR` or `ANTHROPIC_API_KEY`. Codex: a stored subscription under that data dir or `CODEX_API_KEY`; the host `~/.codex` is never presented to a container. Where an unattended run has none, the `[runtime]` scenarios stay open and the report says so, never a skip.
- **AndThen skills inside the container.** `implement-story` calls `andthen:plan`, `andthen:exec-plan`, `andthen:review` and `andthen:ship` plus the `dartclaw-discover-*` skills. Container steps see skills only through what DartClaw provisions into the mounted workspace and generated state. A step that fails because a skill is unavailable is a step-path defect (scenario S05); fix it inside the boundary, or record it when only a boundary change would fix it.
- **Rollout detection** matches the first line of a new `rollout-*.jsonl` for `"originator":"dartclaw"`. A DartClaw server the operator runs concurrently confounds it; the command states that in its header.
- **Port 3343** for the scenario server (3341 and 3342 are `run.sh`).
- **`container.enabled: true` already routes the task lane to containers** (`ExecutionPolicyResolver.resolveForTask`); the seed config still declares `tasks.execution: container` so the proof does not depend on the default.

- **Placement record.** "Execution records naming container placement" (FR3) is `agent_executions.container_json`, written as `{"profile": <id>, "container": <name>}`. The executor holds the policy at task start (`task_executor.dart`, `runnerPolicy.containerProfile`), so it persists the profile there. The name is minted in `SecurityWiring.acquireContainerAuthority`; thread it back with one callback from the worker-creation site, which already holds the task id. If it needs more than a callback, persist `{"profile": <id>}` only and keep the name in the authority-start log line (task id and container name); record the choice in Implementation Observations. `coding.sh` checks placement through the task API's `agentExecution.containerJson`, never by log grep.
- The scenario drives `dartclaw serve` with the connected `workflow run`, not `--standalone`; proving the standalone lane would add a second run mode to the same command and is out of scope.
- The exit status is the acceptance verdict (0 only when every selected provider and fixture installed and passed its tests); `--baseline` is the recording mode. Per the plan's shared decision, S05 runs both fixtures with `--baseline`, S06 runs the Dart fixture without it, and S07 runs both fixtures with both providers without it.
- Install and test outcomes are read from the redacted, size-limited tool results in the persisted turn traces. Where a container step's traces drop a result, the story text tells the agent to echo each acceptance command's exit status and the command reads that instead.
- Publish lands on a per-run local bare remote with `pr.strategy: branch-only`, so no GitHub token is involved; a publish that cannot target a local remote is fixed in the scenario's project setup, not by changing publish.
- ASSUMPTION: the live scenarios need host-held Claude and Codex credentials and a container runtime on the executing machine, and S06 needs a stored Codex subscription – an executor without them leaves S01, S02, S04 to S07 open (FR4 stays open) and reports it.


## Implementation Plan

### Implementation Tasks

- **TI01** A Dart fixture and a Node fixture exist under `dev/testing/profiles/container/fixtures/` (`dart/`, `node/`), each a small project whose tests fail on its stub, with a story description for `implement-story` and acceptance commands (`dart pub get` / `dart test`; `npm install` / `npm test`) stated in that story. The Dart fixture commits a `pubspec.lock` pinned below the latest `test`, un-ignored through the root `.gitignore`.
  - **Verify**: `cmd: dart format --line-length=120 --output=none --set-exit-if-changed dev/testing/profiles/container && dart analyze --fatal-infos` – both pass with the fixtures present; the Dart fixture's `dart test` fails on the stub (checked in a temp copy after `dart pub get`); `cmd: git ls-files --error-unmatch dev/testing/profiles/container/fixtures/dart/pubspec.lock` – the lock is tracked.
  - **SATISFIES**: SC03, S01, S02

- **TI02** `coding.sh` boots the server for a selected provider and fixture and tears it down: seed config (templated paths), per-run git copy of the fixture with a local bare remote, credential and runtime gate that fails (S03), teardown asserting nothing is left (SC01).
  - Follow `dev/testing/profiles/container/run.sh` for Postgres, `DARTCLAW_CONTAINER_DATA_DIR`, trap cleanup and label-based container sweep.
  - **Verify**: the S03 `cmd:` – exit 1 naming the provider; `cmd: git status --porcelain -- dev/testing/profiles/container` – empty after any run.
  - **SATISFIES**: S03, SC01

- **TI03** The executor records each task's container placement on its `agent_executions.container_json` as `{profile, container}` (profile only if threading the name costs more than a callback, per Constraints), persisted through `TaskService.updateFields`.
  - **Verify**: `packages/dartclaw_runtime/test/task/task_executor_test.dart#records container placement on the agent execution` – new test: a task run under a container `workspace` policy leaves `containerJson` naming the profile (and the name when threaded), and a host-policy task leaves it null; `packages/dartclaw_runtime/test/task/task_service_test.dart#updateFields persists container placement on the agent execution` – new test reading it back through the repository
  - **SATISFIES**: S01, S02

- **TI04** `coding.sh` runs `implement-story` per provider and fixture, checks every task of the run for a `workspace` placement through `GET /api/tasks/<id>`, and writes `.agent_temp/container-coding/<UTC timestamp>/results.md` with the S04 row, the Dart row carrying the `pubspec.lock` diff; exit 0 only when every row passed, `--baseline` ignores install and test failures only.
  - Install and test outcomes come from the turn traces' recorded commands and results for the run's tasks, never from the agent's own summary. Depends on TI03.
  - **Verify**: `cmd: bash dev/testing/profiles/container/coding.sh --baseline` – exit 0; results has four rows, each with a placement-checked task list and an install and a test outcome, and the Dart rows show the lockfile diff.
  - **SATISFIES**: S01, S02, S04

- **TI05** The baseline (the S04 results table for both providers and both fixtures, failing commands and output tails, plus the classification of each failure as toolchain, registry or other) is recorded in this FIS's `## Implementation Observations` under the heading `Container coding baseline`, before any defect fix lands.
  - **Verify**: `cmd: grep -rq "Container coding baseline" dev/bundle/docs/specs/0.28.1` – the heading exists in the executed FIS copy.
  - **SATISFIES**: S04

- **TI06** Every failure in the baseline that is neither a missing toolchain binary nor missing registry access is fixed in the container step path with a regression test that fails on the pre-fix code, adding no writable mount beyond the task's own worktree (an in-container git failure is recorded and the host-side commit sweep commits), and a user-facing fix gets a 0.28.1 `CHANGELOG.md` entry; a failure that only a boundary change (see What We're NOT Doing) could fix is recorded in Implementation Observations instead.
  - **Verify**: `cmd: dart analyze --fatal-infos && dart test --reporter=failures-only -x slow packages/dartclaw_runtime` – green, including the golden `packages/dartclaw_runtime/test/container/container_manager_test.dart#start builds the exact docker create argv — the full container security boundary` (a writable mount reddens it), plus the regression tests named in Implementation Observations; `cmd: bash dev/testing/profiles/container/coding.sh --baseline` – every remaining failing command is a toolchain or registry failure.
  - **SATISFIES**: S05, SC04

- **TI07** Codex runs of the scenario compare `~/.codex/sessions` rollouts before and after and fail on a new `dartclaw` rollout.
  - **Verify**: the S07 `cmd:` – exit 0; the check names the count of Codex steps that completed.
  - **SATISFIES**: S07

- **TI08** The Codex home recheck runs once: a host-mode Codex turn with the stored-subscription dedicated home in effect, and the container-mode observation from the Codex scenario run. Its commands and both observations are recorded in Implementation Observations under `Codex home recheck`. Any Codex spawn path found writing under `~/.codex` while a dedicated home is in effect is fixed with a test asserting that spawn's `CODEX_HOME`; the outcome (explained by the system-home default, or fixed) goes to `dev/state/LEARNINGS.md` only if it is a trap the code and docs do not already carry, and `dev/testing/profiles/workflows/README.md` is corrected only if it states something the recheck disproved.
  - Existing assertions to extend, not duplicate: `packages/dartclaw_core/test/harness/codex_harness_test.dart` (host dedicated and isolated homes), `packages/dartclaw_runtime/test/runtime/workflow_probe_environment_test.dart` (probe lane).
  - **Verify**: the S06 `cmd:` – the heading exists; `cmd: dart test --reporter=failures-only packages/dartclaw_core/test/harness/codex_harness_test.dart packages/dartclaw_runtime/test/runtime/workflow_probe_environment_test.dart packages/dartclaw_runtime/test/runtime/provider_resolution_test.dart` – green.
  - **SATISFIES**: S06, S07

- **TI09** `dev/testing/README.md` names the command, port 3343, `--provider`, `--fixture` and `--baseline` in its profile table; the script header documents prerequisites, exit codes and the concurrent-server caveat.
  - **Verify**: `cmd: git grep -n "container/coding.sh" -- dev/testing/README.md` – a table row matches.
  - **SATISFIES**: SC02

## Discovered Requirements

- **Collect before profile-owned teardown**. **Description**: Generate the disposable instance’s `implement-story` from the shipped canonical definition with only existing `gitStrategy.cleanup.enabled: false`; retain its worktree until the collector reads the actual lockfile, then let the profile EXIT trap remove all run resources. **Rationale**: Terminal-failed workflows otherwise delete the unpublished post-run lockfile before the connected CLI returns. **Interpretation**: Resolution Ladder rung 2 (Widen): the existing cleanup property and this FIS’s lockfile/teardown intent establish an operational collection override. Keep every step, role and other definition field unchanged, assert their equality after generation, and preserve all container boundaries. This adds no product configuration, maintained workflow copy or second scenario. **Traced from**: TI02/TI04/TI06 and SC01. **Date**: 2026-11-17.

- **Workflow traces must cover each step turn**. **Description**: Route workflow work, follow-up and finalizer outcomes through the existing task trace writer. **Rationale**: The first live Claude/Dart run accepted two containerized steps but `GET /api/traces` returned zero rows; workflow execution returns before the generic task trace path. **Interpretation**: TI06 includes this result-capture defect. Record the first diagnostic baseline with unknown command outcomes, fix capture, then rerun the four-row baseline; TI05 cannot record command output before the missing recorder is repaired. This changes no acceptance requirement. **Traced from**: TI04/TI05/TI06. **Date**: 2026-11-17.
- **Live continuity is distinct from durable resume**. **Description**: For a structured step, request a durable provider session only when the harness supports it; otherwise run its immediate finalizer on the same leased worker only when it declares live session continuity. **Rationale**: Container Codex correctly has a non-durable auth-clean home, but the first Codex run failed before its work turn because the workflow always requested durable resume. **Interpretation**: Preserve the existing failure when a durable-capable harness omits its promised ID, and reject any explicit persisted ID on a harness without durable-resume capability. Use the existing capability contract; change no home or credential boundary. **Traced from**: TI06/TI07. **Date**: 2026-11-17.

## Implementation Observations

### Container coding baseline

- First diagnostic run: Claude/Dart, workflow `05c0082d-d1aa-4912-ade6-f0702579673b`, logs under `.agent_temp/container-coding/20261117T143953Z.ddtsNI/`. The classifier and specification tasks were accepted, both with API placement `{"profile":"workspace"}`. `GET /api/traces?limit=10` and each completed task's filtered query returned zero traces. Install/test outcomes are unknown because the recorder is missing; classification: other (result capture). Cancelled this diagnostic run after proving the missing trace path; this is not acceptance proof. The complete baseline will follow the recorder fix.
- Second diagnostic run `ca52f1f2-c9b0-468a-85af-d2c778f1b0fb` confirmed another missing link: `TaskWiring` did not pass the existing storage trace service into `TaskExecutorServices`. A composition-root regression (`headless_file_storage_test.dart#standalone workflow execution reloads its completed run from the file store`) failed with expected one persisted trace, actual zero, then passed after the one-line wiring fix. The per-turn regression `task_executor_workflow_oneshot_test.dart#workflow turn traces retain work and finalizer results` failed with expected two traces, actual zero, then passed with failed shell output retained. Second diagnostic logs: `.agent_temp/container-coding/20261117T145036Z.CeJrgG/`; cancelled before rerunning against the fixed composition.
- Baseline `.agent_temp/container-coding/20261117T150613Z.u3TVv6/`: Claude/Dart completed, with both `dart pub get` and `dart test` exiting 127 and an unchanged lockfile. Claude/Node failed before the acceptance commands: an upstream 429 reached the CLI as compressed binary, then its NUL-bearing error text caused PostgreSQL SQLSTATE 22021 while persisting run context. The adapter forwarded the client's `Accept-Encoding` choices but always stripped the response encoding after Dart's gzip-only decompression. Classification: other (provider HTTP mediation). Regression `provider_adapter_test.dart#negotiates only response compression the host can decode on provider refusals` fails before the fix, showing `gzip, deflate, br, zstd` forwarded instead of the host's `gzip` negotiation.
- Bundled skill-link diagnosis: the runtime's `WorkspaceSkillLinker` pointed task-worktree `.agents/skills/dartclaw-*` and `.claude/skills/dartclaw-*` at absolute host data-dir caches outside the mounted worktree. Its existing `symlinksEnabled: false` mode only copied on Windows and preserved matching old symlinks. The regression `workspace_skill_linker_test.dart#disabling symlinks replaces existing links with self-contained skill copies` fails with an actual link instead of a directory; `headless_runtime_test.dart#task worktree native skills remain readable without the host cache` fails after the host cache is hidden. Reuse that copy mode for runtime-created worktrees, with no new mount or config key. Resolution Ladder rung: Widen (existing materialization owner and FIS SC04).
- Codex diagnostic run `2dc8649d-d758-4fb5-99f2-1495ccfde4a8` failed at `detect-spec-input` before any model work: `UnsupportedHarnessCapabilityException: CodexHarness (non-durable CODEX_HOME) does not support provider session resume`. Evidence: `.agent_temp/container-coding/20261117T152901Z.AJeG19/`. The capability regression covers live continuity both enabled and disabled, an explicit persisted ID, and a durable-capable provider with live continuity that omits its promised ID. Reinstating the unconditional durable-resume request makes both non-durable work turns fail before invocation (`.agent_temp/s02-live-continuity-mutation.log`: `+1 -2: Some tests failed.`); the explicit persisted-ID rejection remains green. The corrected full one-shot suite passes 38 tests.

#### DRIFT

- spec-stale: TI05's complete pre-fix baseline cannot exist while workflow turns persist no traces; record the diagnostic failure first, repair the existing trace path, then execute the complete baseline | Stale targets: TI05 in this FIS | –

### Codex home recheck

- Host command: `bash .agent_temp/s02-codex-home-recheck.sh` (disposable server on port 3344, host execution, stored subscription selected from `~/.dartclaw/credentials/codex`, before/after rollout inventories taken while the server ran). Result: `CODEX_HOST_CHECK_OK`, one new `dartclaw` rollout in the dedicated store and zero new `dartclaw` rollouts under `~/.codex/sessions`. Evidence: `.agent_temp/s02-codex-home-recheck.json`, `.agent_temp/s02-codex-home-recheck.log`, `.agent_temp/s02-codex-host-server.log`. No spawn ignoring the dedicated home was found.
- The first host attempt completed the turn but could not prove the positive rollout observation: Codex Desktop's inherited `CODEX_INTERNAL_ORIGINATOR_OVERRIDE` labelled it `Codex Desktop` despite DartClaw's client identity. Clearing that parent-only override in the profile and one-off launcher produced the positive evidence above. This is a fixture environment correction, not a provider credential fallback or a runtime home change.
- Existing host/probe spawn assertions: `dart test --reporter=failures-only packages/dartclaw_core/test/harness/codex_harness_test.dart packages/dartclaw_runtime/test/runtime/workflow_probe_environment_test.dart packages/dartclaw_runtime/test/runtime/provider_resolution_test.dart` → exit 0, `+98: All tests passed!`. Container observations are recorded in the complete baseline below.

### Boundary readings and preserved scope

- Placement is persisted as `{"profile":"workspace"}`. The task executor owns the resolved policy; obtaining the minted container name would require carrying a new callback through the runtime composition rather than one callback at an existing worker creation site. This takes the FIS's explicit profile-only option. Container names remain in authority-start logs.
- Native AndThen plugins remain unavailable in the auth-clean container. The live Codex specification task's filesystem inventory contains only the four copied `dartclaw-*` skills, while the host preflight resolves the operator's AndThen installation. The bundled discovery skill was read successfully in the container. ADR-040 makes AndThen an operator-installed provider prerequisite and forbids runtime cloning/installing/rebranding; this FIS explicitly forbids host plugin mounts/copies and permits recording that gap. Resolution Ladder: Widen established the ownership; Work around takes TI06's sanctioned boundary exception. No host plugin directory or login directory was copied or mounted. The live pipeline and fixture outcomes are proved separately from native AndThen skill availability. S05–S07 must retain this limitation; adding a toolchain or registry adapter cannot establish container-native plugin availability.
- The source fixtures are intentionally assertion-red projects. The command snapshots their bytes before execution, compares them in its EXIT trap, and confines all agent changes to disposable copies. TI02's literal `git status` is meaningful after the story commit; during development its own newly created profile files are expected worktree changes.
- Mechanical tidy: `packages/dartclaw_testing/CLAUDE.md` no longer says the local fitness gates run in CI. This corrects an already disproven statement in the section changed for the fake harness's independent live-continuity option.

- Codex/Dart capability retry `2a713018-7322-45eb-ba6d-c78682063af7` reached ship with five completed container steps; both acceptance commands exited 127 (`/bin/sh: 1: dart: not found`), the Dart lock was unchanged, and the system-home inventory found zero new DartClaw rollouts. Its ship step requested input for those expected toolchain and inaccessible in-container Git observations, so the recorder rejected `awaitingApproval` and exited 1. This is diagnostic evidence, not a terminal baseline pass. Fixture instructions now explicitly require a truthful report of these expected limitations, host commit/publication, and no operator-input request solely for them. No outcome override or auto-approval was added.
- Recorder regression `coding_results_test.py#test_codex_rollouts_are_checked_after_an_early_collection_failure` failed before moving the final rollout inventory into `finally`; the corrected five-test suite passes. Every Codex attempt now records the after inventory even when CLI startup or placement collection fails.

### External live-proof gate

- `andthen:triage --auto` diagnosis of the full-matrix failure: `.agent_temp/container-coding/20261117T154618Z.IWX9d6/claude-dart-run.json`, run `0c768323-6eea-4eb6-bac1-04c68159ef6a`, records `Skill introspection failed for provider "claude" ... You've hit your 5-hour limit · resets 8:30pm (Europe/Stockholm)`. No child tasks were created. The profile exited 1, rejected vacuous placement evidence, removed its labelled container and disposable resources, and did not alter its source fixtures. Root cause: provider subscription capacity at host preflight, before container work, rather than a local authentication, placement, registry or toolchain defect. No local repair can reset that capacity; changing credentials or waiting for the stated reset is external input. The four-row proof was open at that point; the operator subsequently replaced the stored Claude credential, and the fresh final matrix below passed.
- The qualification stories distinguish failed acceptance from a human decision: after attempting both commands, a failure is `step_outcome.outcome: failed`, never a claim that verification passed and never `needsInput` solely for the documented toolchain/registry/Git limitations. The recorder uses the run's validated semantic outcome as well as task status, and requires its current failing task to have a recorded nonzero acceptance command. Its regression rejects unrelated or absent failure-task IDs; `awaitingApproval`, paused and cancelled states remain failures. This follows the FIS's permitted terminal-failed baseline, without an outcome override.

- Terminal-failed Codex/Dart diagnostic `d7f9c07c-c6be-40b5-a986-50f7a23d6087` records both acceptance commands at exit 127 and two completed Codex steps, but the collector rejected it because normal workflow cleanup had already removed its unpublished lockfile. Retention is an existing per-definition `gitStrategy.cleanup.enabled: false` property. A diagnostic attempt using the nonexistent global `workflow.cleanup.enabled` was rejected at startup (`.agent_temp/container-coding/20261117T155037Z.UOl7no/`), then removed. The collector must retain a trustworthy post-run snapshot before the profile EXIT trap deletes its resources; no failed lock comparison is a pass. The published-remote lockfile regression remains as coverage for already-delivered trees.

### Accepted Codex baseline and teardown proof

`DARTCLAW_CONTAINER_DATA_DIR=/Users/tobias/.dartclaw bash dev/testing/profiles/container/coding.sh --provider codex --baseline` → exit 0, with results under `.agent_temp/container-coding/20261117T155301Z.D7CNTI/`:

| Provider | Fixture | Run | Install | Test | Completed Codex steps | New system-home rollouts | Dart lock |
|---|---|---|---|---|---|---|---|
| Codex | Dart | `26f9e2d5-497f-4c5c-88ca-faa7eaa65928` | `dart pub get`: 127 | `dart test`: 127 | 2 | 0 | unchanged |
| Codex | Node | `798f3ead-a4ad-45bb-91ca-e8f272a53507` | `npm install`: 127 | `npm test`: 127 | 2 | 0 | n/a |

Every recorded task has API placement `{"profile":"workspace"}`. Both workflows are terminal `failed`, with the current failed step's validated outcome linked to both recorded command failures. Output is `/bin/sh: 1: dart: not found` or `/bin/sh: 1: npm: not found`; classification: missing toolchain. These are baseline passes, never successful dependency installation or fixture tests. The retained worktree supplied the Dart lockfile. The profile exited 0, its byte-for-byte source-fixture trap passed, and an independent check found both referenced run roots absent (including repos, data and retained worktrees) and `docker ps -aq --filter label=dartclaw.data-dir` empty.

Normal-mode counterproof: `DARTCLAW_CONTAINER_DATA_DIR=/Users/tobias/.dartclaw bash dev/testing/profiles/container/coding.sh --provider codex --fixture dart` → exit 1, `FAIL: Install, test or workflow failed; see recorded command output.` Run `7d74fb60-c016-4109-b855-3093e133dd9c`, both commands 127, two completed Codex steps and zero system-home rollouts; evidence `.agent_temp/container-coding/20261117T155816Z.s2q05q/`. An independent check again found its retained run root/worktrees/repos/data and all data-dir-labelled containers absent. This proves cleanup for both profile success and failure exits.

### Executed development proofs

- Fast tier (the exact `Key Development Commands` row) → exit 0: analyzer `No issues found!`; kernel `+1430: All tests passed!`; core `+1757 ~19: All other tests passed!`; search `+62: All tests passed!`; workflow `+2133 ~11: All other tests passed!`; runtime `+5695 ~25: All other tests passed!`; CLI with `-x slow` `+856 ~3: All other tests passed!`. Skips are the runner's default live/integration/slow exclusions; the FIS's real-provider scenarios are separate executed proof, not inferred from these suites. Full tier is delegated to the plan runner under `--no-full-tier`.
- TI01: `dart format --line-length=120 --output=none --set-exit-if-changed .` → exit 0, `Formatted 2230 files (0 changed)`; `dart analyze --fatal-infos` → exit 0, `No issues found!`; `git ls-files --error-unmatch dev/testing/profiles/container/fixtures/dart/pubspec.lock` → exit 0, exact fixture lock path. The temporary Dart and Node copies installed their dependencies successfully, then failed by assertions on the zero-return stubs (expected 4, actual 0); evidence `.agent_temp/s02-fixture-proof/`.
- TI02/S03: missing-Claude-credential proof → exit 1 naming Claude, `dartclaw auth claude` and `ANTHROPIC_API_KEY`; missing-runtime proof with non-answering docker/podman stubs → exit 1, `FAIL: no Docker or Podman container runtime answered.` Neither launches a workflow. Evidence `.agent_temp/s02-missing-credential.log` and `.agent_temp/s02-missing-runtime.log`.
- TI03: task executor and task service placement proofs pass, including host clearing a stale placement; `.agent_temp/s02-placement-final.log` and `.agent_temp/s02-targeted.log`.
- TI05: `grep -rq "Container coding baseline" dev/bundle/docs/specs/0.28.1` → exit 0.
- TI06: `dart analyze --fatal-infos && dart test --reporter=failures-only -x slow packages/dartclaw_runtime` → exit 0, `No issues found!`, `+5680 ~20: All other tests passed!` (`.agent_temp/s02-runtime-final-proof.log`); exact container security-boundary golden → exit 0, `+1: All tests passed!` (`.agent_temp/s02-container-golden.log`). Provider adapter 51, native skill linker 15, composition-root skill-copy 1, trace composition 1 and workflow one-shot 38 tests pass after their recorded red regressions. Testing package → exit 0, `+58: All tests passed!`.
- TI07/S07: the accepted two-fixture Codex baseline above exits 0, with two completed Codex steps per fixture and zero new system-home rollouts per run.
- TI08/S06: `grep -rq "Codex home recheck" dev/bundle/docs/specs/0.28.1` → exit 0; the existing host/probe/provider-resolution command → exit 0, `+98: All tests passed!`; the live host positive/negative observations are recorded above.
- TI09: `git grep -n "container/coding.sh" -- dev/testing/README.md` → exit 0, profile table line 30 names command, port, selectors, credential source and results.
- Generated-workflow fidelity: `.agent_temp/s02-definition-proof-final.json` reports all canonical fields unchanged after restoring only cleanup.enabled, eight steps and five unchanged role patterns. `e2e_fixture_test.dart` → exit 0, `+17: All tests passed!`.
- Diagram: `tasks-turn-recording.svg` passes XML validation, rendered light/dark variants were visually inspected without clipping/overlap, and all three source-link hover hit areas were exercised. No app UI changed.

### Independent review repair round

Reviewed: fresh reviewer ran `andthen:review --quick --fix --auto` across S02's code, tests, profile, fixtures, docs and FIS claims. Four validated findings were fixed: select the latest command attempt before validating its evidence (HIGH); match command tools `shell`/`Bash` rather than report-writing tools (MEDIUM); require the existing `/api/config` metadata path to match the profile's unique config before connected CLI launch (MEDIUM); emit all Markdown summary rows before detailed sections (LOW). The added regressions were red before each repair. `.agent_temp/s02-review-final-python.log` → exit 0, `Ran 9 tests`, `OK`; `git diff --check` → exit 0. No code finding remains open from the quick review. The live four-case proof subsequently passed as recorded below.

Direct substance/wiring scan: no new TODO, placeholder implementation, skipped test, suppression or canned-success path was found. The fixtures' zero-return stubs are intentional assertion-red inputs and do not belong to repository package suites. Placement writes route through `TaskService.updateFields`; workflow traces reuse `_persistTrace`; worktree skill copies reuse `WorkspaceSkillLinker`; retained workflow generation is called by the thin profile config helper and uses the existing materializer/parser/emitter inside `E2EFixture`. Root analysis is clean without a new dependency or lint suppression. The provider role mapping remains owned solely by `E2EFixture`.

### Final four-case baseline

`DARTCLAW_CONTAINER_DATA_DIR=/Users/tobias/.dartclaw bash dev/testing/profiles/container/coding.sh --baseline` → exit 0 (`.agent_temp/s02-full-matrix-reviewed.log`). Its startup gate ran nine Python tests successfully. Results and retained raw command evidence: `.agent_temp/container-coding/20261117T160539Z.iHFMJK/`.

| Provider | Fixture | Run | Install exit | Test exit | Placement-checked tasks | New system-home Codex rollouts | Dart lock |
|---|---|---|---|---|---|---|---|
| Claude | Dart | `32f4e333-21e6-4a6b-8ddf-ef1de137ee73` | 127 | 127 | 2/2 workspace | n/a | unchanged |
| Claude | Node | `bd0164ed-48ff-4085-b24c-025a06dd76c4` | 127 | 127 | 2/2 workspace | n/a | n/a |
| Codex | Dart | `e57dd9ed-0416-4de8-81f6-8c8f61d92608` | 127 | 127 | 2/2 workspace | 0 | unchanged |
| Codex | Node | `79f97ce9-9f06-432f-9df8-d919e3c5f1d5` | 127 | 127 | 2/2 workspace | 0 | n/a |

All four workflows reached terminal `failed` after attempting both commands. Every install/test failure is `/bin/bash: line 1: dart: command not found`, `/bin/sh: 1: dart: not found`, or the corresponding `npm` message. Classification: missing toolchain, not registry access. Each Codex row has two completed agent tasks, including a succeeded classifier, so its rollout observation is non-vacuous. The profile's EXIT trap passed its unchanged-fixture check and removed the retained run root, repos, worktrees, data and every exact data-dir-labelled container. The same assertions were independently repeated for each recorded task after exit (`git-projection.json`). Foreign pre-existing containers were left in place.

A post-run report inspection found that `git status; echo GIT_STATUS_EXIT=$?` can have tool success `true` while retaining inner Git exit 128. The original failure-only projection omitted it. The regression `test_git_results_preserve_a_compound_command_with_an_inner_failure` failed `0 != 1`, then passed after the report changed to neutral `gitCommands`, preserving command, output and tool-success flag for every Git shell call without inferring an inner exit or parsing prose. The final Python suite passes ten tests (`.agent_temp/s02-python-final.log` and the final direct run). Per the session's bounded repair decision, `.agent_temp/s02-project-git-results.py` replayed only this pure projection over all four retained raw traces and regenerated `results.md`/`results.json`; original live receipts remain `results-live.md`/`results-live.json`. It revalidated each acceptance result with the reviewed parser, proved every other live row field unchanged, and changed no acceptance verdict, placement, rollout observation or teardown. `git-projection.json` records 1/1/1/2 Git command results for Claude/Dart, Claude/Node, Codex/Dart and Codex/Node respectively. No second scenario or permanent replay mode was added.

### Chain Attestation

- OC01: scenarios S01–S03 are closed by TI01–TI04 and TI09: the one documented command ran both fixtures with both providers, all eight API task placements name workspace, both credential/runtime absence gates fail before a workflow, and byte snapshots plus teardown assertions preserve the committed fixture inputs.
- OC02: scenario S04 is closed by TI04–TI05: the final four-row baseline retains actual command output and exit markers, both Dart lock comparisons, and Git command evidence; normal mode's recorded exit-1 counterproof rejects these same missing-toolchain failures.
- OC03: scenario S05 is closed by TI06's regression-proven placement, trace composition, HTTP compression, native-skill materialization and live-session finalizer repairs. Remaining acceptance-command failures are missing toolchains. Provider-native AndThen availability is the explicitly sanctioned FIS/ADR-040 boundary exception recorded above; no host login/plugin directory or extra writable mount was introduced.
- OC04: scenarios S06–S07 are closed by TI07–TI08: the qualifying host turn produced a dedicated-home rollout and zero new system-home rollouts; each final container Codex run completed real tasks and produced zero new system-home DartClaw rollouts. Host/probe spawn assertions pass 98 tests.
- Discovered requirement, workflow traces: work and finalizer outcomes reuse the existing trace writer; per-turn and composition-root red→green regressions plus all eight live task traces prove both links.
- Discovered requirement, live continuity: durable-capable missing-ID failure and unsupported explicit resume remain enforced; the capability matrix passes 38 tests and both real auth-clean Codex fixtures completed work/finalizer pairs without a durable home.
- Discovered requirement, collection timing: the existing materializer/parser/emitter generates the disposable cleanup override, full normalized definition comparison preserves every other field, actual retained lockfiles were read, and success/failure profile exits independently removed retained resources.

All TI01–TI09 proof targets have now executed. The only scope exception is provider-native AndThen availability at the documented credential boundary. TI05's pre-fix complete-table impossibility is the recorded `spec-stale` drift; diagnostic failures, discarded evidence and the failed normal-mode counterproof remain visible. No Learnings entry was added because the non-obvious originator override is encoded in the launcher comment and this executed record. `CHANGELOG.md` holds the required three user-facing entries, but also contains a pre-existing foreign reorder and is deliberately left wholly uncommitted under the shared-worktree rule.

Final exact placement proofs: executor title filter → exit 0, `+2: All tests passed!`; service title filter → exit 0, `+1: All tests passed!`. Exact TI01 fixture format check → exit 0, `Formatted 3 files (0 changed)`; analysis → exit 0, `No issues found!`. Package instructions now name copy materialization, per-turn traces and the durable/live finalizer distinction. These are documentation updates to changed component contracts, not additional runtime behavior.
