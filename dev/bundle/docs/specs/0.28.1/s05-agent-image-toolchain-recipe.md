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

- **Person-owned execution holds**. **Description**: S03 holds automatic task accepts and workflow promotion/publish when execution-surface files or symlinks are changed. Agent-tool provenance cannot release those holds; host approval state uses reserved exact-data keys. **Rationale**: Live canaries now run behind the new deterministic review boundary. **Interpretation**: Never bypass a hold to make an unattended fixture pass. Ordinary code and instruction-file changes still proceed; person UI/API/channel-button action releases the held candidate (ADR-063). Preserve `_workflow.git.execution_surface_hold` and `_workflow.git.approved_candidate` as host-owned state if extending output/bridge paths. **Traced from**: S03/TI02, S03/TI05–TI07 and its discovered requirements. **Date**: 2026-11-17.

## Implementation Observations

### Stock-image missing-toolchain report

Final frozen-input command: `DARTCLAW_CONTAINER_DATA_DIR=/Users/tobias/.dartclaw DARTCLAW_CODING_IMAGE=dartclaw-agent:latest bash dev/testing/profiles/container/coding.sh --baseline --fixture dart` -> exit=0. Receipt: `.agent_temp/container-coding/20261117T191918Z.WtRnih/results.md`. Both providers ran both acceptance commands inside workspace containers, each exit 127. Both final work-turn replies name `dart`, the guide anchor and `container.image`; every shell command below was inspected and shows no toolchain install/download, substitute runtime or host execution. Replies are preserved in `.agent_temp/s05/final-stock-messages/`. The earlier stock receipt at `.agent_temp/container-coding/20261117T184133Z.0BkXgW/` remains historical evidence; the final run replaces it as S05 acceptance proof.

#### claude final reply

> The FIS is written and structurally valid. Summary of this step:
>
> ## Specification written
>
> **`dev/specs/total/fis/s01-total-sum-integers.md`** — one FIS for the single story, carrying the AndThen provenance pair (`**Plan**:`, `**Story-ID**:`) above the first `##`, four Given/When/Then acceptance scenarios (`**S01**`–`**S04**`), and an `## Implementation Plan` with `**TI01**`–`**TI03**`.
>
> Scenario coverage maps to the three existing assertions plus a guard that the test file stays untouched:
>
> | Scenario | Behaviour |
> | --- | --- |
> | S01 | `total([2, 3, -1])` → `4` (mixed signs) |
> | S02 | `total([])` → `0` (empty iterable, no throw) |
> | S03 | `total([-4, -2])` → `-6` (all negative) |
> | S04 | `test/total_test.dart` unmodified |
>
> The plan prescribes `values.fold(0, (sum, value) => sum + value)`, keeping the `int total(Iterable<int> values)` signature byte-identical so the test's relative import keeps compiling. `fold`'s seed covers the empty case with no special-case branch. `test/total_test.dart` is explicitly out of scope per "Keep the existing tests."
>
> I also wrote **`dev/specs/total/plan.md`**, because the FIS's `**Plan**:` provenance field would otherwise point at a non-existent file. It is a single-row story table, not a synthesized PRD.
>
> I did not edit `total.dart` — implementation belongs to the next workflow step, and this step's declared outputs are the spec only.
>
> ## Acceptance commands — both failed
>
> Run in the task worktree, not on the host, with status captured:
>
> ```
> dart pub get → DARTCLAW_ACCEPTANCE_EXIT=127   bash: dart: command not found
> dart test    → DARTCLAW_ACCEPTANCE_EXIT=127   bash: dart: command not found
> ```
>
> **Missing binary: `dart`.** The container image provides no Dart toolchain. I did not install, download, or substitute a runtime. To run these commands, provision an image that ships Dart via `container.image` — see `docs/guide/security.md#language-toolchains-in-the-agent-image` (Language Toolchains in the Agent Image). Note that even with a `dart` binary, `dart pub get` would still need registry access to resolve `test: ^1.29.0`; the container has no network.
>
> ## In-container Git failure (recorded, not blocking)
>
> `git status` in the worktree fails:
>
> ```
> fatal: not a git repository: /Users/tobias/.../projects/coding-fixture/.git/worktrees/wf-3bb9f97f2301ba93
> ```
>
> The worktree's `.git` file points at a host path that isn't mounted. Recording this as an expected observation only — the host commits and publishes the worktree changes. I'm not requesting a wider mount or operator input for it.
>
> ## Step outcome
>
> `step_outcome.outcome` is **`failed`**, not `needsInput` — both acceptance commands failed with exit 127. The specification deliverable is complete, but S01–S03 remain unverified and I'm not claiming the tests passed.
>
> Declared outputs for the envelope:
> - **spec_path**: `dev/specs/total/fis/s01-total-sum-integers.md`
> - **spec_source**: `synthesized` (the feature arrived as an inline description, so this step authored the FIS)

