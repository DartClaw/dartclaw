# Tasks

DartClaw's task system is for reviewable background work. A task carries a title, description and explicit execution declarations, then stops in a review state before the final outcome is accepted.

## Core Concepts

### Lifecycle

```text
draft -> queued -> running -> review -> accepted
                 |         |
                 |         -> rejected
                 |-> failed -> queued
                 -> interrupted -> queued
```

Push-back sends a review task back to `queued` with operator feedback attached.

Starting a failed task — from the task page or `POST /api/tasks/<id>/start` — re-queues it as a fresh attempt: the
retry counter resets to zero and the previous run's recorded error and error summary are cleared, so the restarted run
gets the task's full `maxRetries` budget again and shows no leftover failure text while it runs.

## Creating Tasks

### Web UI

Open `/tasks` and use **New Task**. The form supports:

- title
- description
- acceptance criteria
- optional goal
- `autoStart`
- advanced overrides such as model and token budget
- whether the task needs an isolated git worktree

`autoStart: true` queues the task immediately. Otherwise it remains in `draft` until started manually.

### API

```http
POST /api/tasks
Content-Type: application/json

{
  "title": "Refactor the auth middleware tests",
  "description": "Tighten rate-limit and cookie coverage without changing behavior.",
  "acceptanceCriteria": "All auth tests pass and analyzer stays clean.",
  "autoStart": true,
  "configJson": {"needsWorktree": true}
}
```

Tasks can also be linked to a goal with `goalId`.

### Project Targeting

Tasks can target a specific project. When creating a task, set `projectId` to route it to the correct repository:

```http
POST /api/tasks
Content-Type: application/json

{
  "title": "Refactor auth middleware",
  "description": "Refactor the middleware without changing behavior.",
  "projectId": "my-app",
  "autoStart": true,
  "configJson": {"needsWorktree": true}
}
```

- If `projectId` is omitted, the task targets the **default project** (first project with `default: true`, or the first external project, or `_local`).
- The web UI's **New Task** dialog includes a project selector dropdown showing all registered projects with status indicators.
- Tasks targeting external projects get auto-fetch before worktree creation and push-to-remote on accept. Tasks targeting `_local` use local merge.

See [Projects & Git](projects-and-git.md) for project setup, auto-fetch behavior, and accept workflows.

### Per-Task Overrides

When creating a task (via API or web UI), you can set per-task overrides in `configJson`:

