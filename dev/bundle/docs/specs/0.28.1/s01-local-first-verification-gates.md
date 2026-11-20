# Local-first Verification Gates

**Plan**: dev/bundle/docs/specs/0.28.1/plan.json
**Story-ID**: S01

## Feature Overview and Goal

**Intent**: GitHub `Checks` stops running the timing-sensitive heavy gates that failed 8 of the last 8 red runs, and the release check proves those gates, Linux included, locally on the exact candidate.

**Expected Outcomes**:

- [OC01] A push gets a GitHub verdict from `Check` (format, analyze, architecture) and `PowerShell scripts` only, and the release check's `ci` gate asks for exactly those two jobs.
- [OC02] Every release candidate can carry Linux evidence from a local `linux` gate that runs the local gates and the container posture profile inside a Lima VM on the same commit.
- [OC03] The public release and development docs state this split, so nobody expects GitHub to run tests, fitness, PostgreSQL or container posture.


## Required Context

Paths are relative to the public repo root (`../dartclaw-public/` from the private repo), where this FIS executes from its exported copy and where `cmd:` proofs run; `docs/specs/` and `docs/research/` paths name this plan's private sources, exported to `dev/bundle/docs/`.

- `docs/specs/0.28.1/prd.md#fr1-fast-github-check-heavy-gates-local` – the CI cut and its doc acceptance criteria
- `docs/specs/0.28.1/prd.md#fr2-linux-lane-on-lima` – the `linux` gate contract
- `docs/specs/0.28.1/prd.md#edge-cases` – broken VM and candidate-changed recoveries
- `docs/specs/0.28.1/prd.md#constraints` – binding: a story never carries a task that re-runs a release gate; story proof is its own tests plus the `fast` / `full` tiers
- `dev/tools/release_check.dart#_gates` – gate table, `_ciJobs`, `execute`, the candidate-identity checks the lane inherits
- `apps/dartclaw_cli/test/tool/release_check_test.dart` – fixture with fake `dart`, `gh`, gate scripts on `PATH`; extend it with a fake `limactl`
- `dev/testing/profiles/container/run.sh` – the `--ci` posture profile the lane runs as root


## Acceptance Scenarios

- **S01 [OC01] Push runs only the fast checks**
  - **Given** the repository's `Checks` workflow
  - **When** a commit is pushed
  - **Then** it runs the `Check` job (dependency install, embedded-asset generation, format, analyze, architecture) and the `PowerShell scripts` job, and no other job
  - **And** no step in it runs the workspace tests, the fitness functions, the PostgreSQL contract or the container posture profile

- **S02 [OC01] The `ci` gate requires exactly the two remaining jobs**
  - **Given** a successful push-triggered `Checks` run on the full HEAD SHA
  - **When** `release_check.sh --gate ci` runs and the run's jobs are `Check` and `PowerShell scripts`, both successful
  - **Then** the gate passes and its receipt records the run URL
  - **And** when either job is missing or not successful, the gate fails naming it

- **S03 [OC02] The lane proves the candidate on Linux**
  - **Given** a clean committed candidate, `limactl` on `PATH` and the Lima VM present
  - **When** `release_check.sh --version <v> --gate linux` runs
  - **Then** the candidate's exact commit is run inside the VM: the local gates, then `dev/testing/profiles/container/run.sh --ci` as root
  - **And** the gate passes only when both pass, recording one `linux` receipt whose log holds the combined in-VM output, including the commit it ran

- **S04 [OC02] `--local` includes the lane, never `ci`**
  - **Given** a clean committed candidate
  - **When** `release_check.sh --version <v> --local` runs
  - **Then** the `linux` gate runs after the other local gates and `ci` does not run
  - **And** the in-VM run it triggers does not itself start a `linux` or `ci` gate and makes no GitHub API or Actions call (no `gh`)

- **S05 [OC02] No Lima fails with the install command**
  - **Given** `limactl` is not on `PATH`
  - **When** the `linux` gate runs
  - **Then** it fails with a message naming `brew install lima`, with a failed receipt and no VM work attempted