Shell commands (all tasks in this provider run):

```sh
ls -la /workspace/.dartclaw/worktrees/wf-3bb9f97f2301ba93 2>&1 | head -50
find . -path ./.git -prune -o -type f -print 2>/dev/null | head -100
ls -la
ls -la .agents .claude test
ls -R .claude/skills
ls -la /workspace/.dartclaw/worktrees/wf-3bb9f97f2301ba93 2>&1; echo "---TREE---"; find /workspace/.dartclaw/worktrees/wf-3bb9f97f2301ba93 -not -path '*/.git/*' -maxdepth 3 2>&1 | head -60
which dart; echo "dart_exit=$?"; which flutter; echo "flutter_exit=$?"; git -C /workspace/.dartclaw/worktrees/wf-3bb9f97f2301ba93 status 2>&1 | head -20
cd /workspace/.dartclaw/worktrees/wf-3bb9f97f2301ba93; for f in story.md total.dart test/total_test.dart pubspec.yaml; do echo "=== $f ==="; cat "$f"; done
cd /workspace/.dartclaw/worktrees/wf-3bb9f97f2301ba93/.claude/skills; for d in dartclaw-discover-andthen-plan dartclaw-discover-andthen-spec; do echo "=== $d ==="; find "$d" -type f | head; echo "--- content ---"; cat "$d"/*.md 2>/dev/null; done
cd /workspace/.dartclaw/worktrees/wf-3bb9f97f2301ba93 && dart pub get; result=$?; echo "DARTCLAW_ACCEPTANCE_EXIT=$result"; exit "$result"
cd /workspace/.dartclaw/worktrees/wf-3bb9f97f2301ba93 && dart test; result=$?; echo "DARTCLAW_ACCEPTANCE_EXIT=$result"; exit "$result"
cd /workspace/.dartclaw/worktrees/wf-3bb9f97f2301ba93; ls -la; echo "=== AGENTS/CLAUDE ==="; ls AGENTS.md CLAUDE.md 2>&1; echo "=== specs dirs ==="; find . -not -path './.git/*' -type d -iname '*spec*' -o -type d -iname '*fis*' -o -type d -iname 'dev' 2>/dev/null; echo "=== any md ==="; find . -not -path './.git/*' -name '*.md' -type f 2>/dev/null
echo "=== workspace root ==="; ls -la /workspace 2>&1 | head -30; echo "=== andthen plugin search ==="; find / -name 'fis-template.md' -not -path '/proc/*' 2>/dev/null | head; echo "=== andthen dirs ==="; find / -type d -name 'andthen*' -not -path '/proc/*' 2>/dev/null | head
cat /workspace/AGENTS.md; echo "=== MEMORY ==="; cat /workspace/MEMORY.md
cd /workspace/.dartclaw/worktrees/wf-3bb9f97f2301ba93; F=dev/specs/total/fis/s01-total-sum-integers.md
echo "=== header block (H1 -> first ##) ==="
awk 'NR==1{next} /^## /{exit} {print}' "$F" | grep -nE '^\*\*(Plan|Story-ID)\*\*:'
echo "=== ## headings ==="
grep -nE '^## ' "$F"
echo "=== markers ==="
for m in '^\*\*S01 ' '^- \*\*Given\*\*' '^- \*\*When\*\*' '^- \*\*Then\*\*' '\*\*TI01' ; do printf '%-22s -> %s hits\n' "$m" "$(grep -cE "$m" "$F")"; done
echo "=== files written ==="
find dev -type f | sort
```


