# Blocked-host fix hint and task branch cleanup

**Plan**: dev/bundle/docs/specs/0.28.1/plan.json
**Story-ID**: S04

## Feature Overview and Goal

**Intent**: A blocked network call tells the operator and the model which config key lifts the block, a cancelled task's work is pinned as surviving cleanup, and an accepted squash merge no longer leaves its task branch behind.

**Expected Outcomes**:

- [OC01] A host blocked by NetworkGuard comes with the config key that would allow it, so the agent's reply to the operator carries the fix.
- [OC02] Cancelling or cleaning up a task never loses its work: unmerged commits stay on `dartclaw/task-<taskId>`, uncommitted changes stay in the worktree, and the guide says where.
- [OC03] A task accepted with the squash strategy leaves no `dartclaw/task-<taskId>` branch behind once the merge succeeded.


## Required Context

Paths are relative to the public repo root (`../dartclaw-public/` from the private repo), where this FIS executes from its exported copy and where `cmd:` proofs run; `docs/specs/` and `docs/research/` paths name this plan's private sources, exported to `dev/bundle/docs/`.

- `docs/specs/0.28.1/prd.md#fr6-blocked-host-message-names-the-fix` – the message contract.
- `docs/specs/0.28.1/prd.md#fr7-saved-branches-on-cancel-and-cleanup` – FR7 closed on its verify-first clause, plus the squash-accept leftover.
- `docs/research/devvm-2026-11/research.md#v5--keep-unmerged-task-commits-on-cancel-p3-verify-first` – origin of FR7.
- `dev/architecture/task-execution-architecture.md#51-worktreemanager` – branch naming and cleanup semantics.
- `packages/dartclaw_runtime/lib/src/task/task_review_service.dart` (merge at ~:218, cleanup at ~:280) and `runtime/task_wiring.dart:144` (squash is the default strategy).


## Acceptance Scenarios

- **S01 [OC01] Block names the blocked agent's key**
  - **Given** NetworkGuard with the default allowlist and agent `search`, which has no `agent_overrides` entry
  - **When** that agent fetches `https://evil.example/page` through `web_fetch` or `shell`
  - **Then** the block reason still starts `Network blocked: domain not in allowlist (evil.example)` and ends with a hint naming `guards.network.agent_overrides.search.extra_domains`

- **S02 [OC01] Block with no agent id names the global key**
  - **Given** the same guard and a main-agent call (no agent id)
  - **When** it fetches `https://evil.example/page`
  - **Then** the hint names `guards.network.extra_allowed_domains`

- **S03 [OC01] A block no config key can lift names none**
  - **Given** the same guard
  - **When** a command targets a literal IP address, or matches an exfiltration pattern
  - **Then** the reason is unchanged from today

- **S04 [OC02] Cancel keeps unmerged commits**
  - **Given** a task with a clean worktree whose branch `dartclaw/task-<id>` holds a commit that is not on its base
  - **When** the task is cancelled (worktree cleanup runs)
  - **Then** the worktree directory is gone and `dartclaw/task-<id>` still holds that commit, because git refuses to delete an unmerged branch
  - **Proof**: `packages/dartclaw_runtime/test/task/worktree_manager_test.dart#cleanup keeps unmerged work` – green – parity/regression: real git, pins today's behavior

- **S05 [OC02] Cleanup keeps a dirty worktree**
  - **Given** a task worktree with uncommitted changes
  - **When** cleanup runs
  - **Then** the worktree directory, its changes and its branch survive, because git refuses to remove a dirty worktree
  - **Proof**: `packages/dartclaw_runtime/test/task/worktree_manager_test.dart#cleanup keeps unmerged work` – the same test, second worktree

- **S06 [OC03] Squash accept deletes the task branch**
  - **Given** a worktree task on `dartclaw/task-<id>` with a commit, strategy `squash` (the default), and a merge that succeeds
  - **When** the task is accepted
  - **Then** the base ref holds the squash commit and `dartclaw/task-<id>` no longer exists
  - **Proof**: `packages/dartclaw_runtime/test/task/task_review_service_test.dart#squash accept deletes the task branch` – red at spec time: real git, the branch survives today

