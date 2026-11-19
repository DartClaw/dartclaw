**Plan**: dev/bundle/docs/specs/0.28.1/fis/plan.json
**Story-ID**: S01

## Feature Overview and Goal

**Intent**: A containerized agent must not be able to choose what host-side Git executes. Today host Git working in an agent worktree follows that worktree's agent-writable `.git` gitlink, so the agent can substitute a gitdir whose config names clean filters, `gpg.program` or diff drivers that then run on the host.

**Expected Outcomes**:

- [OC01] Host Git against an agent worktree uses the gitdir DartClaw recorded when it created the worktree, never the one the worktree's `.git` file names, and never runs the config of a repository nested inside the worktree.
- [OC02] A worktree whose gitlink was rewritten, replaced or removed is refused with an error naming the worktree, before any Git operation on it runs.
- [OC03] Ordinary promotion, publish, task accept and diff behavior is unchanged for an untampered worktree.

## Required Context

- `dev/bundle/docs/specs/0.28.1/0.28.1-andthen-mixed-review-claude-2026-11-18.md#finding-13---critical---a-containerized-agent-can-make-host-git-run-executables-it-chooses-by-rewriting-its-worktree-gitlink` – the defect, the reproduction and the call sites found so far.
- `dev/architecture/security-architecture.md#task-security` – the boundary claim this story corrects.

## Acceptance Scenarios

- **S01 [OC01,OC03] Promotion and publish of an untampered worktree still sweep, commit and deliver**
  - **Given** a workflow story worktree DartClaw created, with uncommitted agent changes
  - **When** the host sweeps it for promotion or publish
  - **Then** the changes are committed on the story branch and delivered exactly as before this change
  - **Proof**: `packages/dartclaw_runtime/test/task/workflow_git_support_test.dart` – green – parity/regression

- **S02 [OC01,OC02] [runtime] A workflow sweep refuses a worktree whose gitlink points at an agent-built gitdir**
  - **Given** a real-Git project and a DartClaw-created worktree whose `.git` file was rewritten to `gitdir: .evil`, where `.evil` holds a config with a clean filter that writes a marker file outside the worktree, an `info/attributes` selecting it for every path, and an `info/exclude` hiding `.evil`
  - **When** the host runs the workflow sweep (status, stage, commit) on that worktree
  - **Then** the sweep fails with an error naming the worktree as tampered, the marker file does not exist, and the story branch and the project's index are unchanged

- **S03 [OC01,OC02] [runtime] The execution-surface candidate preview refuses the same tampered worktree**
  - **Given** the tampered worktree of scenario S02
  - **When** promotion or publish computes the execution-surface candidate
  - **Then** no candidate is produced, the run step fails with the tampered-worktree error, and the marker file does not exist