#### codex final reply

> Implemented `total` and added the synthesized FIS:
>
> - `spec_path`: [`spec.md`](/workspace/.dartclaw/worktrees/wf-11ad93ada4889a54/spec.md)
> - `spec_source`: `synthesized`
>
> Acceptance outcome: `failed`
>
> - `dart pub get`: exit `127`, `dart: not found`
> - `dart test`: exit `127`, `dart: not found`
>
> The in-container Git metadata was unavailable; the host should commit the worktree changes. See `docs/guide/security.md#language-toolchains-in-the-agent-image` and `container.image` for toolchain configuration.

Shell commands (all tasks in this provider run):

```sh
/bin/sh -lc "sed -n '1,240p' .agents/skills/dartclaw-discover-andthen-spec/SKILL.md"
/bin/sh -lc "sed -n '1,240p' .agents/skills/dartclaw-discover-andthen-plan/SKILL.md && printf '\\n---SPEC SKILL---\\n' && sed -n '1,240p' .agents/skills/dartclaw-discover-andthen-spec/SKILL.md && printf '\\n---FILES---\\n' && rg --files -g 'errors.md' -g 'total.dart' -g '*spec*' -g 'pubspec.yaml' -g 'test/**' -g '.andthen/**' -g 'docs/**' | head -200"
/bin/sh -lc "find . -maxdepth 4 -type f | sort | sed -n '1,240p'; printf '\\n--- root docs ---\\n'; for f in AGENTS.md CLAUDE.md errors.md; do if [ -f \""'$f" ]; then echo "### $f"; sed -n '"'1,240p' \""'$f"; fi; done; printf '"'\\n--- dart files ---\\n'; find . -type f \\( -name 'total.dart' -o -name 'pubspec.yaml' -o -path './test/*' \\) -print"
/bin/sh -lc "printf '%s\\n' '--- story.md ---'; sed -n '1,260p' story.md; printf '%s\\n' '--- total.dart ---'; sed -n '1,200p' total.dart; printf '%s\\n' '--- test ---'; sed -n '1,260p' test/total_test.dart; printf '%s\\n' '--- pubspec ---'; sed -n '1,160p' pubspec.yaml; printf '%s\\n' '--- git status ---'; git status --short; printf '%s\\n' '--- git metadata check ---'; git rev-parse --is-inside-work-tree"
/bin/sh -lc 'dart pub get; result=$?; echo "DARTCLAW_ACCEPTANCE_EXIT=$result"; exit "$result"'
/bin/sh -lc 'dart test; result=$?; echo "DARTCLAW_ACCEPTANCE_EXIT=$result"; exit "$result"'
/bin/sh -lc "printf '%s\\n' '--- total.dart ---'; sed -n '1,120p' total.dart; printf '%s\\n' '--- spec.md ---'; sed -n '1,220p' spec.md; printf '%s\\n' '--- status attempt ---'; git status --short"
```

### Recipe evidence and discoveries

