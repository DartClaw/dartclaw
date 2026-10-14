**Plan**: dev/bundle/docs/specs/0.28/runtime-cwd-single-authority/plan.json
**Story-ID**: S01

## Feature Overview and Goal

**Intent**: `DartclawRuntime.build(runtimeCwd:)` / `stageHeadless(runtimeCwd:)` reaches only task wiring today. An injected directory therefore splits one runtime across two repositories: worktrees and `PROJECT: _local` workflow runs use the injected one, while agent spawns, behavior files, the container `/project` mount and `ProjectService.localProject` use the process cwd. Runtime tests pass or fail depending on where `dart test` runs.

**Expected Outcomes**:

- [OC01] A caller that injects the runtime directory gets every repository-scoped surface – agent spawn directory, behavior files, model-catalogue probe, container `/project` mount, container-mode project registration – rooted there, whatever the process cwd.
- [OC02] The implicit `_local` project has one answer, the injected runtime directory, owned by the project service; without a project service no code substitutes the process cwd.
- [OC03] A test can no longer depend on the process cwd by accident: the constructors that take a directory require it, and no runtime suite assigns `Directory.current` in-process.


## Acceptance Scenarios

- **S01 [OC01,OC03] Agent spawns and behavior files follow the injected directory**
  - **Given** a harness wiring composed with runtime directory R, where R holds `.dartclaw/SOUL.md` and the process cwd is a different directory without one
  - **When** the primary harness, a worker and the model-catalogue probe are created and behavior files are loaded
  - **Then** every `HarnessFactoryConfig.cwd` the factory receives is R, and the project-`SOUL.md` deprecation warning fires for R's `.dartclaw`

- **S02 [OC01] [runtime] The container `/project` mount is the injected directory**
  - **Given** the container parity composition with the checkout root injected as both the runtime directory and the source-checkout directory, run with the process cwd at `packages/dartclaw_runtime`
  - **When** the owner and agent `c` acquire container leases
  - **Then** each lease's container manager maps the checkout root to `/project` and its spawn `cwd` is the checkout root, and the same holds when run from the repo root

- **S03 [OC02] Every `_local` resolution agrees on the injected directory**
  - **Given** a headless runtime built with runtime directory R while the process cwd is elsewhere
  - **When** the project service's `_local` project and a workflow run with `PROJECT: _local` are resolved
  - **Then** both resolve to R

- **S04 [OC01] Container-mode local-path registration is judged against the injected directory**
  - **Given** a composed server with containers enabled and a project service whose `_local` path is R, R not the process cwd
  - **When** a runtime local-path project is registered inside R, and another outside every mounted root
  - **Then** the first is accepted, and the second is refused `LOCAL_PATH_NOT_MOUNTABLE` with `mountRoots` naming R and not the process cwd

- **S05 [OC02] Without a project service, nothing claims the process cwd as `_local`**
  - **Given** conversation and session routes composed with no project service
  - **When** a non-owner session's context initializes, a context change names `_local`, and a retained file reference is re-validated
  - **Then** the session gets the owner-workspace context, so its file suggestions come from the owner workspace. The `_local` change is refused `PROJECT_FORBIDDEN`. The re-validated reference, which resolves with no context root, is refused `409 REFERENCE_UNAVAILABLE` and is not resolved under the process cwd


## Structural Criteria

- **SC01** Runtime and core library code read the process cwd in two places only: the `DartclawRuntime` `runtimeCwd` default, and the `SecurityWiring` source-checkout default that locates DartClaw's image build context and `build/bridge`.
- **SC02** No `dartclaw_runtime` suite assigns `Directory.current` in-process. `test/static/fixtures/unrelated_cwd_node_harness_fixture.dart` stays: `controller_test_support_test.dart` runs it in its own process.
- **SC03** Contributor docs under `dev/` (bundle excluded) and the runtime `CLAUDE.md` name only seams that exist. The `runtimeCwd` bullet lists every consumer and both remaining process-cwd reads with their reasons. No such doc cites `withWiredCurrentDirectory`, `WorktreeManager(currentDirectory:)` or `_local` as `Directory.current.path`. `docs/guide/projects-and-git.md` and ADR-017 keep their wording: the first is still accurate for the CLI, the second is historical.
- **SC04** The bash step runner refuses a step context without a data directory instead of substituting the process cwd.