- **S07 [OC03] Only a successful squash merge force-deletes, and only the task's own branch**
  - **Given** an accept whose merge conflicts, or whose strategy is `merge`, or a task attached to an existing branch such as `wf/integration`
  - **When** the accept runs
  - **Then** a conflicting accept keeps the branch and the task in `review`, a `merge` strategy deletes as today (non-force), and an attached branch is never deleted
  - **Proof**: `packages/dartclaw_runtime/test/task/worktree_manager_test.dart#forceDeleteBranch` – red at spec time for the force path: an owned-name branch is deleted, an `wf/integration`-style branch survives, the default path issues the same git commands as before; `packages/dartclaw_runtime/test/task/task_review_service_test.dart#squash accept deletes the task branch` – the conflict case keeps the branch


## Structural Criteria

- **SC01** `WorktreeManager.cleanup` without the force-delete option issues the same git commands as before, so cancel, reject, project deletion and every other caller are unaffected.


## Scope & Boundaries

### Work Areas
- `packages/dartclaw_kernel/lib/src/network_guard.dart` and its tests, plus the exact-string assertion in `packages/dartclaw_core/test/harness/codex_approval_flow_test.dart`.
- `packages/dartclaw_runtime/lib/src/task/worktree_manager.dart`, `worktree_cleanup.dart`, `task_review_service.dart` and their tests.
- Docs: `dev/architecture/control-protocol.md` (example reason), `docs/guide/projects-and-git.md`, `dev/architecture/task-execution-architecture.md` § 5.1, `CHANGELOG.md` § 0.28.1.

### What We're NOT Doing
- Renaming a cancelled task's branch, a separate branch namespace, collision handling, a task API field or any operator notice for it – verify-first shows cancel and cleanup already keep the work (FR7 closed on that evidence, owner decision).
- Changing the cancel, reject or project-delete cleanup commands: the non-force `git worktree remove` and `git branch --delete` are what keep unmerged work.
- Force-deleting on a `merge`-strategy accept (the non-force delete already succeeds after a true merge), on a project-backed accept (it pushes the branch and merges nothing locally), or on a conflicting accept.
- A config knob, a retention policy or an auto-prune for task branches – YAGNI at prototype stage.
- Bumping "Current through" markers, the Ubiquitous Language and figures – story S09 owns them.


## Architecture Decision

**Approach**: FR6: `NetworkGuard` appends a hint to the existing reason, chosen by `GuardContext.agentId`. FR7: no behavior change, one real-git test pins it. The squash-accept leftover: `WorktreeManager.cleanup` takes `forceDeleteBranch` (default false) that swaps `git branch --delete` for `git branch -D`, honored only for a branch DartClaw minted for the task (`dartclaw/task-<taskId>`); `cleanupWorktree` passes it through; `TaskReviewService` sets it on the local-merge accept path when the merge returned `MergeSuccess` and the strategy is `squash`.
**Why this over the floor**: the floor for FR7 is today's cleanup, and verify-first (scratch repo, 2026-11-13) shows it already keeps the work: `git branch --delete` refuses an unmerged branch and non-force `git worktree remove` refuses a dirty tree. The same refusal is wrong for a squash accept, whose branch is never an ancestor of the base, so every default accept leaves `dartclaw/task-<id>` behind with a WARN "Failed to delete branch". After `MergeSuccess` the work is on the base, so the force delete loses nothing.
**Hint format** (a contract, asserted verbatim): `Network blocked: domain not in allowlist (<host>); to allow it, add the host to <key>` where `<key>` is `guards.network.agent_overrides.<agentId>.extra_domains` when `agentId` is non-null, else `guards.network.extra_allowed_domains`. The prefix stays byte-identical so nothing matching on it breaks.


## Constraints & Gotchas

- **Constraint**: `cleanup` is also reached for tasks attached to an existing branch (`createBranch: false`, `info.branch` is an integration or operator branch) – Workaround: `forceDeleteBranch` deletes only a branch whose name is `dartclaw/task-<taskId>`; anything else keeps today's non-force delete.
- **Constraint**: the branch may be absent (a queued task cancelled before its worktree existed; a workflow step task keyed to a shared worktree) – a failed delete stays a WARN, never an error.
- **Constraint**: a dirty worktree makes `git worktree remove` fail and leaves its branch checked out, so `branch -D` fails too and the accept leaves both in place, as today.
- **Constraint**: a workflow-owned git task accept goes through no local merge (`isWorkflowOwnedGitTask`), so it never sets the option.


## Implementation Plan

### Implementation Tasks