- **S06 [OC02] A failing in-VM step fails the lane and is named**
  - **Given** one in-VM local gate (for example `tests`) exits non-zero
  - **When** the `linux` gate runs
  - **Then** the gate fails, its log names that gate, and the container posture profile does not run after it
  - **And** when the gates pass but the container posture profile exits non-zero, the gate fails and its log names the profile

- **S07 [OC02] The VM is created once from the template and reused**
  - **Given** no VM of the lane's name exists
  - **When** the `linux` gate runs
  - **Then** the VM is created from the checked-in template and then used
  - **And** when the VM already exists, a second run reuses it without creating another
  - **And** when the VM exists but cannot be started or reached, the gate fails and its log names the VM and how to recreate it from the template

- **S08 [OC02] [runtime] Lima accepts the checked-in template**
  - **Proof**: `cmd: limactl validate dev/tools/lima/linux.yaml` – exit 0 on a machine with Lima (the lane's full run is release-preparation evidence, not a story task, per the binding constraint)

- **S09 [OC03] Docs state the split**
  - **Given** the public docs a maintainer reads before a push or a release
  - **When** they look up what GitHub runs, which local gates carry the rest, and how the squash commit is qualified
  - **Then** they state: GitHub `Checks` runs `Check` and `PowerShell scripts` only; tests, fitness, PostgreSQL and container posture run through the local gates and the `linux` gate; the squash-commit rule requires those two jobs green on the exact SHA; local results carry to the squash commit through the qualification ledger's input comparison, since a squash commit has the branch tip's Git tree
  - **And** none claims a pushed commit that breaks a test turns GitHub red: GitHub stays green and the local `tests` gate fails


## Structural Criteria

- **SC01** No public doc outside `CHANGELOG.md` and the ADR records still names the removed jobs or a four-job rule.
- **SC02** The Lima template and the lane's in-VM invocation make no GitHub API or Actions call: the lane runs no `gh` command and starts no `ci` gate in the VM. Pinned, checksum-verified release-asset downloads (dependency hooks such as llamadart, and `dev/tools/build.sh` for the `build` gate) are allowed.
- **SC03** The VM shares no host directory with the guest (no shared `.dart_tool`, build outputs or test data); the candidate reaches it as a committed snapshot only.


## Scope & Boundaries

### Work Areas
- `.github/workflows/ci.yml`
- `dev/tools/release_check.dart` and its test `apps/dartclaw_cli/test/tool/release_check_test.dart`
- `dev/tools/lima/linux.yaml` (new Lima template)
- Public docs: `dev/guidelines/RELEASE_PREPARATION.md`, `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md`, `dev/architecture/architecture-governance.md` (§ CI, § Governance Layers prose), `CLAUDE.md` (and its `AGENTS.md` link), `README.md`, `dev/testing/README.md` (`container --ci` row), the header comments of `dev/testing/profiles/container/run.sh` that describe a CI job, `dev/guidelines/TESTING-STRATEGY.md` (PostgreSQL contract line), `dev/state/LEARNINGS.md` (the `release_check.sh is not CI` bullet this change makes false)

### What We're NOT Doing
- Replacing GitHub Actions or moving to another runner – failures were test failures, not runner infrastructure (PRD out of scope).
- Running the lane for real from a story task, or any other release gate – `RELEASE_PREPARATION.md` reserves release gates to release preparation.
- A Parallels VM as release lane, or editing `PARALLELS_LINUX_AGENT_VM.md` beyond what the release docs need – that guide stays for desktop-agent use.
- x64 Linux test runs – the tag-time release matrix proves x64.
- CHANGELOG § 0.28.1 and architecture "Current through" markers – story S09 owns them.
- A config knob or gate option for tuning the lane beyond what the in-VM exclusion needs.


## Architecture Decision

**Approach**: `linux` is one more entry in `release_check.dart`'s gate table with a dedicated handler (as `cleanup` and `ci` have), so receipts, candidate-identity checks, `--resume`, `--status` and `--local` selection come for free. The handler drives `limactl`: ensure the VM from `dev/tools/lima/linux.yaml`, ship the committed candidate as a Git snapshot that reproduces the same HEAD and tree in a clean clone inside the VM, run the release check there, then run the container posture profile as root.
**Why this over the floor**: the floor is leaving the heavy gates on GitHub, which the PRD rules out (flaky, 13m37s). A separate script outside the release check would lose the commit-bound receipt FR2 requires.
**Flow**: host `linux` handler → limactl ensure VM (create from template if absent) → snapshot candidate into VM → in-VM `release_check.sh --version <v> --local` with `linux` and `ci` omitted and `DARTCLAW_NATIVE_ALLOW_DOWNLOAD=1` set, so `build` runs and fetches its checksum-pinned native archive → in-VM `sudo -E env "PATH=$PATH" bash dev/testing/profiles/container/run.sh --ci` → combined log into the host receipt. First failure stops the lane.


## Constraints & Gotchas

- **Constraint**: the in-VM run must omit the `linux` gate (recursion; the VM has no Lima) and the `ci` gate (it needs the GitHub API) – the runner needs an option that omits named gates, covered by a test. `--local` already never selects `ci`; the lane names it anyway so a later gate-table change cannot put a GitHub call in the VM. FR2's GitHub rule means no GitHub API or Actions call (no `gh`, no `ci` gate), not no network: the in-VM run keeps the `build` gate, whose linux-arm64 native archive comes from a pinned GitHub release URL in `dev/native_artifacts.json`. The lane sets `DARTCLAW_NATIVE_ALLOW_DOWNLOAD=1` for it (`dev/tools/build.sh` verifies the download against the manifest's sha256), and dependency hooks (llamadart) download their pinned release assets the same way. The lane proves linux-arm64 builds before the tag; the tag-time matrix still builds every Linux target.
- **Constraint**: the host `--local` run now needs Lima and Docker Desktop; the new `linux` gate must not break callers that pass `--gate <other>`. `linux` is not in `_needsAssets` (the VM prepares its own assets).
- **Constraint**: the container posture profile builds the bridge and boots a server, so it needs, in the VM, Docker Engine reachable by root, `dart`, `git`, `ripgrep` (fitness), `python3`, `curl`. The template provisions them; the Dart SDK version tracks the `[tools] dart` pin in `mise.toml`, which the `Check` job installs.
- **Constraint**: `ci.yml` trimming leaves setup that only the removed steps needed (ripgrep install, the `TMPDIR` comment on `Test`); drop what no remaining step uses, keep the pinned action SHAs.
- **Constraint**: the release check's own test fixture shadows `dart`/`gh` on `PATH`; the fake `limactl` joins them and records each call, so tests assert VM creation, reuse and the in-VM commands without a VM.