## Scope & Boundaries

### Work Areas
- `packages/dartclaw_runtime/lib/src/runtime/` – `service_wiring.dart`, `harness_wiring.dart`, `harness_wiring_model_catalogue.dart`, `security_wiring.dart`, `project_wiring.dart`
- `packages/dartclaw_runtime/lib/src/project/project_service_impl.dart`, `packages/dartclaw_core/lib/src/project/project_service.dart` (doc)
- `packages/dartclaw_runtime/lib/src/server.dart` (`_projectRouteContainerMountRoots`)
- `packages/dartclaw_runtime/lib/src/conversation/conversation_service_persistence.dart`, `api/session_routes_support.dart`, `api/session_attachment_routes.dart`, `api/session_message_routes.dart`
- `packages/dartclaw_runtime/lib/src/container/container_manager.dart`, `container/bridge_binary.dart`, `task/task_executor.dart`, `task/worktree_manager.dart`
- `packages/dartclaw_workflow/lib/src/workflow/bash_step_runner.dart`
- Test fixtures and suites: `test/runtime/harness_wiring_fixture.dart`, `general_project_context_composition_test.dart`, `container_provider_parity_integration_test.dart`, constructor call sites of the changed classes, including `packages/dartclaw_workflow/test/workflow/scenario_test_support.dart` (`TaskExecutor`, `StaticPathWorktreeManager`)
- Docs: `packages/dartclaw_runtime/CLAUDE.md`, `dev/state/LEARNINGS.md`, `dev/guidelines/TESTING-STRATEGY.md`, `dev/architecture/data-model.md`, `dev/architecture/system-architecture.md`, `CHANGELOG.md`

### What We're NOT Doing
- No `--project-dir` flag or config key for `_local`. The CLI keeps the process cwd through the `DartclawRuntime` default, so `docs/guide/projects-and-git.md`'s note that `_local` is the launch directory stays accurate.
- Not routing the image build context or the bridge source tree through the runtime directory. Both locate DartClaw's own checkout, not the repository the runtime operates on, and get their own source-checkout directory on `SecurityWiring`.
- Not unifying that source-checkout directory with `WorkflowAssetSourceResolver`'s upward discovery. That is the workflow package's own checkout lookup.
- Not touching `dartclaw_workflow`'s source-checkout discovery (`workflow_materializer.dart`, `workflow_asset_source_resolver.dart`), `cli_skill_introspector.dart`'s `hostWorkingDirectory`, or the CLI's invocation-directory reads. The introspector value is inert because it passes no container manager. The CLI reads are the process boundary.
- Not making `ProjectService` non-nullable across server deps and routes. The null case is a composition without projects, and scenario S05 defines it.
- Not moving the server's mount-root computation onto `SecurityWiring`'s mount set. `_projectRouteContainerMountRoots` re-derives that set from config, which is a separate one-authority question.


## Architecture Decision

**Approach**: `DartclawRuntime.runtimeCwd` stays the one owner, and its constructor default is the only production read of the process cwd for the runtime's repository. Each wiring that means "the runtime's repository" takes it as a required constructor input. `_local` consumers read it from `ProjectService.localProject`, the existing `_local` authority, and a composition without a project service has no `_local`. "Where is DartClaw's own checkout" gets one owner too: an optional source-checkout directory on `SecurityWiring`, defaulting to the process cwd, which the container layer below receives as required input.
**Why this over the floor**: the floor is to leave the reads in place and document them. The brief's done-when rules it out twice: one owner must supply the directory to every site that means it, and the parity test must inject the directory and pass from any cwd. So does the live split in Intent. Threading the directory into `ConversationService` and `sessionRoutes` for the no-project-service case was rejected. About 90 test constructions would change for a branch production never takes, and it would keep a second `_local` resolver.
**Flow**: `DartclawRuntime(runtimeCwd)` → `ProjectWiring` → `ProjectServiceImpl.localProject` → {server mount roots, conversation `_local`, session reference root}; → `SecurityWiring` (`/project` mount); → `HarnessWiring` (behavior files, spawn `cwd`, catalogue probe); → `TaskWiring` (unchanged). Separately, `SecurityWiring(source checkout)` → `ContainerManager.buildContextDir` and `BridgeBinaryProvisioner.sourceTreeDir` (`<checkout>/build/bridge`).


