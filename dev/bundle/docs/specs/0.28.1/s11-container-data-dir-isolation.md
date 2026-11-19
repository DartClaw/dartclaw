# S11: Container data-dir isolation

**Plan**: dev/bundle/docs/specs/0.28.1/plan.json
**Story-ID**: S11

## Feature Overview and Goal

**Intent**: `dartclaw service install` starts `serve` from the instance directory, which is the data directory, so every `workspace` container mounts the credential store and `gateway_token` read-only at `/project`, and project git credentials sit in askpass files inside the `/projects` mount. This story keeps a workspace container from ever seeing DartClaw's data directory or a git credential, whatever directory `serve` starts from.

**Expected Outcomes**:

- [OC01] When `serve` runs from its data directory, which is the service-install layout, a workspace container sees no file of the data directory and still starts and runs turns.
- [OC02] When `serve` runs from a directory that contains the data directory, which is the dev and example layout, the container sees the project at `/project` with the data directory's location empty, and no host path inside the data directory translates into that empty location.
- [OC03] A git credential DartClaw writes for a project fetch or push is never inside any container mount.
- [OC04] Operators can find out what changed: the changelog names the exposure and says to restart, the security docs state the rule, and `serve` logs one INFO line for each source it skips or masks.


## Required Context

- `dev/architecture/security-architecture.md#lifecycle-and-flags`: the `create` flag listing this story changes.
- `dev/architecture/security-architecture.md#profiles-and-authorities`: the profile mount table and the named-agent paragraph this story changes.
- `dev/architecture/security-architecture.md#git-credentials`: the askpass paragraph this story moves.


## Acceptance Scenarios

- **S01 [OC01] The service-install layout mounts nothing of the data directory**
  - **Given** `runtimeCwd` equal to the data directory, which holds `gateway_token` and `credentials/claude/setup-token.json`
  - **When** the owner's workspace authority mounts are composed
  - **Then** no mount source equals or contains the data directory, there is no `/project` target, `/workspace`, `/projects` and the `SecurityProfile.packageCachePath` volume are still mounted, the working directory is `/workspace`, and one INFO record (never WARNING) names the skipped source and says it is the data directory
  - **Proof**: `packages/dartclaw_runtime/test/runtime/security_wiring_data_dir_mount_test.dart#a runtime directory equal to the data directory is not mounted` – red at spec time (file does not exist)

- **S02 [OC02] A data directory inside the runtime directory is masked at /project**
  - **Given** `runtimeCwd` is a temp repo and the data directory is `<repo>/.dartclaw-example`
  - **When** the owner's workspace authority mounts are composed
  - **Then** they hold `<repo>:/project:ro` plus the bare spec `/project/.dartclaw-example`, beside the unchanged `/workspace`, `/projects` and package-cache specs, the working directory is `/project`, and one INFO record names the source and the masked path
  - **Proof**: `packages/dartclaw_runtime/test/runtime/security_wiring_data_dir_mount_test.dart#a data directory inside the runtime directory is masked at /project` – red at spec time