- **S04 [OC01,OC02] [runtime] Task accept refuses a tampered task worktree**
  - **Given** a task in `review` whose worktree gitlink was rewritten as in scenario S02
  - **When** a person accepts the task, or automatic accept (`auto_accept`, an agent's `task_review` accept) runs its execution-surface check on it
  - **Then** the accept fails with the tampered-worktree error, the task stays in `review`, and the marker file does not exist

- **S05 [OC01,OC02] [runtime] Review diff generation refuses a tampered worktree**
  - **Given** a task worktree rewritten as in scenario S02, with `.evil/config` also naming a `diff.external` command that writes a second marker
  - **When** the review diff is generated for the task (structured and unified)
  - **Then** diff generation fails with the tampered-worktree error and neither marker exists

- **S06 [OC01,OC02] [runtime] Merge and reset through the workflow Git port refuse a tampered worktree and keep their repo lock key**
  - **Given** a tampered worktree as in scenario S02
  - **When** the workflow Git port is asked to stage and commit step artifacts in (the workflow artifact commit), merge into, reset or inspect that worktree
  - **Then** the operation fails with the tampered-worktree error, the marker does not exist, and the repo-lock key for the worktree is the project's real common dir, not one the gitlink names

- **S07 [OC02] [runtime] A replaced or missing gitlink is refused, not repaired**
  - **Given** a DartClaw-created worktree whose `.git` was replaced by a directory (for example after an agent ran `git init`), or by a symlink, or deleted
  - **When** any host operation of scenarios S02–S06 and S08 runs on it
  - **Then** it fails with the tampered-worktree error, and nothing is committed into the agent-created repository

- **S08 [OC01,OC02] [runtime] The read-only task mutation check refuses a tampered worktree**
  - **Given** a read-only task running in a DartClaw-created worktree whose gitlink was rewritten as in scenario S02, with `.evil/config` also setting `core.fsmonitor` to a command that writes the marker
  - **When** the host takes the read-only baseline or the post-turn mutation snapshot
  - **Then** the task fails with the tampered-worktree error (not a skipped check) and the marker does not exist

- **S09 [OC01] [runtime] A repository nested in an untampered worktree cannot run its filters on the host**
  - **Given** an untampered DartClaw-created worktree containing `sub/.git`, an agent-built repository whose config names a clean filter and a `diff.external` command that write a marker, with `sub` already recorded in the story branch's index as a gitlink
  - **When** the host runs the operations of scenarios S02, S04, S05 and S08 on that worktree
  - **Then** each operation completes (or refuses) without the marker existing

## Structural Criteria

- **SC01** Every host Git invocation whose working tree is an agent worktree goes through the one authority in `packages/dartclaw_runtime/lib/src/task/host_worktree_git.dart`, which supplies `--git-dir` and `--work-tree` from host-owned state; no call site runs Git with an agent worktree as its working directory without it.
- **SC02** The authority derives the worktree's admin directory from the project's common dir (`<common>/worktrees/<id>`, matched by that record's `gitdir` path against the worktree path DartClaw holds), never by running Git inside the worktree or by reading the target of the worktree's `.git` file.
- **SC03** `dev/architecture/security-architecture.md` (the Agent-written files row and § Task Security) and `docs/guide/security.md`, where it describes the host sweep, state what host Git in agent worktrees neutralizes: the agent-writable gitlink, hooks and fsmonitor; operator-defined filters selected by a worktree `.gitattributes` remain operator trust.

## Scope & Boundaries

### Work Areas
- `packages/dartclaw_runtime/lib/src/task/host_worktree_git.dart` – the authority.
- `packages/dartclaw_runtime/lib/src/runtime/workflow_git_support.dart` – sweep, merge abort/reset/clean, revision and status reads in worktrees.
- `packages/dartclaw_runtime/lib/src/runtime/workflow_git_candidate.dart` – candidate preview.
- `packages/dartclaw_runtime/lib/src/task/workflow_git_port_process.dart` – worktree operations and `_gitCommonDir` lock key. Its worktree caller is `packages/dartclaw_workflow/lib/src/workflow/workflow_artifact_committer.dart` (add, cached diff, commit in the task worktree); `MergeExecutor` drives the same port against the project dir only.
- `packages/dartclaw_runtime/lib/src/task/task_review_service.dart` – accept sweep and publish diff check.
- `packages/dartclaw_runtime/lib/src/task/execution_surface.dart` – `executionSurfaceBaseRef` (plain `runGit` in the worktree) and `executionSurfacePaths` (constructs `DiffGenerator` with the worktree as its `projectDir`), reached from automatic accept.
- `packages/dartclaw_runtime/lib/src/task/task_read_only_guard.dart` – read-only baseline and mutation snapshot: plain `runGit` `status` in the task's execution directory, which is the worktree when the task has one (`task_executor_helpers.dart#_captureReadOnlyProjectStatus`).
- `packages/dartclaw_runtime/lib/src/task/diff_generator.dart` – structured, unified and untracked-file reads in worktrees.
- Docs per SC03; `CHANGELOG.md` 0.28.1 `### Fixed`; `packages/dartclaw_runtime/CLAUDE.md` if its Workflow Git approval or Task runtime bullets name the hardening.

### What We're NOT Doing
- Mounting the gitlink read-only in the container – the owner chose host-side resolution; a mount change is a separate decision.
- The channel approval post truncation (review Finding 14) and the credentialed push URL (review Finding 15) – separate findings.
- Git run in the project checkout itself (`workflow_worktree_binder.dart` inline mode, `worktree_manager.dart` create/remove/list, project fetch) – its `.git` is the host's own repository, not agent-writable through a worktree gitlink.
- Neutralizing operator-configured filters in the project's own config – operator trust (SC03).
- Bash workflow steps (`bash_step_runner.dart`) – they run the operator's declared command by design.
- Workspace Git sync (`workspace/workspace_git_sync.dart`), which runs host Git in `config.workspaceDir`, itself mounted `/workspace:rw` – the same class of hole outside the worktree-gitlink frame, tracked as its own finding.

## Architecture Decision

**Approach**: Extend `runHostWorktreeGit` into the single host-worktree authority: given the project dir and the worktree path as separate arguments, resolve the admin dir from `<common>/worktrees/*/gitdir`, verify the worktree's `.git` is a regular non-symlink file whose canonicalized target is that admin dir, and run Git with `--git-dir=<admin> --work-tree=<worktree>`, the existing hook/fsmonitor options, and options that stop Git descending into nested repositories (submodule recursion and submodule status/diff off; the exact keys are chosen by the S09 proof). A mismatch throws one typed tampered-worktree exception. `WorkflowGitPort` methods that act on a worktree take the project dir explicitly: this is a cross-package API change in `dartclaw_workflow` (owner decision), named in the story report, and every caller passes the project dir it already holds.
**Why this over the floor**: extending the existing `hostWorktreeGitOptions` with more `-c` overrides cannot work, because the agent's gitdir supplies config keys no fixed override list enumerates (Intent: the agent must not choose what host Git executes).

## Constraints & Gotchas

- **Constraint**: `--git-dir` set to a worktree admin dir relies on its `commondir` file to reach the shared repository; resolve the common dir by running Git in the **project** dir (`rev-parse --git-common-dir`), and keep `noSystemConfig` as today.
- **Constraint**: Several call sites use one helper for both the project dir and a worktree (for example `workflow_git_support.dart`'s project-dir `switch`/`fetch`). Only worktree invocations take the authority; the project-dir ones keep today's call, so the authority must take the worktree as a distinct argument rather than inferring it from the working directory.
- **Constraint**: The story runs on its own branch while another session edits `CHANGELOG.md` and `dev/architecture/security-architecture.md` in the shared checkout. Keep this story's edits to those files to the lines SC03 and the `### Fixed` entry need, so the branch lands with small conflicts.
- **Gotcha**: Git writes both the gitlink and the admin record's `gitdir` as canonical real paths (macOS: `/private/var/...` where Dart's `Directory.systemTemp` yields `/var/...`), and with `worktree.useRelativePaths` it writes them relative (`gitdir: ../p/.git/worktrees/w`, admin `gitdir` `../../../../w/.git`; checked on Git 2.53). Compare both sides after resolving relative to their own file and canonicalizing, never as literal strings, or every legitimate worktree is refused.
- **Constraint**: `DiffGenerator`, `TaskReviewService`, `TaskReadOnlyGuard` and `execution_surface.dart` take an injectable `GitRunner` that existing tests rely on. The authority composes over that seam (it builds the arguments and verifies the gitlink, then calls the injected runner); do not add a second runner type.
- **Gotcha**: Tests must build the tampered gitdir with real Git (`git init --bare`, then edit its `config`), set `core.bare = false`, and quote the filter command so it writes the marker into the test's temp dir. Use per-test temp dirs; never change `Directory.current`.

## Implementation Plan

### Implementation Tasks

- **TI01** `host_worktree_git.dart` exposes the host-worktree authority: resolution of the admin dir per SC02, gitlink verification per OC02, the typed tampered-worktree exception, and invocation with explicit `--git-dir`/`--work-tree`.
  - Add the shared real-Git tamper fixture (project, worktree, the S02 gitdir, the S07 variants) under `packages/dartclaw_runtime/test/task/`, reused by TI02–TI05 and TI08.
  - **Verify**: `packages/dartclaw_runtime/test/task/host_worktree_git_test.dart` – an untampered worktree runs `status` and reports its changes; a worktree with the S09 nested repository runs `status`, `add -A` and `diff` without the marker; each S02/S07 tamper variant throws the tampered-worktree exception before any Git process runs against the worktree (the project-dir `rev-parse --git-common-dir` may run), with no marker; the resolved admin dir equals the record under the project's common dir.
  - **SATISFIES**: S07, S09, SC02

- **TI02** The workflow sweep, merge abort/reset/clean, revision and status reads in `workflow_git_support.dart`, and the candidate preview in `workflow_git_candidate.dart`, run worktree Git only through the authority.
  - **Verify**: `packages/dartclaw_runtime/test/task/workflow_git_support_test.dart` – new tamper cases for the sweep and the candidate preview assert the exception, no marker, branch tip and project index unchanged; existing promotion and publish cases stay green.
  - **SATISFIES**: S01, S02, S03, SC01

- **TI03** `WorkflowGitPortProcess` runs worktree operations through the authority with the project dir its caller passes, and its repo-lock key is the project's common dir resolved without running Git in the worktree. `workflow_artifact_committer.dart` passes the project dir, and its `_isGitWorktree` fallback no longer retargets the commit to the project dir when the worktree `.git` is missing: that case refuses per scenario S07.
  - **Verify**: `packages/dartclaw_runtime/test/task/workflow_git_port_process_test.dart` – tamper cases assert add/commit, merge and reset on the worktree fail with the exception and no marker; a lock-key assertion shows the tampered worktree keys on the real common dir; `packages/dartclaw_workflow/test/workflow/workflow_artifact_committer_test.dart` covers the deleted-gitlink refusal; `packages/dartclaw_runtime/test/task/merge_executor_test.dart` (project-dir use of the port) stays green.
  - **SATISFIES**: S06, SC01

- **TI04** `TaskReviewService` accept runs its worktree status, stage, commit and publish-diff check, and the automatic-accept execution-surface check in `execution_surface.dart`, through the authority.
  - **Verify**: `packages/dartclaw_runtime/test/task/task_review_service_test.dart` – tamper cases for a person's accept and for automatic accept assert the accept fails, the task stays `review`, no marker; existing accept cases green.
  - **SATISFIES**: S04, SC01

- **TI05** `DiffGenerator` runs its worktree reads (structured, unified, untracked) through the authority in both operator and automated modes.
  - **Verify**: `packages/dartclaw_runtime/test/task/diff_generator_test.dart` – a tamper case with the `diff.external` marker asserts the exception and neither marker; existing diff cases green.
  - **SATISFIES**: S05, SC01

- **TI06** No host Git call outside the authority uses an agent worktree as its working directory.
  - **Verify**: `inspect: packages/dartclaw_runtime/lib/src/task/host_worktree_git.dart:1` – list every `runGit`/`runHostWorktreeGit`/`_runGit` call in `packages/dartclaw_runtime/lib` whose working directory can be a worktree (`git grep -n "runGit\|runHostWorktreeGit\|_runGit\|_git(" -- packages/dartclaw_runtime/lib`), and confirm each goes through the authority or is a project-dir call excluded in *What We're NOT Doing*; record the list in `## Implementation Observations`.
  - **SATISFIES**: SC01

- **TI07** The security docs and the changelog state the hardening per SC03, and `packages/dartclaw_runtime/CLAUDE.md` names the authority where it describes host worktree Git.
  - **Verify**: `inspect: dev/architecture/security-architecture.md:557` – the sentence no longer claims hooks alone keep the boundary; it names the explicit gitdir and the tampered-worktree refusal, and states the operator-trust remainder per SC03. The Agent-written files row (`security-architecture.md:22`) and `docs/guide/security.md:308` say the same. `CHANGELOG.md` 0.28.1 `### Fixed` carries one entry for the refusal.
  - **SATISFIES**: SC03

- **TI08** `TaskReadOnlyGuard` runs its baseline and snapshot `status` through the authority when the execution directory is a task worktree, and a tampered-worktree error fails the task instead of skipping the check (`task_executor_helpers.dart#_captureReadOnlyProjectStatus`); a project-dir execution keeps today's call.
  - **Verify**: `packages/dartclaw_runtime/test/task/task_read_only_guard_test.dart` – a tamper case with the `core.fsmonitor` marker asserts the task fails with the tampered-worktree error and no marker; existing guard cases green.
  - **SATISFIES**: S08, SC01

## Final Validation Checklist

- Run `bash dev/testing/profiles/container/coding.sh` for one fixture and provider if a container runtime is available, confirming an untampered containerized coding run still promotes; record the result or the reason it could not run.

## Discovered Requirements

- `MergeExecutor` is not project-dir only: workflow promotion (`workflow_git_support.dart#_withIntegrationWorktree`) drives it in an existing or temporary integration worktree. It now takes `worktreePath` beside `projectDir`, so that merge also runs through the authority.
- An untracked nested repository is harmless until the sweep's `add -A` records it as a gitlink; every later host Git call in that worktree (the sweep's `write-tree`/`commit`) is then refused. An agent that clones a repository into its worktree now fails the sweep with the tampered-worktree error instead of committing a gitlink.

## Implementation Observations

- **Nested repositories (S09), probed on Git 2.53.0** (`.agent_temp` probe, removed): with `sub` recorded as a gitlink and `sub/.git` armed with a clean filter, `diff.external` and `core.fsmonitor`, host `status`, `diff`, `add -A` and `commit` with explicit `--git-dir`/`--work-tree` ran the nested clean filter, because Git's submodule dirty check runs `git status` inside a populated gitlink. `-c diff.ignoreSubmodules=all` is overridden by a `.gitmodules` entry with `ignore = none`, `add -A` performs the check whatever the config says, and `core.bare`/`core.worktree` overrides change nothing. An untracked nested repository (never recorded as a gitlink) ran nothing.
- **TI06 call-site list** (`git grep -n "runGit\|runHostWorktreeGit\|_runGit\|_git(" -- packages/dartclaw_runtime/lib`). Through the authority with a worktree: `workflow_git_support.dart` sweep (`status`, `add -A`, `write-tree`, `commit`), cleanup (`merge --abort`, `reset --hard`, `clean -fd`), retry-capture `status`; `workflow_git_candidate.dart#_readGit` (preview `rev-parse --git-path index`, `--shared-index-path`, `add -A`, `write-tree`); `workflow_git_port_process.dart#_git` (every port method, including `MergeExecutor`'s integration-worktree merge); `task_review_service.dart#_git` (status, add, commit, publish diff); `diff_generator.dart#_git` (numstat, raw, unified, untracked); `execution_surface.dart#executionSurfacePaths` (through `DiffGenerator`); `task_read_only_guard.dart#snapshot` when `projectDir` is set. Project-dir calls, excluded by *What We're NOT Doing*: `workflow_git_support.dart` lines 59, 74, 98, 102, 120 (`runWorkflowGitCommand`, whose callers pass project dirs), 133 (`workflowLocalRefExists`, project `localPath`), 163, 167, 324, 356 (`rev-parse` of a branch, run in the project since refs are repo-wide), 525/541 (`worktree add`/`remove`), 584 (push), 732 (fetch), 736 (`worktree list`); `service_wiring_workflow_git.dart:75` (fetch); `execution_surface.dart:43` (`executionSurfaceBaseRef`, now `projectDir`); `remote_push_service.dart` (project `localPath`); `project_service_impl.dart`; `workflow_local_path_preflight.dart` (project `localPath`); `workflow_worktree_binder.dart` 163/195/219 (inline mode, project checkout); `worktree_manager.dart` (create/remove/list/prune in the project); `workspace/workspace_git_sync.dart` (out of scope, own finding); `task_read_only_guard.dart:58` (project-dir execution).
- **Held worktree path (review fix round).** The first version resolved the held worktree path, and the record's `gitdir` target, through the filesystem. An agent that moved its worktree away and left a symlink to the project checkout at that path therefore had host Git (`status`, the sweep's `add -A`, retry cleanup's `reset --hard`/`clean -fd`) run in the operator's checkout.
  - Now only the held path's parent, which is the host-owned worktrees root, is symlink-resolved. Its last component must be a real directory; a symlink is refused, even one to the genuine worktree.
  - The record's target and a relative gitlink are compared to that held path as normalized paths. A relative one is joined to its own file's canonical directory. Neither is ever followed into the worktree.
  - Git writes both as realpaths, so a host path through a symlinked parent (macOS `/var`) still resolves.
  - A symlinked worktrees root yields a held path that no record names, so it is refused too.
- Residual TOCTOU: the gitlink and nested-gitlink checks run before the command, so an agent writing `.git` between check and command could still redirect it. Closing it needs the gitlink mount read-only, which this story rules out.
- `TaskReviewService` resolves a local task's project dir from `WorktreeManager.projectDirFor(null)`, else `MergeExecutor.projectDir`; with neither, automatic accept fails closed with `ReviewActionFailed`.
- Tamper tests carry positive controls (`host_worktree_git_test.dart` "a tampered gitlink" group). For each armed tamper kind, plain `git` run in the worktree as its working directory fires the marker that the authority's refusal then keeps silent.
  - `.evil` is a bare clone of the project with an index of the worktree branch, so `diff.external` and `core.fsmonitor` really fire.
  - The deleted-gitlink case arms an enclosing repository, which plain Git climbs to.
  - A symlink to the genuine admin dir arms nothing and has no positive control; it is refused on the `.git` file type.
- The nested-gitlink `ls-files` check reads the index the caller's plan selects, so the candidate preview's scratch index (`GIT_INDEX_FILE`) is checked, not the worktree's own index.
- The artifact committer fails when the task's recorded worktree directory is gone, instead of committing in the project checkout.
- The artifact collector keeps swallowing diff errors (best-effort artifact), so a tampered worktree yields no `diff.json` and a logged warning there; S05 is proven at the `DiffGenerator` level.
- **Final validation, container check** (`coding.sh --provider claude --fixture dart`, run 2026-11-19): **failed**, and the failure is not caused by this story. Both tasks ran in the container and were accepted. The `spec` step's promotion then failed with `Workflow branch "dartclaw/workflow/<run>" changed after inspection.` The cause is how `implement-story` promotes: its source branch is the integration branch. `_promoteWorkflowBranchLocallyUnlocked` first sweeps the dirty worktree as the source, which commits it. It then sweeps the same branch again as the base, against the revision inspected before that commit, so `_sweepCandidateTree`'s revision check throws. A scratch test (promote a dirty linked worktree whose branch is `branch == integrationBranch`) gives the same error on this branch and on base `f4182b8eb`. The check comes from `cbafb21f2` (ADR-063 approval). No tampered-worktree refusal occurred in the run. The in-container agent's own `git` failed with `not a git repository` because the gitlink's host path is unreachable inside the container, which was already the case before this change.

#### DRIFT
- Nested repositories are neutralized by refusing any worktree whose index holds a gitlink with a populated `<path>/.git` (`ls-files --stage -z` plus a filesystem check), not by option keys: the probe above shows no option set stops the check.
- `executionSurfacePaths` drops `includeWorktree`; the worktree is included exactly when `worktreePath` is given, and `projectDir` is required.
- `resolveHostGitCommonDir` throws `WorktreeException`, not `StateError`, because `TaskReviewService` maps `StateError` to an invalid transition.
- TI02's tests live in `packages/dartclaw_runtime/test/runtime/workflow_git_support_test.dart`, where the suite already was, not `test/task/`.
- The `project-backed accept` cases in `task_review_service_test.dart` moved from exact-argument fake runners on fictitious paths to a real project and linked worktree, since the authority reads the worktree record from disk; the inherited-worktree read-only case in `task_executor_worktree_test.dart` uses a linked worktree instead of a clone.