## Implementation Plan

### Implementation Tasks

- **TI01** `ci.yml` has only the `Check` job (setup, dependencies, assets, format, analyze, architecture) and `PowerShell scripts`; unused setup of the removed steps is gone
  - **Verify**: `apps/dartclaw_cli/test/tool/release_check_test.dart#CI workflow runs only the fast jobs` – new test parsing `ci.yml`: job names are exactly those two and no step's `run` invokes `test_workspace.sh`, `fitness/run_all.sh`, `postgres_contract.sh` or `container/run.sh`
  - **SATISFIES**: S01

- **TI02** `release_check.dart` requires `Check` and `PowerShell scripts` for the `ci` gate and no other job; the test fixture's stub run and existing job-coverage tests match
  - **Verify**: `apps/dartclaw_cli/test/tool/release_check_test.dart#CI gate requires exactly the two remaining jobs` – new test: both successful passes, each one missing or failing fails with its name; the existing `every job advertised by the CI workflow...` test stays green
  - **SATISFIES**: S02

- **TI03** `linux` is a registered gate selected by `--local` after the other local gates, never by `ci`, with the in-VM omission option; without `limactl` on `PATH` it fails naming `brew install lima`
  - Pattern: `release_check.dart#_gates` entries `cleanup`/`ci` with handlers in `execute`.
  - **Verify**: `apps/dartclaw_cli/test/tool/release_check_test.dart#linux gate fails naming brew install lima without limactl` and `#local run includes the linux gate and the omission option skips it` – the second shows the lane's own in-VM invocation omits `linux` and `ci`, so it never selects either; also update the existing local-run test's fixture so `--local` still passes with the fake `limactl`
  - **SATISFIES**: S04, S05, SC02

