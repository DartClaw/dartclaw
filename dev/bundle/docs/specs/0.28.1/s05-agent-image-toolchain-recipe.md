# S05: Agent image toolchain recipe

**Plan**: dev/bundle/docs/specs/0.28.1/plan.json
**Story-ID**: S05

## Feature Overview and Goal

**Intent**: The agent image ships no language toolchain and nothing tells an operator how to add one, so a containerized coding step dies on `dart: command not found` with no pointer to the fix. This story documents the extension recipe, proves it with story S02's scenario, and makes a step that lacks a toolchain binary say which one and where the recipe is.

**Expected Outcomes**:

- [OC01] An operator follows the container guide to build a Dart or Node image from `dartclaw-agent`, selects it with `container.image`, and `dart`, `node` and `npm` run in a `workspace` container under its hardening.
- [OC02] story S02's scenario, with the recipe images, reaches each fixture's install and test commands inside the container; no failing command left is a missing toolchain binary, so only registry access (S06, S07) remains.
- [OC03] When a `workspace` container step lacks a toolchain binary, the operator reads the binary's name and the recipe's location in the step's result, and the agent has not tried to install the binary itself.
- [OC04] A `container.image` naming a tag other than the default `dartclaw-agent:latest` that does not exist fails startup naming `docker build -t <image>` and the guide's recipe section, instead of silently building the stock image under that tag.


## Required Context

Paths are relative to the public repo root (`../dartclaw-public/` from the private repo), where this FIS executes from its exported copy and where `cmd:` proofs run; `docs/specs/` and `docs/research/` paths name this plan's private sources, exported to `dev/bundle/docs/`.

- `docs/specs/0.28.1/prd.md#fr8-toolchain-image-recipe-and-missing-toolchain-error` – the three acceptance criteria.
- `docs/specs/0.28.1/s02-live-containerized-workflow-proof.md` – the scenario command `dev/testing/profiles/container/coding.sh`, its flags, fixtures, results file and teardown rules; rerun unchanged as this story's acceptance proof (plan `sharedDecisions` "Containerized coding scenario"). story S02's recorded failures are the baseline.
- `docs/research/devvm-2026-11/research.md#v2--project-toolchain-in-the-agent-image-p1-pairs-with-v1` – leanest-first options (a) recipe, (b) detection; this FIS settles (b) in Architecture Decision.
- `dev/adrs/054-model-first-delegation-and-one-authority-per-concern.md` – Rule 1 ("give the model the context it needs") is why the note goes to the model; its no-prose-scraping bullet names model replies and inbound user text, not tool output.
- `dev/state/PROMPT-SURFACES.md` – the prompt inventory a changed surface updates in the same change.
- `docker/Dockerfile` and `packages/dartclaw_runtime/lib/src/container/container_manager.dart#start` – base image (uid 1000, `PATH`) and the container flags the recipe must live under; `#ensureImage` (~:281) is the image build the startup rule changes.
- `apps/dartclaw_cli/lib/src/commands/init/setup_checks.dart` (`container.image` row, ~:640) and `packages/dartclaw_runtime/lib/src/runtime/security_wiring.dart` (~:453, where `ensureImage` runs and `refuse` reports) – the doctor row and the startup refusal.


## Acceptance Scenarios

- **S01 [OC01] [runtime] Recipe images run their toolchain under container hardening**
  - **Given** the stock image built as `dartclaw-agent:latest` and the Dart and Node recipe images built from it
  - **When** `dart --version` (Dart image) and `node --version` and `npm --version` (Node image) run in a container with `--network none`, `--read-only`, `--cap-drop ALL` and the `/tmp` tmpfs DartClaw uses
  - **Then** each prints a version, and the process user inside both images is uid 1000
  - **Proof**: `cmd: docker build -q -t dartclaw-agent:latest docker/ && docker build -q -t s05-dart -f dev/testing/profiles/container/images/dart.Dockerfile dev/testing/profiles/container/images && docker build -q -t s05-node -f dev/testing/profiles/container/images/node.Dockerfile dev/testing/profiles/container/images && for i in s05-dart s05-node; do test "$(docker run --rm --network none --read-only --cap-drop ALL --tmpfs /tmp:rw,noexec,nosuid,size=100m $i id -u)" = 1000 || exit 1; done && docker run --rm --network none --read-only --cap-drop ALL --tmpfs /tmp:rw,noexec,nosuid,size=100m s05-dart dart --version && docker run --rm --network none --read-only --cap-drop ALL --tmpfs /tmp:rw,noexec,nosuid,size=100m s05-node sh -c 'node --version && npm --version'` – exit 0

