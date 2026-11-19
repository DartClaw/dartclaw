# Product Requirements Document: 0.28.1 Local-first Verification and Containerized Coding Tasks

> **Source**: `docs/ROADMAP.md` § Active Milestone and § 0.28.1 – Local-first verification (as of 2026-11-13)
> **Context**: 0.25 open items ([0.25 PRD](../0.25/prd.md), lines on containerized workflow steps and Codex rollouts);
> [devvm research](../../research/devvm-2026-11/research.md) V1–V5; [warp-factories research § 4](../../research/warp-factories-2026-11/research.md#4-factory-ui-ideas-u1u6)
> **Related Assets**: public ADR-062 (Proposed, D1–D3 pinned), ADR-015, ADR-054, ADR-055, ADR-060;
> public `dev/guidelines/RELEASE_PREPARATION.md`, `dev/tools/release_check.dart`, `.github/workflows/ci.yml`


## Executive Summary

- **Problem**: GitHub's push `Checks` run takes 9–14 minutes (13m37s on the 0.28.0 main commit) and every one of the
  last eight failed runs failed in its `Test` step on timing-sensitive tests, not on code; separately, a containerized
  agent cannot install dependencies or run a project's tests, and the `visual` testing profile shows no tasks or runs.
- **Vision**: heavy gates run locally through `release_check.sh` with receipts, Linux included through a Lima VM;
  GitHub keeps a check that finishes in minutes plus Windows and publishing. A containerized coding step on a Dart or
  Node project installs dependencies through a read-only registry mirror and runs its tests, and the merge path back
  to the host cannot carry an execution-surface file without a human look.
- **Target Users**: the maintainer releasing DartClaw; operators running coding tasks and workflows in containers.
- **Success Metrics**: push Checks ≤ 3 min; Linux full-suite evidence on every release; a containerized
  `implement-story` run on a Dart and a Node fixture passes its tests; `visual` shows tasks and runs in every seeded
  state.

### Capabilities at a Glance

- **FR1: Fast GitHub check, heavy gates local** _(Must / P0)_ – GitHub `Checks` keeps format, analyze, architecture and PowerShell; tests, fitness, PostgreSQL and container posture leave it.
- **FR2: Linux lane on Lima** _(Must / P0)_ – a `linux` release gate runs the local gates and the container posture profile inside a Lima Ubuntu VM on the same candidate.
- **FR3: Live containerized workflow step** _(Must / P0)_ – a real coding workflow runs with its steps in containers against a Dart and a Node fixture, re-runnable.
- **FR4: Codex home recheck** _(Must / P0)_ – settle why DartClaw Codex rollouts land in `~/.codex/sessions/`, fix any spawn that ignores a dedicated home.
- **FR5: Execution-surface review downgrade** _(Must / P0)_ – a diff touching an execution-surface path turns an automatic accept, promotion or publish into review, paths named; host commit sweeps run no agent hooks.
- **FR6: Blocked-host message names the fix** _(Should / P1)_ – NetworkGuard's block reason names the config key that would allow the host.
- **FR7: Saved branches on cancel and cleanup** _(Should / P1)_ – closed on evidence that cancelled work already survives; squash accepts stop leaving their branch behind.
- **FR8: Toolchain image recipe and missing-toolchain error** _(Must / P0)_ – documented `FROM dartclaw-agent` recipe for Dart and Node, and an actionable error naming a missing toolchain binary.
- **FR9: Read-only package-registry egress** _(Must / P0)_ – a third bridge surface, `registry`, serving pub, npm, PyPI, crates.io and opt-in Go read-only for `workspace` containers, ecosystems as instance-config records (ADR-062, amended 2026-11-18).
- **FR10: Seeded visual profile** _(Must / P0)_ – `visual` seeds tasks and workflow runs in completed, failed and awaiting-approval states.

### Scope Highlights

- **In scope**: CI cut and local Linux lane; the two 0.25 live proofs; devvm V1–V5; seeded `visual` profile.
- **Out of scope**: replacing GitHub Actions or moving to a drop-in runner; Docker Sandboxes (`sbx`); registry
  built-in registry ecosystems beyond pub, npm, PyPI, crates.io and Go; private registries; a new testing profile.
- **MVP boundary**: FR1–FR5, FR8–FR10. FR6 and FR7 are small and ride along.

### Key Constraints, Assumptions & Dependencies

- *Constraint:* ADR-062's D1–D3 are pinned: registry mirror over the existing pipe with no TLS interception or CONNECT
  tunnel, granted to `workspace` and never `restricted`, no config knob for the grant. Its 2026-11-18 amendment
  replaces "pub and npm only": ecosystems are `container.registries` records, built-ins pub, npm, PyPI, crates.io and Go (off).
- *Constraint:* order is the live containerized proof (FR3) first, then V3, V4, V5, V2, V1; FR3's failures are FR9's
  acceptance test.
- *Dependency:* the Linux lane needs Lima (`brew install lima`) on the release machine; it is arm64 Linux, x64 Linux
  is proven by the tag-time release matrix.


## Problem Definition

### Problem Statement

GitHub Actions is slow and flaky for this repository. The `Check` job's `Test` step alone took 11m01s on the 0.28.0
main commit, and in the 0.28 release it failed on timing-sensitive tests and once on `release_check_test` (exit 254,
code unchanged since two earlier green runs). Each red run cost a diagnosis and a rerun. `release_check.sh --local`
already runs every heavy gate with commit-bound receipts, so GitHub repeats work the release process has proven.

Container mode is the default posture where a runtime exists (ADR-055), yet a containerized agent has `network:none`
and an image with no language toolchain: it cannot run `dart pub get`, `npm install` or a test suite. A containerized
workflow step has never run live (0.25 left it unit-tested only). The merge path from a container back to the host
has a hole: an agent can write `.claude/settings.json` with a hook, an automatic accept merges it, and the next
host-mode Claude spawn in that project runs the hook outside any container.

The next milestone's factory screens need visual validation against seeded tasks and runs, but `visual` seeds none:
its only task and run data was a SQLite `dartclaw.db` that 0.27.0 stopped reading and 0.27.2 deleted, and the server
reads an empty disposable PostgreSQL.

### Target Users

- The maintainer, who qualifies and tags releases from a Mac with Docker Desktop and Parallels.
- Operators who run coding tasks and workflows in containers and need them to install, test and merge safely.
- Agents doing visual validation of the Tasks and Workflows screens.

### Desired Outcome

A push gets a GitHub verdict in minutes, from checks that do not depend on timing. Release evidence for the full
suite, PostgreSQL, fitness, build and container posture comes from local receipts on macOS and on Linux, and the
squash commit still gets one exact-SHA GitHub run for what remains there. A containerized coding step can install
pub and npm dependencies and run its tests without gaining network access or a credential, and nothing it writes
reaches host execution without review. `visual` renders tasks and runs in each state the factory screens show.

### Evidence & Context

- CI step timings, 0.28.0 main run 42666458085 (2026-11-09): Format 8s, Analyze 26s, Test 11m01s, Architecture 1s,
  Fitness 1m35s; Container boundary 2m12s, PostgreSQL contract 2m37s, PowerShell 14s, all in parallel.
- Last eight failed `Checks` runs: all failed in `Check` (`Test` step); `Container boundary` and `PostgreSQL contract`
  did not fail.
- `visual/run.sh:2-4` and `visual/README.md:34-38` claim seeded tasks; the profile writes no task or run rows
  (`git show 1b98f5ba6` deleted the last seed DB).
- 0.25 PRD: "Containerized workflow-step composition is unit-tested only – it has never run live." No testing profile
  sets `tasks.execution`, so no live profile reaches a containerized workflow step.
- DartClaw-originated Codex rollouts (`"originator":"dartclaw"`) exist under `~/.codex/sessions/` from 2026-11-06 and
  2026-11-10; Codex uses the system home unless a stored subscription prepares a dedicated one
  (`codex_environment.dart:162-170`).


## Success Metrics

| Metric | Baseline | Target | How observed |
|--------|----------|--------|--------------|
| Push `Checks` wall-clock | 13m37s (0.28.0 main) | ≤ 3 min | `gh run view` on the first pushes after FR1 |
| Push `Checks` failures not caused by the code | 8 of the last 8 failed runs | 0 over the 0.28.1 cycle | Failed-run job/step names |
| Linux full-suite evidence per release | Implicit, from GitHub `Check` | A passing `linux` receipt for the release candidate | `release_check.sh --status` |
| Containerized coding step on a Dart and a Node project | Never run live | `implement-story` installs dependencies and passes tests in a container on both fixtures | FR3 scenario log |
| Seeded task and run states in `visual` | 0 tasks, 0 runs | Each FR10 state visible on Tasks and Workflows | Capture of `visual` |


## Scope

### In Scope

- Trim GitHub `Checks`, move heavy gates to local release-check gates, add the Lima Linux lane, rewrite the release
  rules that name GitHub jobs.
- Run a containerized coding workflow live; recheck the Codex home; fix defects either finds.
- devvm V1–V5 as specified below.
- Restore seeded tasks and runs in `visual`.

### Out of Scope

- Changing CI provider or runner (drop-in runners, self-hosted runners): failures were test failures, not GitHub
  infrastructure, so a runner swap does not address them.
- Docker Sandboxes (`sbx`) as a backend (devvm research § 5).
- Built-in registry ecosystems beyond pub, npm, PyPI, crates.io and Go (Maven, RubyGems, NuGet and Hex are config-only
  examples; Composer, Gradle, Poetry, SwiftPM and CocoaPods are unsupported); private or authenticated registries; TLS interception.
- `CLAUDE.md` and `AGENTS.md` on the execution-surface list.
- A new testing profile; the Parallels Linux VM as a release lane.
- x64 Linux test runs before tagging.

### MVP Boundary

FR1–FR5 and FR8–FR10. FR6 and FR7 are under a day each and ship with the rest.


## Functional Requirements

### User Stories

| ID | Story | Acceptance Criteria | Priority |
|----|-------|---------------------|----------|
| US01 | As the maintainer, I want a push verdict in minutes, so that CI stops costing a rerun per red timing test | FR1 | Must / P0 |
| US02 | As the maintainer, I want Linux evidence without GitHub running the suite, so that a release still proves Linux | FR2 | Must / P0 |
| US03 | As an operator, I want a containerized coding step to install dependencies and run tests, so that container mode works for coding | FR3, FR8, FR9 | Must / P0 |
| US04 | As an operator, I want agent-written hooks and CI files held for review, so that a container cannot reach host execution through a merge | FR5 | Must / P0 |
| US05 | As an operator, I want a cancelled task's unmerged commits kept, so that cancelling never loses work | FR7 (already true; pinned by test) | Should / P1 |
| US06 | As a validating agent, I want seeded tasks and runs, so that factory screens can be captured | FR10 | Must / P0 |

### Feature Specifications

#### FR1: Fast GitHub check, heavy gates local

**Description**: The push-triggered `Checks` workflow keeps the `Check` job with dependency install, embedded-asset
generation, format check, `dart analyze --fatal-infos` and `arch_check`, plus the `PowerShell scripts` job. The `Test`
and `Fitness functions` steps and the `Container boundary` and `PostgreSQL contract` jobs leave GitHub; their proof
comes from the existing local gates (`tests`, `fitness`, `postgres`) and FR2's `linux` gate. `Release Binaries` is
unchanged. The release rule that one push-triggered `Checks` run on the final squash commit must be green on the exact
SHA stays, narrowed to the jobs that remain; local results carry to the squash commit through the qualification
ledger's existing input comparison, because a squash commit has the branch tip's Git tree.

**Acceptance Criteria**:
- [ ] When a commit is pushed, the GitHub `Checks` workflow shall run only the `Check` job (setup, assets, format, analyze, architecture) and the `PowerShell scripts` job.
- [ ] When `release_check.sh --gate ci` runs, it shall require `Check` and `PowerShell scripts` green by name on the full HEAD SHA, and no other job.
- [ ] When `release_check.sh --local` runs, it shall run the `tests`, `postgres`, `fitness` and `build` gates as today.
- [ ] `RELEASE_PREPARATION.md`, `KEY_DEVELOPMENT_COMMANDS.md` and every other public doc naming the four CI jobs or a per-push test, fitness, PostgreSQL or container run shall state the new split.
- [ ] If a pushed commit breaks a test, then GitHub shall stay green and the local `tests` gate shall fail; no doc may claim otherwise.

**Inputs / Outputs**:
- **Inputs**: `.github/workflows/ci.yml`, `release_check.dart` `_ciJobs`.
- **Outputs**: a shorter `Checks` run; CI receipts naming two jobs.

**Priority**: Must / P0

#### FR2: Linux lane on Lima

**Description**: A `linux` gate in `release_check.dart` runs the candidate on Linux inside a Lima VM (Ubuntu with its
own Docker Engine), started from a template checked into the repo and reused across runs. The lane copies the
committed candidate into the VM (no shared `.dart_tool`, build outputs or test data), runs the local gates there,
`build` included, with the in-VM run excluding the `linux` gate itself, and runs `dev/testing/profiles/container/run.sh --ci` as root, which
is the check the removed `Container boundary` job ran. The gate passes only when both pass; its host receipt keeps the
lane's combined log. Lima replaces the Parallels Ubuntu VM as the native Linux lane; the Parallels VM guide stays for
desktop-agent use.

**Acceptance Criteria**:
- [ ] While Lima is installed, when `release_check.sh --version <v> --gate linux` runs on a clean committed candidate, the release check shall run the local gates and the container posture profile inside the Lima VM on that commit and record one receipt for the `linux` gate.
- [ ] When `release_check.sh --local` runs, it shall include the `linux` gate.
- [ ] If `limactl` is not on `PATH`, then the `linux` gate shall fail with a message naming `brew install lima`.
- [ ] If any in-VM gate or the container posture profile fails, then the `linux` gate shall fail and its log shall name the failing gate.
- [ ] If the VM does not exist, then the lane shall create it from the checked-in template; an existing VM shall be reused.
- [ ] The in-VM run shall make no GitHub API or Actions call (no `gh`, no `ci` gate); pinned, checksum-verified release-asset downloads by dependency hooks and `build.sh` are allowed.

**Inputs / Outputs**:
- **Inputs**: committed candidate; Lima template in the repo.
- **Outputs**: `linux` receipt under `.agent_temp/releases/<version>/linux/`.

**Priority**: Must / P0

#### FR3: Live containerized workflow step

**Description**: The 0.25 live proof. A re-runnable scenario runs the bundled `implement-story` workflow live, with
its agent steps in containers (`tasks.execution: container`, `workspace` profile), against two small fixture projects,
one Dart and one Node, each with a story whose implementation must pass the fixture's tests. It runs once with Claude
Code and once with Codex. Before FR8 and FR9 the steps are expected to fail at dependency install or test commands;
those recorded failures are FR8 and FR9's acceptance test, and the same scenario passing after them is their proof. A
defect in the container step path itself (placement, worktree mount, authority, provider auth, result capture) is
fixed in 0.28.1.

**Acceptance Criteria**:
- [ ] When the scenario runs, each workflow agent step shall execute inside a container, shown by its `agent_executions.container_json` record naming the container profile (and the container name, where threading it costs no more than a callback).
- [ ] A fix to the container step path shall add no writable mount beyond the task's own worktree; an in-container git failure is recorded, and the host-side commit sweep commits.
- [ ] When the scenario runs on a fixture, it shall record per provider whether dependency install and the fixture's tests succeeded, with the failing command and its output.
- [ ] If a step fails for a reason other than a missing toolchain or missing registry access, then that defect shall be fixed with a test before the story closes.
- [ ] The scenario shall be one documented command that a later story reruns unchanged.

**Inputs / Outputs**:
- **Inputs**: Claude Code and Codex credentials; Docker; the fixtures.
- **Outputs**: scenario command, fixtures, recorded results.

**Priority**: Must / P0

#### FR4: Codex home recheck

**Description**: Settle the 0.25 observation that the `workflows` profile's Codex rollouts appeared under
`~/.codex/sessions/` despite the dedicated home. Codex uses the system home by default and a dedicated home only when
a stored subscription prepares one; the `workflows` profile seeds no store and documents that it inherits `~/.codex`.
The recheck runs Codex through DartClaw once with the stored-subscription dedicated home in effect, host mode and
container mode (the latter within FR3's Codex run), and checks where rollouts land. It is a one-off run recorded in
the story, not a re-runnable mode; the lasting guards are FR3's rollout check and tests asserting `CODEX_HOME`.

**Acceptance Criteria**:
- [ ] If no stored Codex subscription is available on the executing machine, then FR4 shall stay open.
- [ ] While a dedicated Codex home is in effect, when DartClaw runs a Codex turn or workflow step, no new rollout shall appear under `~/.codex/sessions/`.
- [ ] If a Codex spawn path writes to `~/.codex` while a dedicated home is in effect, then it shall be fixed with a test asserting the spawn's `CODEX_HOME`.
- [ ] The outcome (explained by system-home default, or fixed) shall be recorded in public `LEARNINGS.md` only if it is a non-obvious trap.

**Priority**: Must / P0

#### FR5: Execution-surface review downgrade

**Description**: devvm V3. One fixed path list, in one place, checked against the diff of every automatic accept and
every workflow promotion: `.claude/**`, `.mcp.json`, `.codex/**`, `.husky/**`, `.githooks/**`, `.github/workflows/**`,
`.envrc`, `.vscode/tasks.json`, `.vscode/settings.json`, `mise.toml`, and any added symlink. `CLAUDE.md` and
`AGENTS.md` are not on the list. A hit turns the automatic accept or promotion into review with the matched paths
named. Workflow publish (the push before a pull request) is gated the same way, because built-in `implement-story`
and serial `implement-prd` runs never promote, and a pushed `.github/workflows/**` change runs with repository
secrets before review. The host's own commit sweeps in agent worktrees run with git hooks disabled, and the check
runs before the sweep. The check is deterministic host code (ADR-054); there is no config knob.

**Acceptance Criteria**:
- [ ] When a task's completion action would accept automatically and its diff touches a listed path, the task shall go to `review` with the matched paths in its review reason, shown on the task detail page and returned by the task API.
- [ ] When a workflow would promote, merge or publish its branch automatically and the diff touches a listed path, the workflow shall stop for review naming the matched paths instead of merging or pushing.
- [ ] When the host commits changes in an agent-written worktree, no git hook from that worktree shall run.
- [ ] When a diff adds a symlink anywhere, it shall count as a hit.
- [ ] When a diff touches only `CLAUDE.md`, `AGENTS.md` or unlisted paths, automatic accept and promotion shall behave as today.
- [ ] When an operator accepts a held task manually, the accept shall proceed.

**Priority**: Must / P0

#### FR6: Blocked-host message names the fix

**Description**: devvm V4. NetworkGuard's block reason `Network blocked: domain not in allowlist ($host)` also names the
config key that would allow the host: `guards.network.agent_overrides.<id>.extra_domains` when the evaluation has an
agent id, else `guards.network.extra_allowed_domains`.

**Acceptance Criteria**:
- [ ] When NetworkGuard blocks a host with an agent id in context, the reason shall name that agent's `extra_domains` key.
- [ ] When it blocks a host with no agent id, the reason shall name `guards.network.extra_allowed_domains`.

**Priority**: Should / P1

#### FR7: Saved branches on cancel and cleanup

**Description**: devvm V5, closed on its verify-first clause (owner, 2026-11-15). Cancel and cleanup already preserve
the work: `WorktreeManager.cleanup` runs non-force `git worktree remove` and `git branch --delete`, which git refuses
for a dirty worktree or an unmerged branch, so commits survive as `dartclaw/task-<id>` behind a WARN. No rename is
built. The same refusal leaves every default squash-accepted branch behind, which is fixed here.

**Acceptance Criteria**:
- [ ] When a task with commits not on its base, or with uncommitted changes, is cancelled or cleaned up, its branch and work shall survive; a real-git test pins it.
- [ ] The projects-and-git guide shall say where a cancelled task's work is kept.
- [ ] When a task is accepted with the squash strategy and the merge succeeds, its task branch shall be deleted.

**Priority**: Should / P1

#### FR8: Toolchain image recipe and missing-toolchain error

**Description**: devvm V2. The user guide documents extending the agent image with `FROM dartclaw-agent:latest`, with a
Dart and a Node example, and setting it through `container.image`. When a containerized step needs a toolchain binary
the image lacks, the operator gets a message that names the binary and points at the recipe. The live scenario (FR3)
with such an image runs the fixtures' tests once dependencies are present.

**Acceptance Criteria**:
- [ ] The container guide shall contain a working `FROM dartclaw-agent:latest` recipe for Dart and for Node and the `container.image` setting that selects it.
- [ ] If a containerized step cannot find a toolchain binary, then the operator shall see a message naming the binary and the recipe.
- [ ] If `container.image` names a tag other than the default `dartclaw-agent:latest` and that image is missing, then startup shall fail naming `docker build -t <image>` and the recipe, instead of building the stock image under that tag.
- [ ] With the Dart and Node recipe images, the FR3 scenario shall run each fixture's test command inside the container.

**Priority**: Must / P0

#### FR9: Read-only package-registry egress

**Description**: devvm V1, per public ADR-062 with D1–D3 pinned. A third bridge surface, `registry`, beside `provider`
and `mcp`: the package manager talks plain HTTP to the in-container bridge's loopback port; the host makes the HTTPS
request to origins each ecosystem record pins (`https://pub.dev`, `https://registry.npmjs.org`, plus the exact
download origins they redirect to). Per ADR-062's 2026-11-18 amendment each ecosystem is a `container.registries`
record in the instance config (built-ins pub, npm, PyPI, crates.io, and Go shipped off) that an operator can disable,
replace or add; startup refuses an invalid record, and `workspace` containers get a package-cache volume. `GET` and `HEAD` only, no credentials, container `Authorization` headers dropped. The client never needs a
direct connection for a pinned-origin download: a record rewrites JSON metadata URLs only where its client has no host
replacement of its own (pub's are rewritten; npm's `replace-registry-host` already routes tarballs through the mirror,
and rewriting would write loopback URLs into `package-lock.json`). Accepted consequence: a containerized `pub get`
ignores a committed `pubspec.lock` (its `url` differs) and writes one naming the mirror, so it re-resolves to newer
versions; ADR-062 and the guide state it. Granted to `workspace` authorities, never
`restricted`, no config knob. Each request is audited; a refusal fires `GuardBlockEvent` (`guard: host-gateway`,
`hook: bridge`). The container keeps `network:none`. ADR-062 moves to Accepted when this ships.

**Acceptance Criteria**:
- [ ] While a `workspace` container runs, when the agent runs `dart pub get` or `npm install` against public packages, the install shall succeed through the bridge with `network:none` unchanged.
- [ ] While a `restricted` container runs, the `registry` surface shall not be granted and installs shall fail.
- [ ] If a request uses a method other than `GET` or `HEAD`, then the host shall refuse it and fire a `GuardBlockEvent`.
- [ ] If a request or redirect targets an origin outside the record's pinned set, then the host shall refuse it.
- [ ] If a response exceeds `BridgeLimits`' 64 MiB cap, then the install shall fail with a message naming the cap.
- [ ] Each served request shall be recorded with authority, ecosystem, path including query, and status.
- [ ] When a containerized `pub get` runs on a project with a committed `https://pub.dev` lockfile, the resulting lockfile change shall be the documented consequence, shown by the FR3 Dart fixture's results.
- [ ] With FR8's images, the FR3 scenario shall pass on both fixtures with both providers.
- [ ] While a `workspace` container runs, when the agent installs Python (uv), Rust (Cargo) or, with `go` enabled in the
  instance config, Go dependencies, the install shall succeed through the bridge with `network:none` unchanged, and the
  FR3 scenario shall pass on those fixtures with both providers.
- [ ] When the instance config disables, redefines or adds a `container.registries` record, the mirror shall serve
  exactly the resulting enabled records from the next start.
- [ ] If a record has a non-HTTPS origin, userinfo, a path or IP literal in an origin, a duplicate route, or an `env`
  key another record or DartClaw sets, then startup shall refuse naming it.
- [ ] Each `workspace` container shall have a writable, executable package cache at `/var/cache/dartclaw`, removed
  with the container; `restricted` shall have none.

**Priority**: Must / P0

#### FR10: Seeded visual profile

**Description**: `visual/run.sh` seeds its PostgreSQL with tasks and workflow runs before the UI is captured, so its
own claim of seeded Tasks and Workflows content holds again. Seeded states: tasks `accepted`, `failed` and `review`;
workflow runs `completed`, `failed` and `awaitingApproval` with a pending approval step and message, each run with its
step tasks. The seed writes through the storage layer the server uses, so a schema change breaks the seed in a test,
not in a capture.

**Acceptance Criteria**:
- [ ] When `bash dev/testing/profiles/visual/run.sh` starts, the Tasks page shall list seeded tasks in `accepted`, `failed` and `review`, each with a detail page that renders.
- [ ] When it starts, the Workflows page shall list seeded runs in `completed`, `failed` and `awaitingApproval`, and the awaiting run's detail shall show its pending approval message.
- [ ] If the storage schema changes in a way the seed no longer satisfies, then a test shall fail.
- [ ] `visual/run.sh`, `visual/README.md`, `dev/testing/README.md` and `dev/testing/.gitignore` shall describe only data the profile actually has.

**Priority**: Must / P0

### Data Requirements

- FR10 seed: tasks, `agent_executions`, `workflow_step_executions` and `workflow_runs` rows as the server's repositories
  write them; run context carrying `_approval.pending.stepId` for the awaiting run.
- FR9 audit: authority, ecosystem, path, status per request.


## Non-Functional Requirements

| Category | Requirement | Threshold / Target |
|----------|-------------|--------------------|
| Performance | Push `Checks` wall-clock | ≤ 3 min |
| Reliability | Push `Checks` has no timing-sensitive step | No test step in `Checks` |
| Security | Registry surface adds no network attachment, CA or credential to the container | `network:none` unchanged; GET/HEAD only |
| Security | Execution-surface hits never auto-merge or auto-push | 100% of listed-path diffs held |
| Usability | Linux lane needs one tool beyond Docker Desktop | Lima only |


## Edge Cases

| Scenario | Expected Behavior | Recovery Path |
|----------|-------------------|---------------|
| Lima VM left in a broken state | `linux` gate fails naming the VM | Delete and recreate the VM from the template |
| Candidate changes while the Linux lane runs | Release check's before/after identity check fails the gate | Rerun on the final candidate |
| A registry redirect chain changes upstream | Request outside the pinned set is refused | Add the exact origin to the record (a built-in in a patch, or in the instance config) |
| Agent writes both a listed path and normal code | Whole accept is held for review | Operator reviews and accepts manually |


## Constraints & Assumptions

### Constraints

- ADR-062 D1–D3 (see Executive Summary); ADR-054 keeps the FR5 and FR9 decisions in deterministic host code.
- `RELEASE_PREPARATION.md`: a story never carries a task that re-runs a release gate; story proof is its own tests plus
  the `fast` / `full` tiers.
- No config knob for FR5 or for FR9's grant; FR9's ecosystems are instance-config records (ADR-062 amendment).

### Assumptions

- Lima's Ubuntu image with Docker Engine runs the container posture profile as root with native bind-mount semantics,
  as the removed GitHub job did.
- arm64 Linux evidence plus the tag-time x64 release matrix is enough Linux proof at prototype stage.

### Dependencies

| Dependency | Why It Matters |
|------------|----------------|
| Lima on the release Mac | FR2's gate fails without it |
| Claude Code and Codex credentials | FR3 and FR4 are live runs |
| FR3 scenario | Acceptance test reused by FR8 and FR9 |


## Open Questions

None open at kickoff.


## Decisions Log

| Decision | Rationale | Alternatives Considered |
|----------|-----------|-------------------------|
| Linux proof is a Lima VM lane run by a `linux` release gate (owner, 2026-11-13) | Lighter than Parallels, scriptable, own Docker Engine covers native-Linux container posture | Parallels Ubuntu VM; reduced Linux lane on GitHub; plain Docker container (cannot prove native posture); devvm (0.1.0, workstation tool) |
| Squash-commit CI rule kept, narrowed to the remaining jobs (owner, 2026-11-13) | Keeps an exact-SHA external check; local results carry by the ledger's tree comparison with no runner change | Tree-bound receipts in the runner; drop GitHub from release evidence |
| `Container boundary` and `PostgreSQL contract` move local too (owner, 2026-11-13) | One local lane owns heavy and Linux proof | Keep one or both on GitHub |
| Seed restored in `visual`, no new profile (owner, 2026-11-13) | Makes the profile's own claim true; nothing new to maintain | New `factory` profile |
| `CLAUDE.md` and `AGENTS.md` off the execution-surface list (owner, roadmap 2026-11-10) | Instructions, not code; agents maintain them | Include them |
| Pub lockfile drift through the mirror accepted and documented (owner, 2026-11-15) | Pub has no host-replace option; normalising the URL keeps the silent upgrade, holding would stop every Dart task | Discard mirror lockfiles host-side; hold lockfile changes for review |
| ADR-062 "Response URLs" row reworded to the no-direct-connection invariant (owner, 2026-11-15) | npm rewrites tarball hosts itself; adapter rewriting pollutes `package-lock.json` | Rewrite npm metadata as the ADR first said |
| Container step fixes add no writable mount beyond the task worktree (owner, 2026-11-15) | A writable git dir hands the agent hooks and config outside any reviewed diff | Leave to the executor |
| A missing non-default `container.image` fails startup (owner, 2026-11-15) | Building the stock image under a recipe tag hides a forgotten build | Document build-first only |
| Publish gated; host commit sweeps run with hooks disabled, check before sweep (owner, 2026-11-15) | Default built-in runs never promote; pushed workflow files run with secrets; agent hooks would run on the host | Promotion only |
| FR7 closed on verify-first evidence; squash-accept leftover branch fixed (owner, 2026-11-15) | Git's non-force delete already keeps unmerged work; every squash accept left its branch | Rename on cancel; rename on cancel and reject |
| `build` runs in the Lima lane; FR2's GitHub rule means no API or Actions call (owner, 2026-11-15) | Dependency hooks download pinned GitHub release assets anyway; proves linux-arm64 before the tag | Omit `build` |
| Placement recorded in `agent_executions.container_json` (owner, 2026-11-15) | The column exists for it and makes placement a repository read | Log line |
| Codex recheck requires the stored-subscription home, run once (owner, 2026-11-15) | That home is what 0.25 observed; FR4 says once | Isolated home only; re-runnable mode |
| Registry ecosystems become `container.registries` records; built-ins add PyPI, crates.io and Go (off); `workspace` gets a package-cache volume (owner, ADR-062 amendment 2026-11-18) | Each ecosystem was four values with no logic, yet needed a release | One adapter class per ecosystem |