- **TI04** The `linux` handler ensures the VM (create from the template when absent, reuse when present), ships the committed candidate as a snapshot with the same HEAD and tree, runs the in-VM local gates then the container posture profile as root, stops at the first failure, and writes the combined output with the failing gate or profile named into the receipt log
  - Depends on TI03. The lane inherits the runner's before/after candidate-identity check, which covers the "candidate changes while the lane runs" edge case.
  - **Verify**: `apps/dartclaw_cli/test/tool/release_check_test.dart#linux gate runs the candidate in the VM` (S03: calls in order, commit shown in log, one passed receipt, the in-VM invocation sets `DARTCLAW_NATIVE_ALLOW_DOWNLOAD=1` and omits `linux,ci`, no `gh` call), `#linux gate names the failing in-VM gate` and `#linux gate names a failing container posture profile` (S06, including that the profile does not run after a gate failure), `#linux gate creates the VM once and reuses it` (S07)
  - **SATISFIES**: S03, S06, S07, SC02

- **TI05** `dev/tools/lima/linux.yaml` is a Lima template for arm64 Ubuntu with its own Docker Engine, `dart`, `git`, `ripgrep`, `python3` and `curl`, no host mounts
  - **Verify**: `cmd: limactl validate dev/tools/lima/linux.yaml` – exit 0 (S08, needs Lima; report unexecuted where `limactl` is absent) and `cmd: test -z "$(grep -n -E '^mounts:' dev/tools/lima/linux.yaml | grep -v -F 'mounts: []')"` – the template declares no mount except the empty list
  - **SATISFIES**: S08, SC03

- **TI06** `RELEASE_PREPARATION.md` states the new split: `ci` row and final-CI paragraph name `Check` and `PowerShell scripts`; the gate table gains `linux`; the Lima lane replaces the Parallels Ubuntu VM as the native Linux lane (Parallels guide stays for desktop-agent use); local results carry to the squash commit through the ledger's tree comparison; the repository-protection paragraph names the two checks
  - **Verify**: `inspect: dev/guidelines/RELEASE_PREPARATION.md:1` – each sentence listed above present and no "four" job claim remains
  - **SATISFIES**: S09

- **TI07** The other public docs match: `KEY_DEVELOPMENT_COMMANDS.md` (CI-equivalent gate no longer "mirrors" `ci.yml` but is the local superset of it plus the heavy gates; Lima lane command; the "obtain GitHub CI once" line), `architecture-governance.md` (§ CI table with two jobs, § Governance Layers sentence about the CI Check job and tests), `CLAUDE.md` (format-gate sentence, Linux CI line, final-squash sentence), `README.md`, `dev/testing/README.md` and the `container/run.sh` header (profile is run by the `linux` gate, not a CI job), `TESTING-STRATEGY.md` PostgreSQL line, `LEARNINGS.md` `release_check.sh is not CI` bullet
  - **Verify**: `cmd: test -z "$(git grep -n -E 'Container boundary|all four named|four named checks|runs four jobs' -- . ':!CHANGELOG.md' ':!dev/adrs' ':!dev/bundle')"` – no removed job name or four-job rule remains outside records; plus `inspect: dev/architecture/architecture-governance.md:160` for the two-job table
  - **SATISFIES**: S09, SC01


## Final Validation Checklist

- Not executed by this story: the full `linux` gate run (`bash dev/tools/release_check.sh --version 0.28.1 --gate linux`) is release-preparation evidence under the binding constraint. The story report names it as not run.