- **TI01** NetworkGuard's reason carries the hint per the Hint format; existing exact-string assertions, the codex approval-flow assertion and the `control-protocol.md` example reason follow it.
  - Update the three assertions in `packages/dartclaw_kernel/test/network_guard_test.dart` and `codex_approval_flow_test.dart#routes exact own-MCP web fetch approval arguments through NetworkGuard`.
  - **Verify**: `packages/dartclaw_kernel/test/network_guard_test.dart#hint` – tests whose names contain `hint` cover agent id without an override entry (`web_fetch` and `shell`), no agent id, and the unchanged IP and exfiltration reasons; the verbatim format is asserted.
  - **Verify**: `packages/dartclaw_core/test/harness/codex_approval_flow_test.dart#routes exact own-MCP web fetch approval arguments through NetworkGuard` – the denial reason carries the hint.
  - **Verify**: `cmd: test -z "$(git grep -nF 'allowlist (evil.com)"' -- dev docs ':!dev/bundle')"` – no doc still shows the old reason.
  - **SATISFIES**: S01, S02, S03

- **TI02** One real-git test pins that cancel and cleanup keep unmerged work: a clean worktree with an unmerged commit ends with the directory removed and the commit still on `dartclaw/task-<id>`; a second, dirty worktree keeps its directory, changes and branch.
  - Beside `worktree_manager_test.dart#cleanup() removes worktree directory and branch`; it passes against today's code.
  - **Verify**: `packages/dartclaw_runtime/test/task/worktree_manager_test.dart#cleanup keeps unmerged work` – green on the unchanged cleanup.
  - **SATISFIES**: S04, S05

- **TI03** After a successful squash merge on the local accept path the task's own branch is force-deleted: `WorktreeManager.cleanup(taskId, project:, forceDeleteBranch:)` runs `branch -D` for a `dartclaw/task-<taskId>` branch, `cleanupWorktree` passes it through, and `TaskReviewService` sets it only after `MergeSuccess` with the squash strategy.
  - Failing-first: write `squash accept deletes the task branch` (real repository, real `MergeExecutor` and `WorktreeManager`) and watch it fail, then implement. Pattern: `merge_executor_test.dart` repository setup.
  - **Verify**: `packages/dartclaw_runtime/test/task/task_review_service_test.dart#squash accept deletes the task branch` – the branch is gone and the base holds the squash commit; the conflicting-merge case keeps the branch and leaves the task in `review`; `packages/dartclaw_runtime/test/task/worktree_manager_test.dart#forceDeleteBranch` – owned-name branch deleted, attached branch kept, default path unchanged.
  - **Verify**: `cmd: dart test --reporter=failures-only packages/dartclaw_runtime/test/task/worktree_manager_test.dart packages/dartclaw_runtime/test/task/task_review_service_test.dart` – both files green, so the fake-runner `cleanup()` command assertions and accept/reject behavior still hold.
  - **SATISFIES**: S06, S07, SC01

- **TI04** The docs state the behavior: one sentence in `docs/guide/projects-and-git.md` saying where a cancelled task's work is kept (unmerged commits on `dartclaw/task-<id>`, uncommitted changes in the worktree directory), `task-execution-architecture.md` § 5.1 `cleanup` bullet (squash accept force-deletes the task branch), and CHANGELOG § 0.28.1: one entry for the hint and one Fixed entry for the squash-accept branch (no story IDs).
  - **Verify**: `cmd: git grep -n "dartclaw/task-" -- docs/guide/projects-and-git.md` – the sentence is present; `cmd: git grep -n -i "squash" -- CHANGELOG.md dev/architecture/task-execution-architecture.md` – both name the squash-accept branch deletion.
  - **SATISFIES**: S04, S06

## Discovered Requirements

- **Preserve review ownership during cleanup**. **Description**: S03 made `TaskReviewService.review` require an explicit trigger and added a held result before merge/push. Execution-surface holds require a person; an agent tool remains automatic even in an admin chat. **Rationale**: The accept path changed after this FIS was authored. **Interpretation**: Keep the hold and hook-free commit gates ahead of the successful local squash cleanup; a held accept must retain its branch. Use explicit person provenance in manual-accept tests and preserve host-owned workflow approval markers if touching those paths. **Traced from**: S03/TI02, S03/TI03, S03/TI07. **Date**: 2026-11-17.