| Key | Type | Default | Purpose |
|-----|------|---------|---------|
| `model` | `string` | global `agent.model` | Model override for this specific task |
| `tokenBudget` | `int` | unlimited | Maximum total token spend; task auto-fails if exceeded (`budget` is a deprecated alias). Per-task budgets are independent of the server-wide [daily token budget](governance.md#daily-token-budget) |
| `needsWorktree` | `bool` | `false` | Whether the task runs in an isolated git worktree |
| `artifactExtensions` | `list<string>` | all modified files | Extensions to retain when collecting files from a non-worktree task, for example `['.md']` |
| `reviewMode` | `string` | `mandatory` | `auto-accept`, `mandatory`, or `worktree-only` |

```http
POST /api/tasks
Content-Type: application/json

{
  "title": "Deep security audit of auth module",
  "description": "Analyze all auth code paths for vulnerabilities.",
  "projectId": "my-app",
  "autoStart": true,
  "configJson": {
    "model": "opus",
    "tokenBudget": 500000
  }
}
```

The web UI's **New Task** dialog exposes these as "Advanced" fields.

## Execution Model

Tasks acquire per-provider worker leases from the execution coordinator, separate from the fixed primary lane used for main user/channel turns. For a full comparison of background tasks and logical-agent sessions, see [Agents](agents.md).

- `providers.<id>.pool_size` is a hard concurrent lease limit shared with other background execution
- the primary lane is never acquired by the task executor
- tasks default to the neutral `workspace` container profile unless an operator declares another profile
- `/tasks` shows execution state through lease-derived worker metrics

### Container Profile Routing

Tasks default to the neutral `workspace` profile. An operator may instead declare `securityProfile: "restricted"`
as a top-level field on the authenticated `POST /api/tasks` request. The declaration is intentionally unavailable
to channel and model-facing task creation surfaces. `configJson.securityProfile` is host-reserved and rejected.

These profiles apply when POSIX container isolation is available. Native Windows keeps task routing and worktree
behavior but cannot activate these container profiles; enabling containers fails closed with POSIX/WSL remediation.

| Declaration | Profile | Mounts |
|-------------|---------|--------|
| Omitted or `workspace` | `workspace` | `/workspace:rw`, `/project:ro` |
| `restricted` | `restricted` | No workspace mount |

The task executor requests a worker for the task's exact provider and effective execution policy. A declared
`restricted` task will only run on a `restricted`-profile runner. Workers start lazily; each task container is
dedicated to that task execution and destroyed when its turn ends.

A container task can only run on a provider whose container execution DartClaw mediates – `claude` and `codex`.
An ACP provider runs on the host only: set the scalar `tasks.execution: host`, or the task lane is refused before it
starts rather than quietly running unisolated. A declared container profile cannot be combined with host execution.

The former `research` input selected `restricted` implicitly. It is now refused on every creation and scheduled
input path so that upgrading cannot silently widen an existing boundary. Declare `securityProfile: "restricted"`
through the authenticated API when that boundary is required. Pre-upgrade stored
`research` rows fail before dispatch with the same remediation.

## Worktree Isolation

Set `configJson.needsWorktree` to `true` to run a task inside an isolated git worktree created from its target project.
Set it to `false` to run in the workflow or project workspace. The web form always sends this declaration. Legacy
`coding` input is refused with this declaration named so an upgrade cannot silently drop isolation.

- **External projects**: worktree branches from the project clone (auto-fetched). On accept, the branch is pushed to the remote (and a PR created if configured).
- **`_local` project**: worktree branches from the local base ref. On accept, `MergeExecutor` squash-merges locally.
- `tasks.worktree.base_ref` chooses the base branch (`_local` tasks only; external projects use their configured `branch`)
- `tasks.worktree.stale_timeout_hours` controls when abandoned worktrees are considered stale
- `tasks.worktree.merge_strategy` chooses `squash` or `merge` for accepted `_local` work

The worktree path is guarded so file operations stay contained to the task's assigned checkout. See [Projects & Git](projects-and-git.md) for the full worktree lifecycle and accept flow.

## Review Workflow

When execution finishes, the task enters `review` with artifacts attached:

- **Accept**: finalizes the task and, when it has a standalone worktree, merges that worktree back into the base ref
- **Reject**: closes the task without re-queueing it
- **Push Back**: requires a comment and returns the task to `running`

The task detail page combines:

- recent session messages (from the execution transcript, not the full history)
- structured diff output when available
- raw or rendered artifacts
- review controls

## Diff Review and Merge Conflicts

Worktree-backed tasks attach a structured diff artifact for review. Tasks without a worktree attach files modified since
their start time, optionally narrowed by `artifactExtensions`. If the final merge hits conflicts, DartClaw preserves a
`conflict.json` artifact and keeps the task in review so the operator can resolve the worktree manually.

## Agent Tool Surface

The agent manages tasks through six MCP tools rather than through chat commands. Each is a strict-schema call: an
argument the schema does not name is rejected before the tool runs.

| Tool | Accepts | Returns |
|---|---|---|
| `task_create` | `title`, `description`, optional `acceptance_criteria`, `project_id`, `auto_start` | the new task's full ID, title and status |
| `task_list` | optional `status`, `limit` (max 200, default 50) | matching tasks with full IDs, plus whether the listing was truncated |
| `review_list` | no arguments | the tasks awaiting review, oldest first, with full IDs |
| `task_review` | `task_id`, `action` (`accept`, `reject`, `push_back`), `feedback` (required for `push_back` only) | the task's full ID, title and new status |
| `task_bind` | `task_id`, `channel_type` (`googlechat`), `thread_id` | the binding's session key |
| `task_unbind` | `task_id` | how many bindings were removed |

Both listings emit full task IDs, so an ordinal reference in the conversation ("accept the second one") resolves
against `review_list`'s order rather than against an ID prefix. `task_review` acts on the full ID only.

What these tools cannot do:

- **`task_create` cannot set a security profile, container profile, mount, placement, provider, model or token
  budget.** A task profile can only be declared as the top-level `securityProfile` field of an authenticated
  `POST /api/tasks` request. The scalar `tasks.execution` YAML key selects host or container mode for the lane; it
  does not declare a profile. No model-facing tool argument spells either setting.
- **`task_create` cannot choose a creator.** The task's `createdBy` is host-assigned.
- **`task_bind` cannot bind "the current thread".** A tool call carries no channel context, so the thread must be
  named explicitly. Binding the thread a message arrived in is what the `/bind` reserved command is for.

- **`task_bind` binds a thread, not a group, and `channel_type` accepts only `googlechat`.** A binding is keyed by the
  per-message thread identity that inbound routing reads, and Google Chat is the only channel that sends one. Naming
  any other channel fails the tool's schema, because a binding stored against a group would never route a message.

  Naming the thread explicitly is also the reach worth knowing about: an agent may bind **any** thread it can name,
  as long as that thread is not already bound and the task is not terminal. It does not have to be a thread the agent
  is talking in. Messages in a bound thread then route to the task's session, so a wrongly chosen thread quietly
  changes where a conversation goes. DartClaw is single-owner, so this reaches only your own threads, but if you want
  it constrained, `task_bind` is a write-classified tool like any other - deny it in a guard rule, or leave it out of
  the agent's allowlist. Every call is audited either way.
- **`task_review` with `push_back` reports the transition, not delivery.** Feedback delivery to the running agent is
  best-effort and unreported.

Every call is guard-evaluated and audited at the MCP dispatch seam; a blocked call comes back as a tool error with no
side effect. Guard coverage differs per provider — Codex interception remains approval-routed, so a Codex deployment's
coverage depends on its configured approval mode (see [Security](security.md)).

The six are also canonical tool names, so an agent or workflow-step allowlist must name them explicitly; allowing
`mcp_call` alone does not grant them.

## Automation and Scheduling

Recurring tasks are scheduled using `type: task` jobs under `scheduling.jobs`. This is the unified model — both prompt-based jobs and task-based jobs live in the same `scheduling.jobs` list.

```yaml
providers:
  claude:
    executable: claude
    pool_size: 3

tasks:
  worktree:
    base_ref: main
    stale_timeout_hours: 24
    merge_strategy: squash

scheduling:
  jobs:
    - id: daily-maintenance-review
      type: task
      schedule: "0 9 * * 1-5"
      enabled: true
      task:
        title: Daily maintenance review
        description: Review maintenance items and report changes that are needed.
        acceptance_criteria: Findings identify each affected component and its next action.
        auto_start: true
```

Scheduled task jobs do not expose the standalone worktree declaration. Use a workflow or create a standalone task
through the API or web form when the turn must run in an isolated worktree.

Task jobs can also override `effort` at the job level:

```yaml
scheduling:
  jobs:
    - id: quick-analysis
      type: task
      schedule: "0 10 * * *"
      effort: low
      task:
        title: Quick analysis
        description: Run a lightweight daily analysis.
```

See [Scheduling](scheduling.md) for the broader scheduler model.

## Goals and Observability

- Tasks can be grouped under goals for planning and reporting
- `/tasks` shows review counts and lease-derived worker utilization
- task detail pages expose recent session messages plus artifacts for operator review

## Configuration Summary

These task-specific runtime keys come from `DartclawConfig`:

- `providers.<id>.pool_size`
- `tasks.worktree.base_ref`
- `tasks.worktree.stale_timeout_hours`
- `tasks.worktree.merge_strategy`
- `scheduling.jobs` (with `type: task` entries for scheduled recurring tasks)

See also [Configuration](configuration.md), [Scheduling](scheduling.md), and [Web UI & API](web-ui-and-api.md).