## Constraints & Gotchas

- **Constraint**: test fixtures that gain the runtime-directory parameter must not default it to `Directory.current.path`, because that reintroduces the hazard this removes. Workaround: `wireTestSecurity` and `wireTestHarness` (`test/runtime/harness_wiring_fixture.dart`) default it to the per-test `dataDir`. The source-checkout directory needs no fixture default: only container suites use it, and they pass the checkout root.
- **Constraint**: changing a constructor to a required parameter fans out across test call sites: about 70 `WorktreeManager`, 27 `ContainerManager`, 9 `SecurityWiring`, 8 `HarnessWiring`, 6 `TaskExecutor` and 5 `BridgeBinaryProvisioner`. Workaround: give each test a per-test temp directory (or the `dataDir` it already has), never the process cwd.
- **Constraint**: the parity suite is `@Tags(['integration', 'slow'])` and needs Docker. The Key Dev Commands run-one-test row reports a skip as a pass, so its Verify runs `--run-skipped` explicitly. From the package directory it finds the bridge only through the source-checkout directory, because a fresh checkout embeds no bridge (`dev/tools/embed_assets.dart`, `build/bridge-embed` is optional).


## Implementation Plan

### Implementation Tasks

- **TI01** `HarnessWiring` takes a required runtime directory. The behavior service's project directory is `<dir>/.dartclaw`, and every `HarnessFactoryConfig.cwd` built by `_buildFactoryConfig` and `_discoverModelCatalogue` is that directory.
  - `general_project_context_composition_test.dart` injects the directory through `wireTestHarness`. It no longer assigns or reads `Directory.current`.
  - **Verify**: `packages/dartclaw_runtime/test/runtime/general_project_context_composition_test.dart#primary composed owner turns dispatch general workspace and explicit checkout` – passes with the process cwd untouched. New `packages/dartclaw_runtime/test/runtime/model_catalogue_discovery_test.dart#factory configs carry the injected runtime directory` asserts that the primary, a worker and the probe `HarnessFactoryConfig.cwd` equal R, not `Directory.current.path`, and that the project-`SOUL.md` deprecation warning is logged for `<R>/.dartclaw/SOUL.md`. `git grep -l "Directory\.current = " -- packages/dartclaw_runtime/test` lists only `test/static/fixtures/unrelated_cwd_node_harness_fixture.dart`.
  - **SATISFIES**: S01, SC02

- **TI02** `SecurityWiring` takes a required runtime directory, and both `SecurityProfile.workspace(projectDir:)` sites in `_wireContainers` use it. It also takes an optional source-checkout directory, defaulting to the process cwd, which supplies the image build context and the bridge's `build/bridge` source tree. The parity test injects the checkout root as both through `wireTestSecurity`, and as the runtime directory into `HarnessWiring`. Depends on TI01.
  - **Verify**: `cmd: cd packages/dartclaw_runtime && dart test --run-skipped --reporter=failures-only test/integration/container_provider_parity_integration_test.dart --name "production acquisition pins each workspace"` – passes from the package directory. The same command run from the repo root with the file path prefixed by `packages/dartclaw_runtime/` passes too.
  - **SATISFIES**: S02

- **TI03** `ProjectServiceImpl` takes the `_local` directory as required input, used for both `localPath` and the derived name. `ProjectWiring` passes the runtime directory. Core's `ProjectService.localProject` doc names the runtime's working directory.
  - **Verify**: `packages/dartclaw_runtime/test/project/project_service_impl_test.dart#creates _local project` – extended so `_local.localPath` equals the injected directory. `packages/dartclaw_runtime/test/runtime/headless_runtime_test.dart#local project fallback resolves against runtime cwd instead of launch cwd` – already proves the `PROJECT: _local` run resolves in `runtimeCwd`; extended so it also asserts the project service's `localProject.localPath` equals that `runtimeCwd`.
  - **SATISFIES**: S03