- **S03 [OC01] A source that is the data directory, or resolves into it, is not mounted**
  - **Given** a data directory `D` that holds `gateway_token`, passed to the rule once by its real path and once through a symlink to `D` (an operator's symlinked data directory)
  - **When** the rule maps `D`'s real path, `D/logs`, and a symlink outside `D` that points at `D/logs` to `/project`
  - **Then** each yields no mount spec and a reason naming the data directory, under both spellings of `D`
  - **Proof**: `packages/dartclaw_runtime/test/container/data_dir_mount_rule_test.dart#a source inside the data directory, directly or through a symlink, yields no mount` – red at spec time

- **S04 [OC02] A source containing the data directory gets the mask at the data directory's container path**
  - **Given** a source `R` with the data directory at `R/a/data`, and a second case where `R` is reached through a symlink
  - **When** the rule maps `R` to `/projects/demo`
  - **Then** the specs are exactly `R:/projects/demo:ro` and `/projects/demo/a/data` (a bare container path, the anonymous-volume form `SecurityProfile.packageCachePath` uses), and the bind source keeps the caller's spelling
  - **Proof**: `packages/dartclaw_runtime/test/container/data_dir_mount_rule_test.dart#a source containing the data directory masks it with an anonymous volume` – red at spec time

- **S05 [OC01] Unrelated sources and DartClaw-owned project clones mount unchanged**
  - **Given** a source unrelated to the data directory, and a source at `<data_dir>/projects/<id>` (inside `config.projectsClonesDir`) or `<data_dir>/workspace/.dartclaw/worktrees/<id>` (inside `config.workspaceDir`), and a named agent's own `<data_dir>/agents/<id>/workspace` passed as the authority's workspace directory
  - **When** the rule maps each to `/project`
  - **Then** each yields exactly `<source>:/project:ro` and no reason
  - **Proof**: `packages/dartclaw_runtime/test/container/data_dir_mount_rule_test.dart#an unrelated source or a DartClaw-owned project directory mounts unchanged` – red at spec time (the rule does not exist); the outcome it pins is today's, as `test/integration/container_provider_parity_integration_test.dart`'s `authorizedProject` mount shows

- **S06 [OC01,OC02] Local-path projects and a named agent's execution directory follow the same rule**
  - **Given** a `localPath` project equal to the data directory, a second whose `localPath` contains it, and a named agent with its own workspace whose `executionDir` is the data directory
  - **When** the project mounts and the agent's authority mounts are composed
  - **Then** the first project has no `/projects/<id>` mount, the second has its bind plus the mask under `/projects/<id>/`, and the agent's authority has no `/project` mount and working directory `/workspace`
  - **Proof**: `packages/dartclaw_runtime/test/runtime/security_wiring_data_dir_mount_test.dart#local-path projects and a named agent's execution directory follow the data directory rule` – red at spec time

- **S07 [OC02] A host path under a masked location does not translate**
  - **Given** a `ContainerManager` whose mounts are S02's plus `<repo>/.dartclaw-example/workspace:/workspace:rw`
  - **When** `containerPathForHostPath` is asked for `<repo>/lib`, `<repo>/.dartclaw-example/workspace/x` and `<repo>/.dartclaw-example/credentials`
  - **Then** it answers `/project/lib`, `/workspace/x` and `null`
  - **Proof**: `packages/dartclaw_runtime/test/container/container_manager_data_dir_mask_test.dart#a host path under a masked data directory does not translate` – red at spec time

- **S08 [OC03] Askpass files live outside every container mount**
  - **Given** a GitHub-token credential and a legacy API-key credential
  - **When** `resolveGitCredentialPlan` builds each plan
  - **Then** `GIT_ASKPASS` and its `.token` / `.key` file are under `<data_dir>/git-askpass/`, that directory's mode is 0700, and `<data_dir>/projects/` holds nothing (or does not exist)
  - **Proof**: `packages/dartclaw_runtime/test/task/git_credential_env_test.dart#askpass files are written to the owner-only git-askpass directory and never under projects` – red at spec time

- **S09 [OC02] [runtime] Docker shows a masked subdirectory empty under a read-only bind**
  - **Proof**: `cmd: d=$(mktemp -d) && mkdir -p "$d/secret" && echo s > "$d/secret/token" && docker run --rm --network none --read-only -v "$d:/project:ro" -v /project/secret dartclaw-agent:latest sh -c 'test -d /project/secret && test -z "$(ls -A /project/secret)"'; rc=$?; rm -rf "$d"; exit $rc` – exit 0. It passed at authoring time (2026-11-19); the `--rm` removes the anonymous volume


## Structural Criteria

- **SC01** One authority writes operator-chosen read-only mounts. `SecurityProfile.workspace` has no `projectDir` parameter and writes only DartClaw-owned mounts (`/workspace`, `/projects`, the package cache). `security_wiring.dart` gets every `/project` and `/projects/<id>` spec from the rule and writes no `:ro` spec itself.
- **SC02** No reference to the old askpass location remains outside the changelog: no `projects/.git-askpass` path in code, tests, scripts or docs.
- **SC03** The docs state the rule. `security-architecture.md`'s flag listing and profile table show the skip and mask, the flag listing also shows the `SecurityProfile.packageCachePath` volume, its askpass paragraph and `task-execution-architecture.md`'s credential paragraph name `<data_dir>/git-askpass/`, the guide's container section says the data directory is never mounted, `CHANGELOG.md` 0.28.1 has the `### Fixed` entry and the `### Removed` SDK line, and `packages/dartclaw_runtime/CLAUDE.md` names the rule where it describes the `/project` mount.


## Scope & Boundaries

### Work Areas

- `packages/dartclaw_runtime/lib/src/container/`: a new rule file beside `security_profile.dart`, kept out of the barrel; `security_profile.dart` (`workspace` loses `projectDir`); `container_manager.dart` for mask-aware translation.
- `packages/dartclaw_runtime/lib/src/runtime/security_wiring.dart`: owner and execution-directory mounts, working directory, INFO lines, and the test seam.
- `packages/dartclaw_runtime/lib/src/task/git_credential_env.dart`.
- Tests: new `test/container/data_dir_mount_rule_test.dart`, `test/container/container_manager_data_dir_mask_test.dart` and `test/runtime/security_wiring_data_dir_mount_test.dart`; edits to `test/task/git_credential_env_test.dart`. The `SecurityProfile.workspace(projectDir:)` callers migrate: `test/container/security_profile_test.dart` (its `/project` cases move to the rule's test or go), `test/container/container_manager_test.dart` (~228, ~266, ~270), `test/integration/container_provider_parity_integration_test.dart` (~153), `test/integration/agent_workspace_execution_integration_test.dart` (~494) and `test/integration/registry_bridge_integration_test.dart` (~140).
- `dev/testing/profiles/workflows/run.sh` (lines 74-75).
- `CHANGELOG.md`, `dev/architecture/security-architecture.md`, `dev/architecture/task-execution-architecture.md`, `docs/guide/security.md`, `packages/dartclaw_runtime/CLAUDE.md`.

### What We're NOT Doing

- Changing `service install`'s `WorkingDirectory` (launchd `macos_launchd_backend_support.dart:46`, systemd `service_backend.dart:493`). The mount rule and the runtime-directory substitution make it harmless. Listed as NOTICED BUT NOT TOUCHING.
- Recreating or migrating running containers. They keep their mounts until `serve` restarts, and the changelog says so.
- Deleting stale `.git-askpass-*` files a crashed `serve` left in `<data_dir>/projects/`. The changelog tells operators to delete them, because a startup sweep would be new machinery for a one-time leftover.
- Masking anything other than the data directory, such as a home directory's `~/.ssh` when `serve` runs from `$HOME`. The data directory is the one set of files DartClaw owns and knows the location of.
- Using a tmpfs mask instead of an anonymous volume. D1 is settled.
- Supporting a data directory at `<repo>/.dartclaw` in the local-repository posture, whose task worktrees live at `<runtimeCwd>/.dartclaw/worktrees` (`task_wiring.dart`) and would be refused at `/project`. It fails closed, and the default data directory `~/.dartclaw` cannot hit it. Listed as NOTICED BUT NOT TOUCHING.


## Architecture Decision

**Approach**: One rule function in `lib/src/container/`, not exported from the barrel. `SecurityProfile.workspace` loses its `projectDir` parameter, so it writes only DartClaw-owned mounts and the rule is the only writer of operator-chosen ones. Removing the parameter is a breaking change to the barrel-exported SDK, recorded under the changelog's `### Removed`; routing it through the rule instead would need the data directory and the owned roots on a profile factory that cannot log. The rule takes a host source, a container target, the data directory, and the DartClaw-owned exposed roots (`config.workspaceDir`, `config.projectsClonesDir`), and answers the `-v` specs plus an optional reason. `SecurityWiring` computes the owner's operator mounts once per instance and logs each reason at INFO: `runtimeCwd` → `/project`, and each `localPath` → `/projects/<id>`. It computes a named agent's `executionDir` → `/project` per acquisition and logs a reason there too. `buildManager` sets the working directory from the specs it actually emitted. Askpass files move to `<data_dir>/git-askpass/`.
**Why this over the floor**: The floor is a skip inside `SecurityProfile.workspace(projectDir:)`. It covers neither the mask (a second spec), nor `localPath` and `executionDir`, nor the reason D2 logs. Three call sites with one rule need one owner (ADR-054, one authority per concern).


## Constraints & Gotchas

- **Settled design, not reopened.** D1 is the one mount rule. Compare normalized absolute paths with symlinks resolved where the path exists: equal or inside → no mount; contains → bind plus a bare-path anonymous volume at `<target>/<relative data dir>`; otherwise unchanged. DartClaw-owned mounts (`/workspace`, the `/projects` clones root, generated state, bridge, artifacts) bypass it. D2 is one INFO line per skipped or masked source, not a warning. D3 moves askpass files to `<data_dir>/git-askpass/` (0700), which no profile mounts. D4: the data directory is `SecurityWiring._dataDir`, and credentials always live at `DartclawConfig.credentialsDirFor(dataDir)`.
- **Owned roots are exempt from "inside".** A source equal to or inside `config.workspaceDir` or `config.projectsClonesDir` mounts unchanged (scenario S05), checked before the data-directory comparison. A named agent's `executionDir` is a clone at `<data_dir>/projects/<id>` (`container_provider_parity_integration_test.dart`'s `authorizedProject`) or, outside the local-repository posture, a task worktree under `<data_dir>/workspace/.dartclaw/worktrees/` (`task_wiring.dart`'s `worktreesDir`), and both must keep their `/project` mount. The workspace directory this authority mounts at `/workspace` is an owned root too: a named agent with no requested directory runs in its own `<data_dir>/agents/<id>/workspace` (`turn_manager.dart` `directory ?? reservation.workspace?.directory`), so `buildManager` passes its `workspaceDir` argument to the rule beside the two config roots, and that source mounts at `/project` unchanged with no INFO line. All three roots are already container-visible, and after D3 none holds a credential.
- **A missing `/project` breaks `docker exec -w /project`.** Observed 2026-11-19: `chdir to cwd ("/project") set in config.json failed: no such file or directory`, exit 127. Both harnesses fall back to `ContainerExecutor.workingDir` when their default cwd does not translate (`claude_code_harness.dart#_resolveWorkingDirectory`, `codex_harness.dart#_resolveDefaultWorkingDirectory`), and `ContainerManager.workingDir` defaults to `/project`. So `buildManager` picks `/project` only when it emitted a `/project` spec, then `/workspace` when it mounted one, then `/tmp`.
- **Mask volumes are already cleaned up.** `SecurityProfile.packageCachePath` made bare-path anonymous volumes part of every `workspace` container, and every removal (`reclaimOwnedContainers`, `start`'s stale removal, `stop`) already runs `rm -f -v`. The volatile path uses `run --rm`. The masks need no removal change.
- **Masks are invisible to `ContainerManager`'s translation.** `_validateLocalPathProjectMounts`, `_hasContainerMountTarget` and `containerPathForHostPath` all `split(':')` and skip specs with fewer than two parts. That is correct for the package cache, which has no host source. It is wrong for a mask: without S07, a data-directory path that no deliberate mount covers translates through the `/project` bind into the empty mask instead of being refused. Translation answers `null` when its result lands at or under a bare-path target. `/var/cache/dartclaw` never matches, because no bind targets above it.
- **Canonical forms for comparison, caller spelling for the bind.** Use `canonicalizePathWithExistingAncestors` (`dartclaw_kernel`), as `container_manager.dart` does. macOS temp dirs resolve `/var` → `/private/var`, so tests that build symlinks or compare paths must canonicalize. Compute the mask's relative path from canonical forms, and keep the bind source as given so the unchanged case is byte-identical to today's spec.
- **No Docker in the unit lane.** `_wireContainers` returns before any template exists without a runtime, image and bridge binary. The composition `buildManager` uses must therefore be reachable on an unwired `SecurityWiring` through one `@visibleForTesting` member that answers the mounts and working directory for (`workspaceDir`, `executionDir`, `useOwnerWorkspace`). `buildManager` calls the same member, so the test exercises the production path.
- **Test defaults shift.** `wireTestSecurity` (`test/runtime/harness_wiring_fixture.dart`) defaults `runtimeCwd` to `dataDir`. Every composition through it now has no `/project`, and its working directory becomes `/workspace`. The parity suite passes `checkoutRoot`, which is unrelated to the data directory, so it is unaffected. Run the whole package suite, and fix any test that relied on the data directory appearing at `/project` by giving it an unrelated `runtimeCwd`, never by weakening an assertion.
- **The askpass files outlive one git operation.** `ProjectServiceImpl` and `RemotePushService` delete theirs only at `dispose()`, so the token sat in `/projects` for the whole `serve` lifetime after a fetch or push, while the workflow git port deletes its own per operation. Keep the file names (`.git-askpass-<ref>`, `.key`, `.token`) and change only the directory. Create it with `chmodOwnerOnlyDirSync` (`dartclaw_core`, as `named_credential_store.dart` does).
- **Two dartdocs go stale:** `security_wiring.dart:64` ("The repository mounted at `/project`") and `service_wiring.dart:561`. Correct both in the same edit; `/project` is now conditional.
- **An existing 0.28.1 `### Fixed` entry names `<data_dir>/projects/`** ("The git askpass helper files under …"). Correct it to the new directory in the same edit so the changelog does not contradict itself.
- **Fresh worktree.** Run `dart run dev/tools/embed_assets.dart` before `dart analyze`.


## Implementation Plan

### Implementation Tasks

- [x] **TI01** The mount rule exists in `lib/src/container/` as Architecture Decision and scenarios S03–S05 state, and Docker hides a masked subdirectory.
  - Follow `container_manager.dart#containerPathForHostPath` for canonical comparison with `p.equals` / `p.isWithin`.
  - **Verify**: `packages/dartclaw_runtime/test/container/data_dir_mount_rule_test.dart` – all three named tests pass, and the S03 and S04 tests fail when the rule is replaced by an unconditional `<source>:<target>:ro` (today's behavior); plus the S09 `cmd:` – exit 0.
  - **SATISFIES**: S03, S04, S05, S09

- [x] **TI02** `ContainerManager` refuses to translate a host path into a masked location.
  - **Verify**: `packages/dartclaw_runtime/test/container/container_manager_data_dir_mask_test.dart#a host path under a masked data directory does not translate` – red before the change, green after; the same test asserts that a mount list holding only the package-cache bare path translates exactly as before. Then `packages/dartclaw_runtime/test/container/container_manager_test.dart` – passes.
  - **SATISFIES**: S07

- [x] **TI03** `SecurityWiring` builds owner, `localPath` and named-agent `executionDir` mounts only through the rule. The owner set is computed once per instance and logs one INFO record per reason, and an `executionDir` reason logs at acquisition. The working directory follows the emitted specs. `SecurityProfile.workspace` has no `projectDir` parameter, and every caller listed under Work Areas is migrated.
  - Depends on TI01. The `@visibleForTesting` seam is per Constraints & Gotchas.
  - Migrate the test callers. A caller that passed `projectDir: null` drops the argument. A caller that passed a path either appends that literal `<path>:/project:ro` spec (in `ContainerManager` fixtures, which test the manager rather than the rule) or moves its case into `data_dir_mount_rule_test.dart` (in `security_profile_test.dart`).
  - **Verify**: `packages/dartclaw_runtime/test/runtime/security_wiring_data_dir_mount_test.dart` – the S01, S02 and S06 tests pass. Each asserts the full spec list, the working directory, and the log records (level `INFO`, logger `SecurityWiring`, source path in the message). S01 also asserts that no spec's source canonicalizes to the data directory or to a parent of it. `packages/dartclaw_runtime/test/container/security_profile_test.dart` – passes. Then `cmd: test -z "$(git grep -n -e 'projectDir' -- packages/dartclaw_runtime/lib/src/container/security_profile.dart)" && test -z "$(git grep -n -e 'projectDir:' -e ":ro'" -- packages/dartclaw_runtime/lib/src/runtime/security_wiring.dart)"` – exit 0.
  - **SATISFIES**: S01, S02, S06, SC01

- [x] **TI04** Askpass helper files are written under the owner-only `<data_dir>/git-askpass/`, and the workflows profile reads its token fallback from there.
  - The existing permission and prompt-matching tests in `git_credential_env_test.dart` move to the new paths unchanged in intent.
  - **Verify**: `packages/dartclaw_runtime/test/task/git_credential_env_test.dart` – passes, including the S08 test, which checks the directory mode with `statSync().mode` like the file's existing `modeOf` (the file is `@TestOn('posix')`). Then `cmd: bash -n dev/testing/profiles/workflows/run.sh && git grep -q 'git-askpass/.git-askpass-github-main.token' -- dev/testing/profiles/workflows/run.sh` – exit 0, and `cmd: test -z "$(git grep -n -e 'projects/.git-askpass' -e "'projects', '.git-askpass" -- . ':!CHANGELOG.md' ':!dev/bundle')"` – exit 0.
  - **SATISFIES**: S08, SC02

- [x] **TI05** The docs state the rule and the move. Concretely:
  - **`CHANGELOG.md` 0.28.1 `### Fixed`.** One entry says what was exposed: under a service install, every workspace container could read the data directory at `/project` (credential store, `gateway_token`, logs, sessions), and a project's git token sat under `/projects` while `serve` ran. It says to whom: any agent or command in a workspace container. It says what changes: the data directory is never mounted, a project directory containing it shows it empty, and git credential helpers move to `<data_dir>/git-askpass/`. It tells operators to restart the service and to delete leftover `<data_dir>/projects/.git-askpass-*` files. The existing askpass entry (line ~60) names the new directory. Add one `### Removed` SDK line: `SecurityProfile.workspace` no longer takes `projectDir`.
  - **`security-architecture.md`.** The flag listing (`-v <project>:/project:ro` line, ~278), the profile table's `workspace` row (~299) and the named-agent paragraph's "admitted execution directory at `/project`" (~324) show the skip and the mask. The flag listing also gains the `workspace` profile's `-v /var/cache/dartclaw` package-cache volume (ADR-062), which it omits today. The askpass paragraph (~427, § Git Credentials) names the new directory and drops "Protect the data directory accordingly" in favor of the mount fact.
  - **`task-execution-architecture.md`.** The credentials paragraph's "reads the token from a file under `<dataDir>/projects/`" (~237) names the new directory.
  - **`docs/guide/security.md`.** The "Mount allowlist for workspace files" bullet in § Container Isolation (~349), and the **Containers** paragraph of § Who Protects What (~68), say that the data directory is never mounted.
  - **`packages/dartclaw_runtime/CLAUDE.md`.** The `runtimeCwd` bullet's "`SecurityWiring` (the container `/project` mount)" (~85) names the rule and its file.
  - No story ID in any of them.
  - **Verify**: `cmd: b=$(git merge-base HEAD feat/0.28.1); for f in CHANGELOG.md dev/architecture/security-architecture.md dev/architecture/task-execution-architecture.md; do git diff -U0 "$b" -- "$f" | grep '^+' | grep -q 'git-askpass/' || exit 1; done; git diff -U0 "$b" -- dev/architecture/security-architecture.md | grep '^+' | grep -q '/var/cache/dartclaw' && git diff -U0 "$b" -- docs/guide/security.md | grep '^+' | grep -qi 'data directory' && git diff -U0 "$b" -- CHANGELOG.md | grep '^+' | grep -qi 'restart' && git diff -U0 "$b" -- CHANGELOG.md | grep '^+' | grep -q 'projectDir'` – exit 0. Each phrase is checked on added lines only, because the files already contain them; `cmd: test -z "$(git grep -n -e 'helper file in .<data_dir>/projects/' -e 'file under .<dataDir>/projects/' -e 'files under .<data_dir>/projects/. that hold' -- dev/architecture CHANGELOG.md)"` – exit 0, the old askpass location is gone from both architecture docs and the existing changelog entry; `cmd: test -z "$(git diff -U0 "$(git merge-base HEAD feat/0.28.1)" -- CHANGELOG.md docs dev/architecture packages dev/testing | grep '^+' | grep -w 'S11')"` – exit 0, no added line names the story (the changelog's history already holds unrelated `S11` mentions, so the check is diff-scoped); `inspect: CHANGELOG.md` – the 0.28.1 `### Fixed` entry reads as user-facing prose covering exposure, audience, change and restart.
  - **SATISFIES**: SC02, SC03


## Final Validation Checklist

- `cmd: dart format --line-length=120 --output=none --set-exit-if-changed packages/dartclaw_runtime`. Run it alone and read its exit code.
- `cmd: dart run dev/tools/embed_assets.dart && dart analyze packages/dartclaw_runtime` – `No issues found!`
- `cmd: dart test --reporter=failures-only packages/dartclaw_runtime` – exit 0 with a positive pass count; any test that depended on the data directory at `/project` is fixed per Constraints & Gotchas.


## Implementation Observations

Executed 2026-11-19 (CET) in the worktree `.claude/worktrees/container-data-dir-mount`. Status: **done**. Every task
is implemented and verified; nothing committed.

### Chain Attestation

- **OC01**: proven by S01, S03, S05 and S06 through TI01 and TI03. With `runtimeCwd` equal to the data directory the
  owner's plan has no `/project`, works in `/workspace`, and logs one INFO line; DartClaw-owned roots mount unchanged.
- **OC02**: proven by S02, S04, S06, S07 and S09 through TI01–TI03. A containing source gets the bind plus a bare-path
  mask, translation refuses a path under the mask, and Docker shows the masked directory empty.
- **OC03**: proven by S08 through TI04. Askpass files are written to `<data_dir>/git-askpass/` (0700) and nothing is
  written under `<data_dir>/projects/`.
- **OC04**: TI05. The changelog `### Fixed` entry (exposure, audience, change, restart, leftover files) and the
  `### Removed` SDK line, the architecture docs, the guide and the package `CLAUDE.md` state the rule.

### Proof lines

Red runs were taken before any production edit; the new rule and seam did not exist, so S01–S06 failed to compile.

- S01, S02, S06: red `security_wiring_data_dir_mount_test.dart` → "The method 'workspaceMountPlan' isn't defined for
  the type 'SecurityWiring'", `+0 -1: Some tests failed.` Green: part of the 207-test container + wiring run below.
- S03, S04, S05: red `data_dir_mount_rule_test.dart` → "Error when reading '…/data_dir_mount_rule.dart': No such file
  or directory", `+0 -1`. Green → `+3: All tests passed!`. Mutant (rule returns the unconditional
  `<source>:<target>:ro`) → S03 and S04 `[E]`, S05 passes, `+1 -2`; restored.
- S07: red `container_manager_data_dir_mask_test.dart` → `Expected: null Actual:
  '/project/.dartclaw-example/credentials'`, `+0 -1`. Green with `container_manager_test.dart` → `+50: All tests
  passed!`.
- S08: red `git_credential_env_test.dart --plain-name "askpass files are written to the owner-only git-askpass
  directory and never under projects"` → `+0 -1`; the two moved permission tests were red on the old path too. Green
  → `+17: All tests passed!`.
- S09: the `cmd:` → `exit=0`. Negative control without `-v /project/secret` → `exit=1`. `--rm` removed the volume;
  `docker ps -a` and `docker volume ls` matched their pre-run lists after every Docker check.
- TI03: `test/container` + `security_wiring_data_dir_mount_test.dart` → `+207 ~1: All other tests passed!`; the
  `projectDir` / `:ro'` grep → exit 0.
- TI04: `bash -n` + `git grep -q 'git-askpass/.git-askpass-github-main.token'` → exit 0; old-location grep → exit 0.
- TI05: the four doc `cmd:` checks → exit 0 each.
- Final Validation: `dart format … --set-exit-if-changed packages/dartclaw_runtime` → `0 changed`, exit 0;
  `embed_assets && dart analyze packages/dartclaw_runtime` → `No issues found!`; `dart test --reporter=failures-only
  packages/dartclaw_runtime` → exit 0, `+5904 ~25: All other tests passed!`.
- Opt-in Docker suites touched by the caller migration (`--run-skipped -t integration`
  `container_provider_parity`, `agent_workspace_execution`, `registry_bridge`) → `+25 -1`. The one failure,
  `production harness and turn admission use the pinned workspace while a project changes only cwd` (`Actual: 'AGENT A
  SOUL\n'`, a behavior-prompt assertion), fails identically on an unmodified worktree at 4bf36cccd (`+3 -1`), so it is
  pre-existing and unrelated to mounts.

### Drift Notes

- The seam is `SecurityWiring.workspaceMountPlan({workspaceDir, executionDir, useOwnerWorkspace})`, returning
  `({List<String> mounts, String workingDir})`; the rule is `operatorMount` in `container/data_dir_mount_rule.dart`.
- Operator-chosen specs follow the profile's DartClaw-owned specs (`/workspace`, `/projects`, package cache, then
  `/project` and its mask, then local-path projects). Docker orders mounts by destination, and S09 proves the mask
  holds under a read-only bind.
- The owner set is composed lazily on first use, so its INFO lines appear at the first workspace authority rather than
  at `wire()`; it is still composed once per instance.
- No existing test relied on the data directory appearing at `/project`: the package suite passed unchanged after the
  `wireTestSecurity` default (`runtimeCwd` = `dataDir`) lost its `/project`.
- `containerPathForHostPath` refuses any translation landing at or under a bare-path volume, as Constraints state; a
  bind targeted beneath a mask would be refused too, which no current profile produces.

### Review follow-up (2026-11-19 21:16 CET)

- **Runtime directory inside the data directory.** Skipping `/project` left `runtimeCwd` itself pointing at the data
  directory under a service install, and it also feeds `TaskExecutor`'s standalone directory, the `_local` project, the
  harness cwd, behavior files and diff generation, so a task with no project or a `_local` turn failed "Requested
  working directory is not mounted in the container". `DartclawRuntime`'s constructor now resolves a runtime directory
  equal to or inside the data directory (canonical comparison, as the rule) to `config.workspaceDir` and logs one INFO
  line; one that contains the data directory is unchanged. Under a service install the runtime directory is therefore
  the workspace, which `SecurityWiring` no longer binds a second time at `/project`, so the owner container works in
  `/workspace` (proof: `security_wiring_data_dir_mount_test.dart` `a runtime directory equal to the workspace is not
  mounted a second time at /project`, red with the extra `/project:ro` spec, green after). This replaces the earlier Scope
  item that left `_local` at the data directory. Proof: `headless_runtime_test.dart` group `a runtime directory and the
  data directory` — the equal and inside cases red without the substitution (`Actual:` the data directory and
  `<data>/logs/nested`), all three green with it. Four fixtures that seeded their runtime repository inside the data
  directory now place it outside (`HeadlessRuntimeFixture.reposDir`, `headless_file_storage_test.dart`,
  `service_wiring_local_path_bootstrap_test.dart`, `dartclaw_workflow`'s `e2e_fixture.dart`).
- **API local-path projects.** `ProjectMutationService` decided container reachability by mount-root containment only,
  so a `localPath` inside the data directory under a mounted root was accepted and its turns failed later. It now also
  asks `operatorMount` (data dir plus `workspaceDir`/`projectsClonesDir` as owned roots, wired from `server.dart`) and
  refuses with `LOCAL_PATH_NOT_MOUNTABLE` when the rule emits no spec. Proof: `project_routes_test.dart` group
  `container mode with the data directory inside a mounted root` — the refusal case red without the check (`Expected:
  <400> Actual: <201>`), both green with it; `server_test.dart` `container-mode local-path registration is judged
  against the _local directory` now puts the core data directory inside the runtime root and asserts the refusal, red
  (`Expected: <400> Actual: <201>`) with the `dataDir` wiring removed from `server.dart`.

### NOTICED BUT NOT TOUCHING

- `service install`'s `WorkingDirectory` is still the data directory (Scope); the mount rule and the runtime-directory
  substitution make it harmless.
- A data directory at `<repo>/.dartclaw` in the local-repository posture fails closed (Scope).

