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