- **TI04** The server's project-route container mount roots take the runtime directory from `ProjectService.localProject.localPath`, with or without a config. Depends on TI03.
  - **Verify**: new `packages/dartclaw_runtime/test/server_test.dart#container-mode local-path registration is judged against the _local directory` composes a server with containers enabled and a `FakeProjectService` whose `_local` is a temp directory R. It asserts S04's acceptance inside R and its refusal outside, with `mountRoots` naming R.
  - **SATISFIES**: S04

- **TI05** A composition without a project service has no `_local`. `_ensureContext` gives a non-owner session the owner-workspace context. `_validatedContext` refuses `_local` with `PROJECT_FORBIDDEN`. `sessionReferenceRoot` returns no root. With no root, file suggestions are skipped and a file reference is unresolvable.
  - **Verify**: new `packages/dartclaw_runtime/test/conversation/effective_session_context_test.dart#no project service yields no implicit _local` asserts the owner-workspace context and the `PROJECT_FORBIDDEN` refusal. New `packages/dartclaw_runtime/test/api/session_routes_test.dart#retained file reference without a project service is unavailable` asserts `409 REFERENCE_UNAVAILABLE`.
  - **SATISFIES**: S05

- **TI06** `ContainerManager.buildContextDir` and `BridgeBinaryProvisioner.sourceTreeDir` are required, and `SecurityWiring` supplies both from its source-checkout directory. The `defaults buildContextDir to current working directory` test is removed. Depends on TI02.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/container` – green.
  - **SATISFIES**: SC01

- **TI07** `TaskExecutor.currentDirectory` is required.
  - **Verify**: `cmd: dart analyze --fatal-infos` – clean across the workspace, including the `dartclaw_workflow` call sites. `dart test --reporter=failures-only packages/dartclaw_runtime/test/task` is green.
  - **SATISFIES**: SC01

- **TI08** `WorktreeManager` has one required `projectDir`. The `currentDirectory` parameter and the `CurrentDirectoryProvider` typedef are gone.
  - **Verify**: `cmd: git grep -n "CurrentDirectoryProvider" -- packages apps` – exits 1 (no match). `dart analyze --fatal-infos` is clean, and `dart test --reporter=failures-only packages/dartclaw_runtime/test/task/worktree_manager_test.dart packages/dartclaw_workflow/test/workflow/scenarios` is green.
  - **SATISFIES**: SC01

- **TI09** `DartclawRuntime` reads the process cwd once and passes the resolved directory to `ProjectWiring`, `SecurityWiring` and `HarnessWiring` as well as `TaskWiring`. `localFallbackDir` derives from the resolved value, not a second read. Depends on TI01–TI08.
  - **Verify**: `cmd: git grep -l "Directory\.current" -- packages/dartclaw_runtime/lib packages/dartclaw_core/lib` – lists only `service_wiring.dart` and `security_wiring.dart`. Within `service_wiring.dart`, only the `runtimeCwd` default and its doc comment read it. The TI03 headless case exercises the composed path end to end.
  - **SATISFIES**: S01, S03, SC01

- **TI10** `bashStepRun` refuses a context without `dataDir` with a `StateError`, beside its existing required-field check.
  - **Verify**: new `packages/dartclaw_workflow/test/workflow/bash_step_runner_test.dart#refuses a context without a data directory` asserts the refusal.
  - **SATISFIES**: SC04

