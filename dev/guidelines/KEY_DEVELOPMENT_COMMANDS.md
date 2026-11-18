# Key Development Commands

## Running the Application

```bash
# HTTP server + web UI (default port 3000)
dart run dartclaw_cli:dartclaw serve
dart run dartclaw_cli:dartclaw serve --port 3333

# Check runtime status
dart run dartclaw_cli:dartclaw status
```


## CLI Management Commands

```bash
# Auth token management
dart run dartclaw_cli:dartclaw token show
dart run dartclaw_cli:dartclaw token rotate

# Rebuild search index
dart run dartclaw_cli:dartclaw rebuild-index

# Initialize, then install as a background service
dart run dartclaw_cli:dartclaw init
dart run dartclaw_cli:dartclaw service install
dart run dartclaw_cli:dartclaw service start
```


## Workflow Commands

```bash
# List available workflows (built-in + custom)
dart run dartclaw_cli:dartclaw workflow list
dart run dartclaw_cli:dartclaw workflow list --json

# Run a workflow by name
dart run dartclaw_cli:dartclaw workflow run <name> [--var KEY=VALUE ...]

# Check workflow run status
dart run dartclaw_cli:dartclaw workflow status [<run-id>]

# Validate a workflow YAML file (no server required)
# Prints grouped diagnostics: parse errors, validation errors, warnings
# Exit 0 — clean or warnings-only (definition would load)
# Exit 1 — parse error or validation errors (definition would be excluded)
dart run dartclaw_cli:dartclaw workflow validate <path>
```


## Build

```bash
# Install / sync dependencies (workspace root)
dart pub get

# REQUIRED after cloning or creating a git worktree, and after editing built-in
# templates, static files, skills, or workflow definitions. The embedded asset
# libraries are generated, not committed, and lib/ imports them — without this
# the analyzer reports ~32 errors and nothing compiles. CI and
# dev/tools/build.sh run it automatically.
dart run dev/tools/embed_assets.dart

# Build both binaries via `dart build cli`: build/bin/dartclaw and
# build/bin/dartclaw-workflow. Each binary gets its own release archive + checksum.
# First build: allow the manifest-pinned native embedding archive download.
DARTCLAW_NATIVE_ALLOW_DOWNLOAD=1 bash dev/tools/build.sh
# Later builds reuse .agent_temp/native-cache without downloading.
bash dev/tools/build.sh
```

`DARTCLAW_NATIVE_ARCHIVE_CACHE` overrides the default `.agent_temp/native-cache` directory under the repository root.
The archive's size and SHA-256 are verified before build outputs are cleared or assets generated. On Windows, set
`$env:DARTCLAW_NATIVE_ALLOW_DOWNLOAD = '1'` for the first `./dev/tools/build_windows.ps1` invocation; the same cache
default and override apply. Unset the download flag for subsequent offline archive reuse.


## Parallels Windows VM

On a macOS development host, `dev/tools/parallels_windows.sh` gives agents a limited set of VM-management operations
plus arbitrary guest command execution. It requires Parallels Desktop Pro, Business, or Enterprise and Parallels Tools
in the guest. Normal-user commands also require an active signed-in Windows session. The VM name defaults to
`Windows 11`; override it with `PARALLELS_WINDOWS_VM`.

```bash
# Inspect or prepare the VM.
./dev/tools/parallels_windows.sh status
./dev/tools/parallels_windows.sh start

# Run as the signed-in Windows user.
./dev/tools/parallels_windows.sh exec cmd.exe /d /c whoami
./dev/tools/parallels_windows.sh powershell path/to/script.ps1 [args...]

# Use only when elevation is required. These run as NT AUTHORITY\SYSTEM.
./dev/tools/parallels_windows.sh exec-system powershell.exe -NoProfile -Command Get-Service
./dev/tools/parallels_windows.sh powershell-system path/to/admin-script.ps1 [args...]

# Checkpoint, capture, and release resources.
./dev/tools/parallels_windows.sh snapshot before-change
mkdir -p .agent_temp
./dev/tools/parallels_windows.sh capture .agent_temp/windows.png
./dev/tools/parallels_windows.sh pause
```

The helper automatically starts or resumes the VM and waits for Parallels Tools' credential-free SYSTEM execution;
normal-user commands additionally wait for the active signed-in session. Destructive VM configuration, deletion, and
snapshot restoration are intentionally not exposed. Guest commands themselves are unrestricted inside Windows and can
access resources exposed to the guest. Treat each VM as single-caller: do not run concurrent helper invocations against
the same VM.

The `powershell*` commands translate the host script path through Parallels folder sharing. Share only the repository
or another narrow script directory with the guest – never the whole Mac home directory for unattended agent work.
`powershell-system` grants Windows SYSTEM access to that shared script path. For a non-standard `prlctl` location, set
`PARALLELS_PRLCTL`. Use raw `prlctl` only when the task explicitly requires an unsupported VM operation.

