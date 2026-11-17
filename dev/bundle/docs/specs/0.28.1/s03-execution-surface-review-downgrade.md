# Execution-surface Review Downgrade

**Plan**: dev/bundle/docs/specs/0.28.1/plan.json
**Story-ID**: S03

## Feature Overview and Goal

**Intent**: A container-written file that turns a later host-side action into code execution (an agent hook, an MCP server command, a git hook, a CI workflow, a symlink) never reaches the host through an unattended accept or workflow promotion without an operator looking at it first.

**Expected Outcomes**:

- [OC01] An accept nobody initiated (`tasks.completion_action: accept`, or an agent's own `task_review` accept) never merges or pushes a diff that touches an execution-surface path or adds a symlink.
- [OC02] The operator sees which paths held a task, on the task detail page and in the task API, and can still accept it by hand.
- [OC03] A workflow never promotes a story branch or pushes its branch for a pull request when the diff touches the same paths, without the operator's approval, under any `workflow.approvals` policy, with the paths named on the held run.
- [OC04] Everything else, `CLAUDE.md` and `AGENTS.md` edits included, lands exactly as today, and there is no config knob.
- [OC05] The host's own commit sweeps in agent worktrees run no git hook the agent wrote, and the check reads the change set before the sweep commits it.


## Required Context

Paths are relative to the public repo root (`../dartclaw-public/` from the private repo), where this FIS executes from its exported copy and where `cmd:` proofs run; `docs/specs/` and `docs/research/` paths name this plan's private sources, exported to `dev/bundle/docs/`.

- `docs/specs/0.28.1/prd.md#fr5-execution-surface-review-downgrade` – the list, the exclusions, the publish gate, the hook-disabled commit sweeps, the six acceptance criteria
- `docs/specs/0.28.1/prd.md#edge-cases` – a diff with a listed path and normal code is held whole
- `docs/research/devvm-2026-11/research.md#v3--flag-agent-written-execution-surface-files-before-accept-p1-security` – the attack path (container write, automatic merge, next host-mode spawn runs the hook)
- `dev/adrs/054-model-first-delegation-and-one-authority-per-concern.md` – binding: the check is deterministic host code, one authority
- `packages/dartclaw_runtime/lib/src/task/task_review_service.dart#TaskReviewService` – the accept path; `trigger` already separates `auto_accept` and `agent_tool` from `user` and `channel`
- `packages/dartclaw_runtime/lib/src/runtime/workflow_git_support.dart#promoteWorkflowBranchLocally` – the single host seam every workflow promotion passes through; `#publishWorkflowBranchLocally` and `#publishWorkflowBranchWithRemotePush` are the two publish seams


## Acceptance Scenarios

- **S01 [OC04] Instruction files and ordinary code land as before**
  - **Given** `tasks.completion_action: accept` and a worktree task whose changes touch only `CLAUDE.md`, `AGENTS.md` and `lib/a.dart`
  - **When** the task completes
  - **Then** it is accepted automatically and merged exactly as today, with no hold recorded

- **S02 [OC01,OC02] [runtime] A listed path holds an automatic accept**
  - **Given** `tasks.completion_action: accept` and a worktree task that adds `.claude/settings.json` with a hook, committed on its branch, or left uncommitted in its worktree
  - **When** the task completes
  - **Then** the task stays in `review`, the base ref is unchanged and nothing is pushed
  - **And** the task detail page and the task API response name `.claude/settings.json`

- **S03 [OC01] Every listed form is a hit and nothing near it is**
  - **Given** a change set touching one path at a time
  - **When** it is checked
  - **Then** `.claude/hooks/x.sh`, `.mcp.json`, `.codex/config.toml`, `.husky/pre-commit`, `.githooks/pre-push`, `.github/workflows/ci.yml`, `.envrc`, `.vscode/tasks.json`, `.vscode/settings.json`, `mise.toml` and the case variant `.Claude/Settings.json` each hit, and a deletion or rename of one hits too
  - **And** `.vscode/launch.json`, `.github/dependabot.yml`, `CLAUDE.md`, `AGENTS.md` and `docs/.claude/notes.md` do not hit

- **S04 [OC01] An added symlink hits wherever it is**
  - **Given** a change set that adds `docs/notes.md` as a symlink to `/etc/passwd`, committed, or untracked in the worktree
  - **When** it is checked
  - **Then** the symlink path is a hit
  - **And** deleting an existing symlink is not

- **S05 [OC01,OC02] A mixed diff is held whole and names only the listed paths**
  - **Given** a task diff touching `.github/workflows/ci.yml` and `lib/a.dart`
  - **When** its automatic accept is attempted
  - **Then** the whole accept is held, and the recorded paths are `.github/workflows/ci.yml` alone

- **S06 [OC02] An operator accepts a held task by hand**
  - **Given** a task held by S02
  - **When** the operator accepts it in the web UI or through the API
  - **Then** it merges and is accepted as it would be today, and the hold record no longer shows on the accepted task

- **S07 [OC01,OC02] An agent's own accept is held too**
  - **Given** a task in `review` whose diff touches `.mcp.json`
  - **When** an agent calls the `task_review` tool with `action: accept`
  - **Then** the task stays in `review` and the tool result names `.mcp.json`
  - **And** the result says the hold needs a person: Slack renders no review buttons, so a chat-only operator accepts the held task in the web UI or through the API
  - **Proof**: `packages/dartclaw_runtime/test/mcp/task_tools_test.dart#execution-surface hold` – red at spec time: the result names the path and the web UI or API route

- **S08 [OC03] [runtime] A listed path holds a workflow promotion**
  - **Given** a `per-map-item` workflow with `promotion: merge` whose story branch modifies `.mcp.json`
  - **When** the story's promotion would run
  - **Then** the integration branch is unchanged and the run is `awaitingApproval` with a message naming `.mcp.json`

- **S09 [OC03] The hold is not an approval step the policy can skip**
  - **Given** S08, or S12 below, under `workflow.approvals: auto`
  - **When** the promotion or publish would run
  - **Then** the run still stops `awaitingApproval`
  - **Proof**: `packages/dartclaw_workflow/test/workflow/component/parallel_story_promotion_test.dart#execution-surface hold` and `packages/dartclaw_workflow/test/workflow/executor_publish_recovery_test.dart#execution-surface publish hold` – red at spec time: both hold under `approvals: auto`

- **S10 [OC03] [runtime] Approval releases that hold only**
  - **Given** a run held by S08 whose second story also modifies `.husky/pre-commit`
  - **When** the operator resumes the run
  - **Then** the first story's branch is promoted and the run continues
  - **And** the second story's promotion is held, naming `.husky/pre-commit`

- **S11 [OC04] A clean promotion is unchanged**
  - **Given** a story branch touching `AGENTS.md` and `lib/a.dart`
  - **When** its promotion runs
  - **Then** it merges into the integration branch as today

- **S12 [OC03] [runtime] A listed path holds a workflow publish**
  - **Given** a workflow with `git.publish` enabled that resolves to a `shared` worktree (no promotion step, as built-in `implement-story` runs do), whose branch adds `.github/workflows/ci.yml`, committed or left uncommitted in the worktree, and a local bare remote
  - **When** the run finishes its steps and the publish would push
  - **Then** the remote has no new branch, no pull request is opened, and the run is `awaitingApproval` with a message naming `.github/workflows/ci.yml`
  - **Proof**: `packages/dartclaw_runtime/test/runtime/workflow_git_support_test.dart#execution-surface publish hold` – red at spec time: real repository and bare remote, both publish functions (local and remote-push), the remote untouched after a held publish; `packages/dartclaw_workflow/test/workflow/executor_publish_recovery_test.dart#execution-surface publish hold` – the run stops `awaitingApproval` naming the path

- **S13 [OC03] [runtime] Approval releases the publish hold**
  - **Given** a run held by S12
  - **When** the operator resumes the run
  - **Then** the branch is pushed and the run completes
  - **And** a clean branch (only `AGENTS.md` and `lib/a.dart`) publishes without any hold, as today
  - **Proof**: `packages/dartclaw_workflow/test/workflow/executor_publish_recovery_test.dart#execution-surface publish approval` – red at spec time: the run completes after `resume`; `packages/dartclaw_runtime/test/runtime/workflow_git_support_test.dart#execution-surface publish hold` – a clean branch pushes

- **S14 [OC05] [runtime] An agent-written git hook does not run on the host's commit sweep**
  - **Given** a real repository whose `core.hooksPath` points at `.husky` (as an installed husky sets it) or `.githooks`, an agent-written `pre-commit` there that creates a marker file, and an agent worktree with uncommitted changes
  - **When** each host commit sweep runs: the workflow worktree sweep (`commitWorkflowWorktreeChangesIfNeeded`, which the publish preparation also calls), the task accept and publish sweep in `TaskReviewService`, and the `WorkflowGitPortProcess` commit
  - **Then** the changes are committed and the marker file does not exist
  - **And** a change set that adds `.husky/pre-commit` is classified from the uncommitted state, so the S02 hold fires before any sweep commits it
  - **Proof**: `packages/dartclaw_runtime/test/runtime/workflow_git_support_test.dart#host commit sweep runs no git hooks` – red at spec time; `packages/dartclaw_runtime/test/task/task_review_service_test.dart#host commit sweep runs no git hooks` and `packages/dartclaw_runtime/test/task/workflow_git_port_process_test.dart#commit runs no git hooks` – the same assertion at the other two sites


## Structural Criteria

- **SC01** The path list and the symlink rule exist once, in the classifier module; the accept gate, the promotion gate and the two publish gates call it, and no other library source names a listed path.
- **SC02** Package tiers and LOC ceilings hold: `dartclaw_workflow` gains the held result and its handling, never the list or a runtime import.


## Scope & Boundaries

### Work Areas
- `dartclaw_runtime` task package: new classifier `execution_surface.dart`; `TaskReviewService` accept gate and its typed result, with every `ReviewResult` consumer (auto-accept callback in `task_wiring.dart`, `task_tools.dart`, channel mapping, `task_action_service.dart`)
- Task detail page (`tasks_page.dart` detail map, `templates/task_detail.dart`, `task_detail.html`) and task API (`task_routes.dart`)
- `workflow_git_support.dart` promotion gate and the two publish gates (`_publishWorkflowBranchLocallyUnlocked`, `_publishWorkflowBranchWithRemotePushUnlocked`), and the `-c core.hooksPath=/dev/null` commit sweeps (`commitWorkflowWorktreeChangesIfNeeded`, which `_prepareWorkflowBranchForPublish` also calls); the same flag on `task/task_review_service.dart` (commit at ~:379) and `task/workflow_git_port_process.dart` (commit at ~:126)
- `service_wiring_workflow.dart` publish callbacks (base ref, approval read from run context); `dartclaw_workflow` held promotion result and `WorkflowPublishStatus.held`, their handling in foreach and non-foreach promotion and in `_completeRun`, and the approval record
- User guide pages `tasks.md`, `workflows.md`, `security.md`, and CHANGELOG § 0.28.1

### What We're NOT Doing
- A config knob, per-project list or allow-list – ADR-054 and the PRD constraint: the list is fixed and deterministic.
- `CLAUDE.md` and `AGENTS.md` on the list – owner decision (PRD Decisions Log).
- Gating a direct `reviewMode: auto-accept` transition, or accepting a task with no worktree – neither merges nor pushes anything (`task_executor.dart` transitions without calling `TaskReviewService`).
- Matching nested `.claude/` or `.github/workflows/` directories – entries are root-anchored (see Constraints).
- Disabling git hooks anywhere but the host's commit sweeps in agent worktrees: merge-time hooks in `MergeExecutor` runs and the operator's own commits are untouched.
- A distinct "held" run status or UI – the existing `awaitingApproval` run detail and `dartclaw workflow run` exit code 2 apply.
- Architecture deep-dive and "Current through" updates – story S09 owns them; this story updates the user guide and CHANGELOG only.
- A held-state badge in the task list or a new notification – the detail page and API are the contract.


## Architecture Decision

**Approach**: One classifier in `dartclaw_runtime/lib/src/task/execution_surface.dart` returns the matched paths for a change set (branch commits not on the base, plus uncommitted and untracked worktree changes). It runs before every host commit sweep, because it reads the uncommitted and untracked state the sweep would otherwise commit. Four gates call it:
- `TaskReviewService` before any merge or push on an accept whose `trigger` is not a person's (`auto_accept`, `agent_tool`). `trigger` becomes a required parameter of `TaskReviewService.review`, so no caller can silently default to `user`; every caller (and test) passes it.
- `promoteWorkflowBranchLocally`, before its commit sweeps and the merge.
- `_publishWorkflowBranchLocallyUnlocked` and `_publishWorkflowBranchWithRemotePushUnlocked`, before `_prepareWorkflowBranchForPublish` and the push. Both take a `baseRef` that the `publishWorkflowBranch` callbacks resolve as task publish does (`origin/<default branch>` when it exists), so the publish gate also sees whatever reached the integration branch by other routes.

A task hold is recorded as `configJson._executionSurfaceHold: {paths: [...]}`, written by `updateFields` and replaced or removed on every check; the `_` prefix keeps clients from writing it, the task API already serializes `configJson`, and no top-level field is added. A promotion hold is a new `WorkflowGitPromotionHeld(paths)` result that the engine turns into the existing step-level `awaitingApproval` hold (the dependency-hold seam, `_transitionStepAwaitingApproval`), which `workflow.approvals` does not auto-resolve. A publish hold is a new `WorkflowPublishStatus.held` with `heldPaths`; `_completeRun` turns it into the same `awaitingApproval` hold on the run's final step, so `resume` re-enters `_completeRun` and retries the publish. A hold records its branch in run context; resuming moves it to `_workflow.git.approved_branches`, which the host callbacks read by `runId`, and the retried promotion or publish passes the gate for that branch only.
The four host commit sweeps in agent worktrees (`workflow_git_support.dart` `commitWorkflowWorktreeChangesIfNeeded`, `task_review_service.dart` accept and publish, `workflow_git_port_process.dart` commit) run `git -c core.hooksPath=/dev/null commit`, which overrides any `core.hooksPath` the repository configures.
**Why this over the floor**: The floor is the existing review path with no check. The PRD requires a held accept, promotion and publish with the paths named, and no hook running on the host's commit; nothing existing sees a diff's paths at those points. Gating publish as well is required because built-in single-story and serial runs never promote, and a pushed `.github/workflows/**` change runs with repository secrets before any review.
**Flow**: classifier (runtime/task) <- `TaskReviewService` accept gate -> hold record -> detail page and API. Classifier <- `promoteWorkflowBranchLocally` -> `WorkflowGitPromotionHeld` -> engine hold -> `resume` approval record -> retried promotion. Classifier <- both publish functions -> `held` publish result -> `_completeRun` hold -> `resume` approval record -> retried publish.


## Constraints & Gotchas

- **Constraint**: change-set sources differ by accept route. A project-backed accept commits the worktree with `git add -A` before pushing, and a local merge lands branch commits only – the gate runs before both and checks the union, so the hold never depends on which one runs. Untracked files are classified by filesystem entity type, since git has no mode for them yet.
- **Constraint**: `ReviewResult` is sealed. A new held variant breaks every exhaustive switch, which is how the consumers listed under Work Areas are found; the auto-accept callback must report the hold as a hold (task stays in `review`), not as a failed auto-accept.
- **Constraint**: the foreach promotion also resolves through merge-resolve's retry results. A held result can only come from the first promotion, but its switches must stay exhaustive.
- **Constraint**: `agent_tool` (an agent's own `task_review` accept) counts as an automatic accept and is held with `auto_accept`; `user` and `channel` accepts proceed. The cost is stated in the hold's tool result: Slack renders no review buttons, so a chat-only operator accepts the held task in the web UI or through the API (the registered tool is `task_review`).
- **Constraint**: list entries are anchored at the repository root and matched case-insensitively (a macOS or Windows checkout resolves `.Claude` to `.claude`); only the symlink rule applies at any depth. Nested `.claude/` or workflow directories do not match.
- **Constraint**: "touches" includes deleting a listed path and both ends of a rename, and a non-deleted symlink in the change set counts whether added, retyped from a file or retargeted. Deleting an existing symlink does not.
- **Constraint**: a workflow hold reuses `awaitingApproval` and `resume`, with no new run status or UI, so the existing run detail and `dartclaw workflow run` exit code 2 apply.
- **Constraint**: the hook-disabling flag goes on the commit only. `git add` runs no hook, and the host's merge and push paths are out of scope here.

## Implementation Plan

### Implementation Tasks

- **TI01** A classifier returns the matched paths for a worktree's change set against a base ref: the fixed root-anchored list from PRD FR5, case-insensitive, deletes and renames counted, any non-deleted symlink counted, `CLAUDE.md` and `AGENTS.md` absent.
  - Real git repositories in the test; follow `diff_generator_test.dart` for repository setup.
  - **Verify**: `packages/dartclaw_runtime/test/task/execution_surface_test.dart#ExecutionSurface` – the new group covers every path in scenarios S03 and S04 (committed, uncommitted, untracked), the mixed diff of S05 returning the listed path alone, and the clean sets of S01 and S11 returning nothing
  - **SATISFIES**: S01, S03, S04, S05, S11, SC01

- **TI02** `TaskReviewService` holds an accept whose trigger is `auto_accept` or `agent_tool` and whose change set hits: status stays `review`, no merge or push runs, the hold is recorded per Architecture Decision, and a clean check removes any earlier record. A `user` or `channel` accept skips the gate. `trigger` is a required named parameter of `review` (`task_review_service.dart:141`) and every caller passes it.
  - Gate position: before the merge and project-push branches of `_reviewUnlocked` and before its commit sweep. Every `ReviewResult` consumer reports the hold with its paths; the auto-accept callback in `task_wiring.dart#buildAutoAcceptCallback` logs a hold, not a failure; the `task_review` tool result names the paths and states the Slack cost (S07).
  - **Verify**: `packages/dartclaw_runtime/test/task/task_review_service_test.dart#execution-surface hold` – with a real repository and `MergeExecutor`, the base ref is unchanged after a held accept and contains the commit after a person's accept; a project-backed held accept pushes nothing; the hold record is gone from the accepted task; `packages/dartclaw_runtime/test/mcp/task_tools_test.dart#execution-surface hold` – the `task_review` accept result names the path and the web UI or API route; `cmd: dart analyze --fatal-infos packages/dartclaw_runtime` – no call of `review` omits `trigger`
  - **SATISFIES**: S01, S02, S05, S06, S07

- **TI03** The host's commit sweeps in agent worktrees run with hooks disabled (`-c core.hooksPath=/dev/null`): `commitWorkflowWorktreeChangesIfNeeded` (its commit at `workflow_git_support.dart:230`, which the publish preparation at ~:518 also calls), the `TaskReviewService` worktree commit (~:379) and `WorkflowGitPortProcess.commit` (~:126).
  - **Verify**: `packages/dartclaw_runtime/test/runtime/workflow_git_support_test.dart#host commit sweep runs no git hooks`, `packages/dartclaw_runtime/test/task/task_review_service_test.dart#host commit sweep runs no git hooks` and `packages/dartclaw_runtime/test/task/workflow_git_port_process_test.dart#commit runs no git hooks` – new tests: a real repository with `core.hooksPath` at `.husky` and a marker-writing `pre-commit`; the commit lands and the marker is absent
  - **SATISFIES**: S14

- **TI04** The task detail page names the held paths and the task API response carries them.
  - Detail map: `tasks_page.dart#_taskToDetailMap`; follow the `hasConflict` / `conflictingFiles` banner in `task_detail.dart` and `task_detail.html`, escaping per `TRELLIS-GUIDELINES.md`.
  - **Verify**: `packages/dartclaw_runtime/test/templates/task_detail_template_test.dart#execution-surface hold` – the held paths render escaped and the accept control is still offered; `packages/dartclaw_runtime/test/api/task_routes_test.dart#execution-surface hold` – `GET /api/tasks/<id>` returns the paths under `configJson._executionSurfaceHold`
  - **SATISFIES**: S02, S06

- **TI05** `promoteWorkflowBranchLocally` returns `WorkflowGitPromotionHeld(paths)` without merging when the story branch's change set against the integration branch hits and the branch is not in the run's approved branches; both publish functions return a `held` result with `heldPaths` without pushing, under the same condition, against the `baseRef` their callbacks pass.
  - Gate position: before every `commitWorkflowWorktreeChangesIfNeeded` sweep (promotion) and before `_prepareWorkflowBranchForPublish` (publish); the classifier reads the worktree's uncommitted and untracked state itself. The callbacks in `service_wiring_workflow.dart` resolve the base ref and read the approved branches from the run's context by `runId`.
  - **Verify**: `packages/dartclaw_runtime/test/runtime/workflow_git_support_test.dart#execution-surface hold` – real repository: the integration branch SHA is unchanged after a held promotion, a clean branch promotes, an approved branch promotes; `#execution-surface publish hold` – real repository and bare remote: both publish functions leave the remote untouched when held, push a clean branch and push an approved one
  - **SATISFIES**: S08, S10, S11, S12, S13, SC01

- **TI06** The workflow engine settles a held promotion, in foreach (`foreach_iteration_runner.dart`, `promotion_coordinator.dart#callPromote`) and non-foreach (`workflow_executor_node_helpers.dart#_promoteWorkflowTask`) steps, as an `awaitingApproval` hold whose message names the paths, with the iteration or step left pending at its persisted cursor so resume re-enters at the promotion; and a held publish in `_completeRun` as the same hold on the run's final step, so resume re-enters `_completeRun`.
  - Persist-before-transition, as the dependency hold does. No `workflow.approvals` branch applies to either.
  - **Verify**: `packages/dartclaw_workflow/test/workflow/component/parallel_story_promotion_test.dart#execution-surface hold` – foreach: run `awaitingApproval`, message names the path, the same under `approvals: auto`; `packages/dartclaw_workflow/test/workflow/component/workflow_promotion_test.dart#execution-surface hold` – non-foreach step, same assertions; `packages/dartclaw_workflow/test/workflow/executor_publish_recovery_test.dart#execution-surface publish hold` – the run stops `awaitingApproval` naming the path, also under `approvals: auto`
  - **SATISFIES**: S08, S09, S12, SC02

- **TI07** Resuming a promotion or publish hold records its branch as approved in run context (`_workflow.git.approved_branches`), and the retried promotion or publish passes the gate for that branch only; a later held branch stops again.
  - **Verify**: `packages/dartclaw_workflow/test/workflow/component/parallel_story_promotion_test.dart#execution-surface approval` – first story promotes after `resume`, second story held again naming its path; `packages/dartclaw_workflow/test/workflow/executor_publish_recovery_test.dart#execution-surface publish approval` – the run completes after `resume` and the branch is pushed
  - **SATISFIES**: S10, S13

- **TI08** The user guide and CHANGELOG state the behavior: `tasks.md` (the `completion_action` paragraph, the list, the held task and manual accept, the Slack cost for an agent's own accept, `CLAUDE.md` and `AGENTS.md` excluded), `workflows.md` (promotion and publish hold, resume approval, not skipped by `workflow.approvals`), `security.md` § Container Isolation (the merge and push as the escape the hold closes, host commit sweeps run without hooks), and a CHANGELOG § 0.28.1 entry without story IDs.
  - **Verify**: `cmd: test "$(git grep -l -i -F 'execution surface' -- docs/guide/tasks.md docs/guide/workflows.md docs/guide/security.md CHANGELOG.md | wc -l)" -eq 4` – all four files use the term; the executor also checks each page's statements against S01 to S14
  - **SATISFIES**: S02, S06, S07, S08, S10, S12, S13, S14

- **TI09** The list and the symlink rule appear once in library source, and the architecture check passes.
  - **Verify**: `cmd: test -z "$(git grep -l -F -e '.githooks' -e '.husky' -e 'mise.toml' -- 'packages/*/lib' 'apps/*/lib' | grep -v execution_surface)"` – no consumer carries a copy; the `fast` tier is green (tier order and LOC ceilings stay with the release `architecture` gate)
  - **SATISFIES**: SC01, SC02


## Final Validation Checklist

- Capture the held-task detail page per `VISUAL-VALIDATION-WORKFLOW.md` and look at it: paths legible, the accept control present. The `visual` profile has no seeded tasks before story S08, so set `configJson._executionSurfaceHold` on a task in a `plain` profile instead.