- **S02 [OC02] [runtime] The scenario reaches each fixture's install and test commands**
  - **Given** story S02's scenario command, which now runs each fixture in its recipe image
  - **When** the maintainer reruns it with Claude Code and Codex on both fixtures
  - **Then** the results file holds a row per provider and fixture with an install and a test command that ran inside the container, and no row's failing command output is a missing binary (`command not found`); a failure that remains is the install or test command failing for registry access
  - **Proof**: `cmd: bash dev/testing/profiles/container/coding.sh --baseline` – exit 0; then `cmd: d=$(ls -dt .agent_temp/container-coding/*/ | head -1); test -z "$(grep -iE 'command not found|: not found|executable file not found' "$d/results.md")"` – exit 0

- **S03 [OC03] A `workspace` container task's first prompt carries the toolchain note**
  - **Given** a task, or a workflow agent step, placed in a `container/workspace` execution policy
  - **When** DartClaw composes the task's first prompt
  - **Then** it tells the agent that the container has no direct network access, that language toolchains exist only when the configured image provides them (DartClaw's default image provides none), and that when a build or test command's binary is missing it must stop, name the binary, and point the operator at the security guide's toolchain-image section and `container.image` instead of installing the binary; the same section appears on a retry prompt

- **S04 [OC03] Host and `restricted` tasks carry no note**
  - **Given** a task under the host policy, and a task under `container/restricted`
  - **When** DartClaw composes each first prompt
  - **Then** neither contains the toolchain note, and every other prompt section is as before

- **S05 [OC03] [runtime] A stock-image step reports the missing binary instead of working around it**
  - **Given** story S02's scenario with its image forced to the stock `dartclaw-agent:latest` (the baseline condition), Dart fixture
  - **When** the run settles for Claude Code and for Codex
  - **Then** each step's final reply names `dart` as missing and names the guide section, and the agent's commands show no attempt to install a toolchain (`apt-get`, a downloaded SDK); a reply that works around instead, or names neither, is a defect in the note's wording, fixed and rerun
  - **Proof**: `cmd: DARTCLAW_CODING_IMAGE=dartclaw-agent:latest bash dev/testing/profiles/container/coding.sh --baseline --fixture dart` – exit 0, with both providers' replies quoted in Implementation Observations (TI06)


- **S06 [OC04] A missing custom image fails startup naming the build command**
  - **Given** a container runtime answering and `container.image: my-dart-agent:1`, which does not exist
  - **When** container isolation starts (`ensureImage`)
  - **Then** it fails with a message naming `docker build -t my-dart-agent:1` and `docs/guide/security.md` § Language Toolchains in the Agent Image, and no `docker build` ran
  - **And** with the default `dartclaw-agent:latest` missing, the stock image is still built from `docker/` as today
  - **And** `dartclaw doctor`'s `container.image` row for the missing custom image carries the same `docker build -t my-dart-agent:1` remediation
  - **Proof**: `packages/dartclaw_runtime/test/container/container_manager_test.dart#ensureImage fails for a missing custom image` – red at spec time (the existing `#ensureImage builds when image missing` stays green for the default); `apps/dartclaw_cli/test/commands/init/setup_checks_test.dart#container.image remediation names docker build for a custom image` – red at spec time


## Structural Criteria

- **SC01** The guide's recipes are the recipes the scenario builds: every line of `images/dart.Dockerfile` and `images/node.Dockerfile` appears verbatim in `docs/guide/security.md`.
- **SC02** `dev/state/PROMPT-SURFACES.md` names the container note on the task prompt's row, since an uninventoried prompt surface is a defect (its header).
- **SC03** The stock `docker/Dockerfile` and the `container:` config keys are unchanged by this story, and no deterministic missing-binary detection exists in host code.


## Scope & Boundaries

### Work Areas

- `dev/testing/profiles/container/images/` – new `dart.Dockerfile` and `node.Dockerfile`, the proven recipes.
- `dev/testing/profiles/container/coding.sh` (story S02's script) and its seed config – build and select the recipe image per fixture; `DARTCLAW_CODING_IMAGE` override; `dev/testing/README.md` row.
- `docs/guide/security.md` § Container Isolation – new subsection `### Language Toolchains in the Agent Image`.
- `packages/dartclaw_runtime/lib/src/task/task_executor_helpers.dart` (`_composePendingMessage`, `_initialPrompt`) and its call in `task_executor.dart` – the note; the test beside `task_execution_policy_routing_test.dart`.
- `packages/dartclaw_runtime/lib/src/container/container_manager.dart` (`ensureImage`) and `apps/dartclaw_cli/lib/src/commands/init/setup_checks.dart` (`container.image` row remediation), with their tests.
- `dev/state/PROMPT-SURFACES.md`, `CHANGELOG.md` (0.28.1).

### What We're NOT Doing

- A toolchain in the stock `docker/Dockerfile` – the image stays lean and the toolchain is the operator's choice per project (FR8 asks for a recipe).
- Any host-side detection of a missing binary: a `dartclaw doctor` row, a scan of tool output, an exit-127 handler – Architecture Decision and Constraints give the reasons.
- Dependency install: `dart pub get` and `npm install` fail until story S06 and story S07 ship the registry surface. The pub and npm cache capacity under the 100 MiB `/tmp` tmpfs is verified by story S06, the first story that can fill it.
- A second scenario, a new testing profile, or a config key. `DARTCLAW_CODING_IMAGE` is a variable of story S02's script, not product configuration.
- The note on a push-back prompt (a revision turn of a task whose first prompt carried it), on `restricted` containers, and on host tasks.
- Toolchains beyond Dart and Node.


## Architecture Decision

**Approach**: The recipes are two Dockerfiles in story S02's profile that the scenario builds and the guide mirrors (SC01), so the documented recipe is the proven one. The missing-toolchain message is model-reported: the host adds a short, fixed note to the first prompt of a `container/workspace` task, and the agent, the only party that knows which binary its command needed, reports it (ADR-054 Rule 1, `_initialPrompt` already carries host-built sections such as the working directory).
**Why this over the floor**: the floor, a documented recipe only, satisfies FR8's first criterion but not its second (a message naming the binary) or third (the scenario on recipe images). For the message the host cannot detect a missing binary deterministically: `ClaudeProtocolAdapter.parseLine` and `codexBuildCommandExecutionToolResult` both reduce a command result to `ToolResultMessage(output, isError)`, so the exit status never reaches host code and detection would scan prose, which is shell- and locale-dependent. ADR-054 Rule 1's no-prose-scraping bullet names model replies and inbound user text, not tool output, so it does not forbid the scan; it is rejected on practical grounds: no exit status reaches host code, and an agent that works around the missing binary produces no failure to scan. A `dartclaw doctor` check cannot know which binary a project's commands need and would warn on every stock-image install that runs no coding step.


## Constraints & Gotchas

- **Hardening shapes the recipe.** The container runs `--read-only` with `/tmp` a 100 MiB `noexec` tmpfs (`ContainerManager.start`); only `/workspace` and generated state are writable. Anything the toolchain writes at first use (pub cache, npm cache, SDK config) must be pointed at a writable path, and the toolchain itself installed at build time.
- **Recipe settings are image `ENV`.** Containerized runs see only what the image and `ContainerManager.exec(env:)` provide, not the host environment (LEARNINGS § Container / Deployment, hardening env vars), so `PATH` and cache locations belong in the Dockerfile, extending the base's `PATH`.
- **Only the default image is built automatically.** `ensureImage` (`container_manager.dart`) builds `docker/` only when `container.image` is the default `dartclaw-agent:latest` (compared with `const ContainerConfig().image`, so the kernel is untouched). For any other tag that is missing it throws a `StateError` naming `<runtime> build -t <image> <context>` and the guide's recipe section, and the existing `refuse` path in `SecurityWiring` reports it (exit 1 under `container.enabled: true`). The `container.image` doctor row's remediation names the same command for a custom image and keeps the stock-Dockerfile pointer for the default. The guide states: build first, then set `container.image`. This is breaking for anyone who tagged the stock image under another name and relied on the silent build; the CHANGELOG entry says so.
- **The note stays true after story S06 and story S07.** It claims only "no direct network access"; it never says installs are impossible.
- **Scenario image selection is S05's only change to story S02's script.** Flags, results format and teardown are story S02's; recipe images are left cached after a run (story S02's SC01 covers containers, temp dirs and fixtures, not images). Confirm with `git status` that `images/*.Dockerfile` is tracked despite `dev/testing/.gitignore`.

- The missing-toolchain message is model-reported through a host-built prompt note, not host-detected. A guaranteed message would need the command exit status carried through `ToolResultMessage` (Codex reports `exitCode`, Claude's tool result has none).
- A `dartclaw doctor` check against the configured image is rejected: it cannot know a project's binaries (V2(b) needs the project's test command, which lives in prose docs), runs before a step instead of when one fails, and would warn on every default-image install.
- A check on step or task failure output is rejected on practical grounds (see Architecture Decision): neither provider gives the host an exit status, and a step whose agent works around the missing binary never fails.
- The "container guide" of FR8 is `docs/guide/security.md` § Container Isolation, the only guide section that describes the agent image and `container.image`; a dedicated container guide is a doc split for story S09.
- Recipe images live in story S02's profile directory as proof artifacts with the guide mirroring them; shipping them under `docker/recipes/` would put them in the image build context `ensureImage` sends.
- Story S05 passes `--baseline`, per the plan's shared decision "Containerized coding scenario": install cannot succeed before story S06 and story S07, so exit 0 without `--baseline` is unreachable here; the non-baseline pass is story S07's.
- `DARTCLAW_CODING_IMAGE` (one variable, default unset = per-fixture recipe image) is how the stock-image run of scenario S05 reproduces story S02's baseline without a second scenario.
- Toolchain versions are chosen at execution, exact and not floating, satisfying the fixture's SDK and engine constraints from S02 (Dart no older than the 3.14 the repository builds with).
- Verify commands use `docker`; an executor on Podman substitutes the binary.
- **Written against story S02's FIS**, whose `coding.sh` does not exist yet: if story S02's execution renames its flags, results path or seed-config layout, apply the same edits by intent.


## Implementation Plan

### Implementation Tasks

- **TI01** `images/dart.Dockerfile` and `images/node.Dockerfile` exist: each `FROM dartclaw-agent:latest`, installs a version-pinned toolchain as root, sets `PATH` and writable cache locations as image `ENV`, and ends as `USER dartclaw`.
  - Prefer copying the toolchain from the official language image over a downloaded archive (architecture-agnostic).
  - **Verify**: the scenario S01 `cmd:` – exit 0.
  - **SATISFIES**: S01

- **TI02** The guide's `### Language Toolchains in the Agent Image` subsection holds both recipes verbatim, the `container.image` setting, the build-before-start rule with the startup failure for a missing custom image, and that the toolchain version is the operator's to pin and update; `CHANGELOG.md` 0.28.1 gains an entry.
  - **Verify**: `cmd: test -z "$(grep -vxFf docs/guide/security.md dev/testing/profiles/container/images/dart.Dockerfile dev/testing/profiles/container/images/node.Dockerfile)" && git grep -q "^### Language Toolchains in the Agent Image" -- docs/guide/security.md` – exit 0, every recipe line is in the guide and the heading exists.
  - **SATISFIES**: SC01, S01

- **TI03** `coding.sh` builds the selected fixture's recipe image on top of the stock image and runs that server with it as `container.image`; `DARTCLAW_CODING_IMAGE` overrides it for every fixture; the script header and `dev/testing/README.md` row say so.
  - Follow `dev/testing/profiles/container/run.sh` (the base image build) and story S02's seed-config templating.
  - **Verify**: the scenario S02 `cmd:` pair – exit 0, no missing-binary output in the results; `cmd: git grep -n "DARTCLAW_CODING_IMAGE" -- dev/testing/README.md dev/testing/profiles/container/coding.sh` – both files match.
  - **SATISFIES**: S02

- **TI04** A task whose runner policy is `container/workspace` gets the toolchain note in its first and retry prompts, composed by `_initialPrompt` from the policy `_executeCore` already passes as `runnerPolicy`; host and `restricted` tasks get none.
  - Follow `task_executor_helpers.dart#_initialPrompt` (working-directory section) for section style; `task_execution_policy_routing_test.dart` for a fake runner carrying a container policy, and `task_executor_workflow_oneshot_test.dart` (`### Working Directory` assertion) for reading the composed prompt, including the workflow one-shot path that receives the same `pendingMessage`.
  - **Verify**: `packages/dartclaw_runtime/test/task/task_execution_policy_routing_test.dart#workspace container prompt carries the toolchain note` – asserts the note names `container.image` and the guide anchor `language-toolchains-in-the-agent-image` and tells the agent to report the missing binary, for a retry too; and, in the same file, `#host and restricted prompts carry no toolchain note` – both absent.
  - **SATISFIES**: S03, S04

- **TI05** `PROMPT-SURFACES.md` describes the container note on the `_initialPrompt` row (free text, no host parse of the reply).
  - **Verify**: `cmd: git grep -q -i "toolchain" -- dev/state/PROMPT-SURFACES.md` – exit 0; `cmd: git diff --name-only -- docker/Dockerfile packages/dartclaw_kernel` – empty for this story's commits (SC03; scope the diff to the story's commits when others share the tree).
  - **SATISFIES**: SC02, SC03