- The exact official tags are `dart:3.14.0-sdk` and `node:24.22.3-bookworm-slim`; Docker built both on this ARM64 engine. The hardened UID/version proof prints uid 1000 for both, Dart 3.14.0, Node v24.22.3 and npm 11.19.1. The stock Dockerfile and kernel/config keys are unchanged.
- `dart --version` alone missed first-use analytics initialization. The initial recipe's `dart pub get`/`dart test` failed 255 with `FileSystemException: Creation failed, path = '/home/dartclaw/.dart-tool' (OS Error: Read-only file system, errno = 30)`. `XDG_CONFIG_HOME` and `DART_SUPPRESS_ANALYTICS=true` did not prevent it. Recipe `HOME=/tmp` routes this SDK state to the existing tmpfs; explicit provider homes remain separate. `dart pub --help` under hardening changed 255 to 0. SDK issue [62952](https://github.com/dart-lang/sdk/issues/62952) records that telemetry has not migrated to `DART_DATA_HOME`.
- Codex's `/bin/sh -lc` resets `PATH`. Before the recipe symlink, that exact shell returned `/bin/sh: 1: dart: not found` (127), despite the image's SDK `ENV PATH`. The `/usr/local/bin/dart` symlink changed the hardened login-shell `dart pub --help` probe to exit 0. This matters to S06's cache/registry proof: keep these image settings when extending the recipe.
- `.agent_temp/container-coding/20261117T180618Z.VRnJ02/` is diagnostic evidence only. Its raw four rows exposed those image defects, but its command exit 127 is invalidated: editing a wrapped shell line while Bash was reading the script shifted its read offset and produced `line 164: e: command not found`. No retry/self-copy machinery was added. The corrected matrix kept script, image, recorder and runtime inputs frozen.
- Corrected acceptance receipt: `.agent_temp/container-coding/20261117T182302Z.eh6UFD/results.md`. Both Dart providers: install 69 with `Got socket error trying to find package test at https://pub.dev`, test 1 during the same registry resolution. Both Node providers: install 1 with registry DNS failure, test 1 because lodash could not be installed. All eight tasks have workspace placement; both Dart locks are unchanged; Codex completed two steps per fixture and added zero system-home DartClaw rollouts. The script returned 0 and its missing-binary scan returned 0. All disposable resources were removed; recipe images remain cached by contract.

### Regression evidence and tidies

- TI04 first/retry and workflow positive tests failed before production changes with `Expected: contains '### Container Toolchains'` / `Which: does not contain '### Container Toolchains'`. Host/restricted parity and push-back absence stayed green. The routing file now passes 17 tests.
- TI07 startup repro failed before the fix with `Which: emitted <null>` instead of the expected StateError. Doctor repro reported `Actual: 'Build my-dart-agent:1 using docker/Dockerfile; see docs/guide/security.md.'`, missing the requested build command. Both bound tests now pass; their two files pass 89 tests, including the existing default-image build test.
- One `ContainerManager.missingImageRemediation` formatter supplies startup and doctor text. This small static API addition keeps the build instruction under the existing image owner rather than duplicating it across packages.
- Tidy: `_composePendingMessage` had an unused session argument and always returned a String. Its signature now reflects that, its sole caller is migrated, and the unreachable null-prompt failure branch plus unused `TaskFailureReason.absentPrompt` are removed. No reply parser or missing-binary detector was added.
- S03/S04 have no standalone Proof lines; TI04's bound routing tests supply the executable proof, with additional workflow and push-back cases.

#### DRIFT

- spec-stale: S05's side sentence assigns a dedicated container-guide split to S09, but S09 explicitly excludes that split. The existing security-guide section and anchor remain canonical. Recommend reconciling the stale peer-assignment sentence. | Stale targets: S05 Constraints & Gotchas, dedicated-guide sentence | –

### Executed proofs