- **TI11** The docs listed in Work Areas are current:
  - The runtime `CLAUDE.md` `runtimeCwd` bullet names every consumer from the Flow and both remaining process-cwd reads with their reasons. It also says why the workflow and CLI reads in What We're NOT Doing are not the runtime directory.
  - Its Testing note cites only seams that exist.
  - `LEARNINGS.md` and `TESTING-STRATEGY.md` cite `WorktreeManager(projectDir:)`.
  - `data-model.md` and `system-architecture.md` define `_local` as the runtime's working directory.
  - The comment in `service_wiring_login_store_collision_test.dart` no longer says `ProjectWiring` reads `Directory.current`.
  - `CHANGELOG.md` 0.28.0 gets a Fixed entry: an injected `runtimeCwd` now reaches agent spawns, the container `/project` mount and `_local`.
  - **Verify**: `cmd: git grep -n -i -E "withWiredCurrentDirectory|WorktreeManager\(currentDirectory:\)|synthesized from .Directory\.current" -- dev ':(exclude)dev/bundle' packages/dartclaw_runtime/CLAUDE.md` – exits 1 (no match). Then `inspect: packages/dartclaw_runtime/CLAUDE.md` – the `runtimeCwd` bullet under § Runtime composition lists the consumers in the Flow and the two remaining reads with reasons.
  - **SATISFIES**: SC03

## Implementation Observations

#### DRIFT

- ambiguous-intent: S05 clause 3 and TI05's `409 REFERENCE_UNAVAILABLE` for a retained file reference are unreachable. `_validateReferences` checks file references against the stored context root and hands `referenceValidator` only non-file references, so `resolveConversationReference` never sees a file reference with no root. `sessionReferenceRoot` now returns null without a project service, and `session_routes_test.dart#retained file reference without a project service is unavailable` asserts that layer (`resolveConversationReference` refuses a file present under the process cwd with `UNKNOWN_REFERENCE`) | Stale targets: S05 Then-clause, TI05 Verify | –
- spec-stale: TI05's `_validatedContext` refusal needed no new branch. A `_local` id with no project service already reached the existing `projects == null` throw (`PROJECT_FORBIDDEN`); the change removed the `Directory.current` fallback from `_ensureContext` and `_validatedContext`'s root, and the now-dead `_local` special case in the `projects == null` arm | Stale targets: TI05 | –
- spec-stale: Work Areas omit `dev/guidelines/KEY_DEVELOPMENT_COMMANDS.md`, whose Parallelism note cited `WorktreeManager(currentDirectory:)`. TI11's Verify greps all of `dev/`, so it was fixed with the other three docs | Stale targets: Work Areas docs list | –

#### Best readings taken

- TI01: "`HarnessFactoryConfig.cwd` ... is that directory" is read as the runtime directory R itself (S01 says R), while the behavior service's project directory is `<R>/.dartclaw`.
- TI09: `localFallbackDir` became a getter over a private posture flag (`_localRepositoryPosture ? runtimeCwd : null`), because a constructor initializer list cannot reuse the resolved `runtimeCwd` initializer.
- TI06/TI07/TI08 test call sites that never read the path (fake process runners, fake git runners) pass literal `/tmp/...` paths beside their existing literal state dirs, or a per-test temp dir where one already existed (`claude_code_harness_mcp_test.dart`). None passes the process cwd.
- `HarnessWiring`'s capability probe `HarnessFactoryConfig(cwd: '/')` in `_buildModelCatalogueDiscovery` is left as is: it never spawns.

#### Review notes

- Fixed in review: `WorktreeManager._resolveBranchName`/`_branchExists` took a nullable `projectDir` with a dead `?? _projectDir` fallback; both now require it. Stale comments claiming production passes `Directory.current.path` as the harness cwd (`claude_code_harness_mcp_test.dart`) or that sibling suites assign `Directory.current` (`harness_registrar_test.dart`, `service_wiring_andthen_skills_test.dart`, `service_wiring_local_path_bootstrap_test.dart`) were reworded.
- `conversation_service_persistence.dart` `_ensureContext`: in a composition with no project service, a session whose stored `nextContext` already names `_local` (persisted before this change) gets `PROJECT_FORBIDDEN` on every submit until a manual context change, because `_ensureContext` returns early when `nextContext` is set. S05 asks for this refusal and production always composes a project service, so it is a recovery-UX question, not a defect. | Routing: Note