- **TI06** The stock-image run of scenario S05 is recorded in this FIS's `## Implementation Observations` under the heading `Stock-image missing-toolchain report`, each provider's final reply quoted with the commands it ran.
  - **Verify**: the scenario S05 `cmd:` – exit 0; `cmd: grep -rq "Stock-image missing-toolchain report" dev/bundle/docs/specs/0.28.1` – the heading exists in the executed FIS copy.
  - **SATISFIES**: S05

- **TI07** A missing non-default `container.image` fails startup: `ensureImage` throws a `StateError` naming `docker build -t <image>` and the guide section instead of building the stock image under that tag, the default image is still built, and the `container.image` doctor row's remediation names the same command for a custom image. `CHANGELOG.md` 0.28.1 carries the entry with a breaking note for anyone who tagged the stock image under another name.
  - Pattern: `container_manager_test.dart#ensureImage builds when image missing` for the fake runner; the message text is the contract the tests assert verbatim on the command and the section name.
  - **Verify**: `packages/dartclaw_runtime/test/container/container_manager_test.dart#ensureImage fails for a missing custom image` and `apps/dartclaw_cli/test/commands/init/setup_checks_test.dart#container.image remediation names docker build for a custom image` – new tests; `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/container/container_manager_test.dart apps/dartclaw_cli/test/commands/init/setup_checks_test.dart` – both files green, including `ensureImage builds when image missing` for the default; `cmd: git grep -n -i "tagged the stock image" -- CHANGELOG.md` – the breaking note exists.
  - **SATISFIES**: S06