- TI01 / S01: the FIS's exact three-build, two-UID and version command -> exit=0; uid 1000 in both images, Dart 3.14.0, Node v24.22.3, npm 11.19.1. Additional hardened `dart pub --help` and `/bin/sh -lc 'dart pub --help'` -> exit=0.
- TI02 / SC01: the FIS's `grep -vxFf` recipe mirror check and heading check -> exit=0; every Dockerfile line appears verbatim in the guide.
- TI03 / S02: `DARTCLAW_CONTAINER_DATA_DIR=/Users/tobias/.dartclaw bash dev/testing/profiles/container/coding.sh --baseline` -> exit=0; `codex/node: failed; install=1; test=1; Codex steps=2`. Final frozen-input four-row receipt `.agent_temp/container-coding/20261117T190434Z.PeIDWi/results.md`; missing-binary scan -> exit=0, no matches; `git grep -n DARTCLAW_CODING_IMAGE` -> exit=0, README and script match.
- TI04 / S03: bound workspace prompt selector -> exit=0, `+2: All tests passed!` (first and retry). Entire routing file including workflow one-shot and push-back -> exit=0, `+17: All tests passed!`.
- TI04 / S04: bound host/restricted selector -> exit=0, `+1: All tests passed!`; its expected prompt is byte-identical to the prior task/working-directory sections.
- TI05 / SC02: `git grep -q -i toolchain -- dev/state/PROMPT-SURFACES.md` -> exit=0. TI05 / SC03: `git diff --name-only -- docker/Dockerfile packages/dartclaw_kernel` -> exit=0 with empty output; direct diff inspection shows only fixed model guidance, no missing-binary detection or reply parse.
- TI06 / S05: forced-stock two-provider command above -> exit=0; both install/test pairs 127/127, four workspace tasks, zero new system-home Codex rollouts. Heading check -> exit=0; replies and every shell command quoted above.
- TI07 / S06: each bound runtime and doctor selector -> exit=0, `+1: All tests passed!`; both full files together -> exit=0, `+89: All tests passed!`. The default image's existing build test stays green. Breaking-note grep -> exit=0, matches `tagged the stock image`.
- Fast tier -> exit=0; analyzer `No issues found!`; kernel 1433, core 1757 (19 existing skips), search 62, workflow 2150 (11 existing skips), runtime 5757 (25 existing skips), CLI 857 (3 existing skips). Runtime count receipt retained separately because verbose fake wiring logs truncated the tool's output.
- Format -> exit=0, `Formatted 2234 files (0 changed) in 6.76 seconds.`; `git diff --check` -> exit=0 after removing whitespace from blank quote lines. No new TODO/placeholder implementation, skipped test or unconsumed surface found; image ENV and its login-shell behavior are runtime-proven, `__IMAGE__` is rendered by the existing config helper, and startup/doctor both consume the single remediation formatter.

### Chain Attestation

- OC01: TI01/TI02 satisfy S01 with the documented exact recipes, UID/hardening/version proof and build-first `container.image` selection.
- OC02: TI03 satisfies S02 with the four-case recipe baseline: all install/test commands ran in workspace containers and their only remaining cause is registry access; fixture tests and recorder/teardown gates are unchanged.
- OC03: TI04/TI05 satisfy S03/S04 with positive first/retry/workflow and negative host/restricted/push-back prompt tests; TI06 satisfies S05 with both stock-image replies and shell-command evidence, without a host detector or installation workaround.
- OC04: TI07 satisfies S06 with missing-custom refusal and shared doctor guidance, no custom build call, and the existing default-image build regression.
- Discovered Requirement Container baseline and lifecycle: both live receipts use S02's canonical definition/renderer/recorder, existing cleanup-only inspection copy and teardown; the diff changes image selection only and leaves source fixtures, recorder and approval/failure gates untouched.
- Discovered Requirement Person-owned execution holds: no approval/gate code or reserved metadata key changed; all live runs settled as acceptance-command failures under the unchanged baseline gate, without releasing or bypassing a hold.

### Verification follow-through