The portable mock test requires neither Parallels nor macOS and runs as part of `test_workspace.sh`:

```bash
bash dev/tools/parallels_windows_test.sh
```


## Parallels Linux Agent VM

For a reproducible Ubuntu 24 ARM64 desktop VM on an Apple Silicon Mac, follow
`dev/guidelines/PARALLELS_LINUX_AGENT_VM.md`. It covers Parallels Tools, Wayland automatic login, key-only SSH, restricted
host sharing, Cua Driver, optional native-Linux Docker conformance, cold-boot verification, snapshots, and per-agent
clones.

The guide is the provisioning source of truth. `dev/tools/parallels_linux.sh` is only a runtime lifecycle helper; do
not use it as a substitute for setup verification. Treat each VM as single-caller unless every agent has its own clone.


## CI-Equivalent Gate

Run this from the workspace root before pushing shared branches, before declaring a CI fix done, and after changes that
touch package boundaries, tests, build tooling, workflow definitions, or cross-package behavior. The commands cover
the GitHub `Check` job and add the local workspace tests, PostgreSQL and fitness gates. The fitness command owns
the Dart fitness suite in this run. The separate `PowerShell scripts` job uses the [Windows script check](RELEASE_PREPARATION.md#checks-on-this-machine-and-its-vms). The Linux release lane
below adds container posture. A test regression fails the local `tests` gate.

```bash
dart pub get --enforce-lockfile
dart pub get --directory dev/tools/mascot_favicon --enforce-lockfile
dart run dev/tools/embed_assets.dart
dart format --line-length=120 --output=none --set-exit-if-changed .
dart analyze --fatal-infos
bash dev/tools/test_workspace.sh --separate-fitness
# Proves plain PostgreSQL 14 first, then explicit pgvector/hybrid behavior.
# The runner may provision disposable resources with Docker or use supplied disposable endpoints.
bash dev/tools/postgres_contract.sh
dart run dev/tools/arch_check.dart
bash dev/tools/fitness/run_all.sh
git diff --check
git status --short
```

`dart run dev/tools/embed_assets.dart` also copies `dev/design-system/{tokens,components,icons}.css`
into the server's static assets, so canonical CSS edits need no separate sync step.

For release preparation, reuse completed review evidence with the input comparisons required by
[Release Preparation](RELEASE_PREPARATION.md), and run only missing or affected checks. Obtain `Check` and
`PowerShell scripts` once on the exact final squash SHA; local results carry through the ledger's input comparison
because the squash commit has the branch tip's Git tree. For a **clean committed release candidate** missing that local coverage,
`bash dev/tools/release_check.sh --version <version> --local` runs these local gates plus release cleanup/version
checks, the host build and the Lima `linux` gate, retaining per-gate receipts. Lima (`brew install lima`) creates
`dartclaw-release-linux` from `dev/tools/lima/linux.yaml`, without host mounts, and transfers the same committed
candidate. The guest runs the local gates (build included) with `--omit linux,ci`, then the root container posture
profile. To select only that lane:

```bash
bash dev/tools/release_check.sh --version <version> --gate linux
```

Add `--resume` to
reuse eligible results, `--status` to inspect them, or `--gate <id>` to rerun one gate. The dirty development checkout
still uses the individual commands above. See [Release Preparation](RELEASE_PREPARATION.md) for scope and exit codes.
PowerShell validation uses `dev/tools/check_powershell.ps1` both locally in Windows and in CI; PSScriptAnalyzer is required.

## Generated Artifacts

```bash
# Published config JSON Schema — rerun after any ConfigMeta change or a version bump
dart run packages/dartclaw_kernel/tool/generate_config_schema.dart

# Published workflow JSON Schema — rerun after any WorkflowDslRules change
dart run packages/dartclaw_workflow/tool/generate_workflow_schema.dart

# Operator config reference — rerun after the schema or curated core list changes
dart run dev/tools/render_config_reference.dart
```

`schemas/dartclaw.schema.json` is generated only. `bash dev/tools/fitness/run_all.sh` runs the same script with
`--check` and fails when the committed artifact has drifted from `ConfigMeta` or the workspace version, or is missing, naming this command.

`schemas/workflow.schema.json` is also generated only. The fitness harness checks it against `WorkflowDslRules` and
names the regeneration command when the artifact is missing or stale.

The generated region in `docs/guide/configuration.md` is projected from the committed schema. Its core table is
curated in `dev/tools/config_reference_core_keys.txt` and capped at 90 resolvable keys. The fitness run checks both
renderer behavior and reference drift, naming the regeneration command on failure.


## Package Discovery (pub.dev)

```bash
# Search pub.dev for packages
curl -s "https://pub.dev/api/search?q=<query>" | jq '.packages[:5]'

# Package details (versions, description, publisher)
curl -s "https://pub.dev/api/packages/<package_name>" | jq '{name: .name, latest: .latest.version, description: .latest.pubspec.description}'
```


## Code Quality (Formatting, Linting and Type Checking)

> **Line width: 120 chars** — enforced in analysis_options.yaml.

```bash
# Format a file or directory (120-char width configured in analysis_options.yaml)
dart format --line-length=120 <file_or_dir>

# Static analysis + lint (strict-casts, strict-raw-types, lints/recommended).
# Requires the generated asset libraries — see `dart run dev/tools/embed_assets.dart`
# under ## Build for when it must be run.
dart analyze
```


## Testing (Unit, Integration, E2E)

Pick a test file that owns the changed behavior. Run it by name while diagnosing a failure, then run the file.
Pass several files or a test directory from the same package to one invocation. Include a consumer when a public
contract, fixture, or shared helper changes. Use one process per package because some CLI and kernel suites
temporarily change the working directory.

On a fresh checkout, install both locked dependency sets listed in the [CI-equivalent gate](#ci-equivalent-gate).
The runtime's controller tests execute the shipped JavaScript with Node.js (22.7+ or 20.19.x).
The `andthen:exec-plan` tiers run from the workspace root. The fixed fast check exercises the assembled HTTP
handlers. A story also runs its own behavior proofs. The full tier runs developer-tool checks and each workspace
member's default tests, including slow process tests and Dart fitness. The CI-equivalent gate above adds real
PostgreSQL and the remaining fitness checks. A live proof needs its own file, prerequisites and explicit selector.

| Tier | Command |
|---|---|
| fast | `dart run dev/tools/embed_assets.dart && dart analyze --fatal-infos && dart test --reporter=failures-only packages/dartclaw_runtime/test/server_test.dart` |
| full | `bash dev/tools/test_workspace.sh` |
| run one test | `dart test --reporter=failures-only {file} --plain-name "{test}"` |

`{file}` and `{test}` come from the FIS proof. Use its literal test name, including punctuation. Check that the runner
reports the intended case and a positive pass count. A default-skipped suite can exit successfully with zero tests run.
For a named opt-in case, use its file and tag with `--run-skipped` after preparing its dependencies.

```bash
# One behavior, including literal parentheses in its name
dart test --reporter=failures-only packages/dartclaw_core/test/storage/session_service_test.dart \
  --plain-name "returns null for invalid UUID (path traversal defense)"

# One shared interface contract, or a whole affected directory
dart test --reporter=failures-only packages/dartclaw_core/test/search/search_backend_test.dart
dart test --reporter=failures-only packages/dartclaw_core/test/storage

# The isolated Knowledge Hub corpus exercises wiki, graph, memory and inbox together
dart test --reporter=failures-only packages/dartclaw_runtime/test/integration/knowledge_hub_corpus_integration_test.dart

# Workflow Bash steps: iterate on command behavior or exercise real OS deadlines and process termination
dart test --reporter=failures-only -x slow packages/dartclaw_workflow/test/workflow/bash_step_runner_test.dart
dart test --reporter=failures-only -t slow packages/dartclaw_workflow/test/workflow/bash_step_runner_test.dart

# Package scope, with optional exclusion of slow CLI build/process cases during iteration
dart test --reporter=failures-only packages/dartclaw_runtime
dart test --reporter=failures-only -x slow apps/dartclaw_cli

# Opt-in runtime composition with a fake harness
dart test --reporter=failures-only --run-skipped -t integration packages/dartclaw_runtime/test/runtime/server_builder_integration_test.dart

# Fast workflow validation while iterating on workflow YAML, gates, outputs, and review artifacts
bash dev/testing/profiles/workflow-contract/run.sh

# Targeted live workflow canaries (requires real provider binary + credentials)
bash dev/testing/profiles/workflow-live/run.sh --canary step-isolation
bash dev/testing/profiles/workflow-live/run.sh --canary implement-story
bash dev/testing/profiles/workflow-live/run.sh --canary implement-prd
bash dev/testing/profiles/workflow-live/run.sh --canary merge-resolve

# Full live workflow sweep when affected coverage requires the whole matrix
bash dev/testing/profiles/workflow-live/run.sh --full

# Full live sweep WITHOUT the heavy multi-minute agent e2e (tag: live-e2e).
# Fast iteration gate — keeps server/CLI/merge-resolve/fixture/step-isolation live tests.
bash dev/testing/profiles/workflow-live/run.sh --full --skip-e2e

# Only the heavy real-provider agent e2e (implement-story + implement-prd).
# Long-running — launch detached (e.g. nohup … & disown) and poll the log.
bash dev/testing/profiles/workflow-live/run.sh --e2e

# Per-package coverage
dart test --coverage=coverage/ packages/dartclaw_core
dart pub global run coverage:format_coverage \
  --lcov --in=coverage/ --out=coverage/lcov.info --report-on=lib/
```


---


## Visual Validation

See `VISUAL-VALIDATION-WORKFLOW.md` for project-specific conventions (server setup, auth, chrome-devtools, viewports, screenshot naming).

See `dev/testing/UI-SMOKE-TEST.md` for concrete numbered test cases (TC-01…TC-31).