## Implementation Observations

- Linux execution extends the existing release runner. `--omit linux,ci` selects the guest gates without recursion or GitHub API calls; `linux` always reruns on resume because VM state is external. The lane transfers a Git bundle, verifies HEAD and tree in a fresh guest checkout, and retains combined guest output in its host receipt.
- Lima 2.3.0 was installed locally for the template proof. `limactl validate dev/tools/lima/linux.yaml` returned `OK`; no VM was created or started. The full `linux` release gate is intentionally not run by this story, as its Final Validation Checklist requires.
- Regression evidence: the fast-jobs test initially failed with four actual jobs versus two expected; the two-job CI gate initially failed naming the removed job; missing-Lima and local-selection tests initially failed because `linux` was unknown/unselected. Removing the Linux execution dispatch made all five lane identity/failure/reuse tests fail (`.agent_temp/s01-linux-mutation.log`).
- Boy Scout tidies: removed obsolete CI-job references in container-profile comments and changed the Learnings fast-tier warning from CI to the local fitness gate. No production behavior changes beyond the release runner and CI split.
- Documentation closeout propagation: S09 should replace generic fitness-in-CI claims in `apps/dartclaw_cli/CLAUDE.md`, `packages/dartclaw_testing/CLAUDE.md` and `packages/dartclaw_workflow/CLAUDE.md` with local-fitness wording. These package instruction docs are outside S01's explicit doc work areas; the plan's closeout owns their reconciliation.
- Chain Attestation: OC01 closes through S01/S02 and TI01/TI02: the workflow job set and required successful CI jobs are exactly `Check` and `PowerShell scripts`, with missing/failing-job tests. OC02 closes through S03–S08 and TI03–TI05: command-boundary tests prove candidate bundle identity, gate selection/omission, VM creation/reuse and failures; Lima validates the no-mount template. OC03 closes through S09 and TI06/TI07: the named public docs state the local/GitHub split, exact-SHA two-job rule and squash-tree ledger comparison, and the removed-job scan is empty.
- Verification: the required fast command exited 0 (analysis: no issues; kernel 1430, core 1757, search 62, workflow 2132, CLI 855 passed; default suite skips: core 19, workflow 11, CLI 3). Its initial log lacked the runtime summary despite exit 0, so runtime was rerun explicitly: `dart test --reporter=failures-only packages/dartclaw_runtime` exited 0 with `+5686 ~25: All other tests passed!`. Retained logs: `.agent_temp/s01-fast.log`, `.agent_temp/s01-runtime-confirm.log`. Build and full tier are deferred to the plan's final verification under `--no-full-tier`.
- Reviewed: independent code/gap quick review found two defects; both applied and verified, none open. The repair moves staging onto the VM disk with a checkout-owned `TMPDIR`, then cleans the host bundle and exact guest staging directory on success, copy failure, gate failure and posture failure. Reviewer regression proofs fail when either correction is removed (`.agent_temp/s01-review-staging-red.log`, `.agent_temp/s01-review-cleanup-red.log`). The final release-runner suite now contains 23 tests.
- Final affected-check rerun: `dart test --reporter=failures-only apps/dartclaw_cli/test/tool/release_check_test.dart` -> exit 0, `+23: All tests passed!`; `dart analyze --fatal-infos` -> exit 0, `No issues found!`; format -> exit 0, `Formatted 2227 files (0 changed)`; Lima template validation -> exit 0, `OK`; no-host-mount command, removed-job doc scan, shell syntax and `git diff --check` -> exit 0. Log: `.agent_temp/s01-final-proof.log`.
- Task proof map: TI01/TI02's named CI tests and TI03/TI04's named lane tests are all included in the final 23-test run. TI05/S08 are the executed Lima validation and no-mount command. TI06 inspection confirms the release gate table, two-job exact-SHA rule, Lima lane and squash-tree ledger carry; TI07's removed-job scan is empty and the governance table lists two jobs. The Final Validation Checklist's real `linux` gate remains explicitly not run, as required.