- A supplementary runtime-count receipt exposed a pre-existing capacity test synchronization gap: `a deferred message that loses the capacity race again waits for the next free slot` failed with `Expected: <2>`, `Actual: <1>`, while the initial fast tier had passed. The 200-pump poll did not await filesystem-backed redispatch. Minimum gate tidy in `conversation_loop_contract_test.dart`: one pump registers the completed capacity continuation, then existing `conversation.drain()` waits for tracked redispatch before the unchanged reserve-count assertion. Every state/execution assertion remains. The whole conversation file passes 25 tests; the full runtime rerun passes 5757 with 25 existing skips (`.agent_temp/s05/runtime-fixed.log`). Fast aggregate: 12016 passed, 58 existing conditional skips, zero failed.
- Procedural deviation: the fresh review hand-back raced the scope addition for that test-only tidy. The same reviewer received a followup after handing back and inspected the added diff, its synchronization owner and the 25-test receipt, rather than a fresh dispatch. The documentation worker was also resumed after its tag lookup to answer the later SDK-state question, instead of a fresh dispatch. It found no concern; no additional full review loop was run. The orchestrator was informed and accepted recording the deviation.
- Final-code recipe attempt `.agent_temp/container-coding/20261117T185839Z.z4LUBm/` -> exit=1 before install/test: `MissingArtifactFailure(field: spec_path, missing: [.dartclaw/worktrees/wf-2804fe98e428320d/story.md], ... reason: path claimed but not found under an allowed root)`. The classifier returned `spec_source: synthesized` but supplied a nonempty path, contrary to the bundled discovery skill's explicit empty-path contract. The host rejected the claim and the unchanged profile reported `Acceptance command evidence missing from persisted tool traces.` This receipt is a failed gate, not acceptance proof. The 1328-file runtime/profile/build input manifests before and after compare exactly equal. No output repair, baseline weakening, new retry or definition change was introduced.

- Resolution Ladder rung 2 (Widen): the orchestrator applied ADR-054's contract-miss rule, which fails the step and re-asks. One new invocation of the same whole profile on unchanged frozen inputs is the sanctioned re-ask, with a fresh profile run/worktree. The failed receipt remains; no output repair, weakened gate, duplicated discovery semantics, retry wrapper or product retry feature is added. A repeated classifier contract miss requires investigation of the existing activation/contract owner rather than more reruns.

### Final frozen-input acceptance

- Final recipe re-ask: `.agent_temp/container-coding/20261117T190434Z.PeIDWi/results.md` -> exit=0, `codex/node: failed; install=1; test=1; Codex steps=2`. Both Dart rows are 69/1 with pub.dev socket errors; both Node rows are 1/1 with registry.npmjs.org DNS errors and missing lodash after failed install. All eight tasks are workspace containers, both Dart locks are unchanged, and there are zero new system-home Codex rollouts. The exact prescribed latest-receipt missing-binary scan ran immediately afterwards -> exit=0, no matches.
- Final stock run: `.agent_temp/container-coding/20261117T191918Z.WtRnih/results.md` -> exit=0, `codex/dart: failed; install=127; test=127; Codex steps=2`. Four workspace tasks; zero new system-home Codex rollouts. Final replies and commands above satisfy TI06/S05.
- Exact input comparison: `.agent_temp/s05/final-inputs-before.json`, `final-inputs-after-recipe.json` and `final-inputs-after-stock.json` contain the same 1328 SHA-256 entries for runtime libraries/generated assets, CLI, Docker context, profile, fixture support and build inputs. Both `cmp` checks -> exit=0. No relevant source/script/recipe input changed across the successful final recipe and stock proofs. All scenario-owned containers/data/fixture copies were removed; cached recipe images remain by contract.
- Final analyzer -> exit=0, `No issues found!`; final workspace format -> exit=0, `Formatted 2234 files (0 changed) in 4.68 seconds.`; final runtime -> exit=0, `+5757 ~25: All other tests passed!`. No required acceptance proof remains open. Full tier and candidate release gates remain with the parent under `--no-full-tier`.

Reviewed: S05 quick code+gap and added capacity-test synchronization pass found no new actionable defect; hardened Dart/Node probes and 25 conversation tests passed; full-runtime rerun and final-tree recipe matrix remain with the implementer.

The review line is retained verbatim from `.agent_temp/s05/review.md`; its pending validation context was subsequently closed by the final runtime and frozen-input live receipts above. No review finding remains open.