## Discovered Requirements

- **Container baseline and lifecycle**. **Description**: Reuse S02's `container/coding.sh` and existing renderer/recorder. Its four-case baseline recorded install/test exit 127 for missing Dart/npm, workspace placement on all tasks, unchanged Dart locks and no new Codex system-home rollouts. Disposable workflow generation changes only `gitStrategy.cleanup.enabled:false`; the profile collects retained worktree evidence and owns final teardown. **Rationale**: The live proof exposed cleanup and skill-materialization constraints absent at planning. **Interpretation**: Preserve the generated definition's steps and roles. Baseline mode permits terminal failures tied to recorded acceptance commands; awaiting approval and unrelated workflow failures still gate. Bundled `dartclaw-*` skills use managed copies; provider-native AndThen remains outside auth-clean containers under ADR-040 and the FIS boundary exception. Do not copy or mount host login/plugin directories. Consult S02's observations for exact receipts and the pre-fix trace-baseline drift. **Traced from**: S02/TI04–TI08. **Date**: 2026-11-17.

- **Person-owned execution holds**. **Description**: S03 holds automatic task accepts and workflow promotion/publish when execution-surface files or symlinks are changed. Agent-tool provenance cannot release those holds; host approval state uses reserved exact-data keys. **Rationale**: Live canaries now run behind the new deterministic review boundary. **Interpretation**: Never bypass a hold to make an unattended fixture pass. Ordinary code and instruction-file changes still proceed; person UI/API/channel-button action releases the held branch. Preserve `_workflow.git.execution_surface_hold` and `_workflow.git.approved_branches` as host-owned state if extending output/bridge paths. **Traced from**: S03/TI02, S03/TI05–TI07 and its discovered requirements. **Date**: 2026-11-17.
