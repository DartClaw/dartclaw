# Tasks

DartClaw's task system is for reviewable background work. A task can run as coding, research, writing, analysis, automation, or custom work, then stop in a review state before the final outcome is accepted.

## Core Concepts

### Task Types

- `coding`
- `research`
- `writing`
- `analysis`
- `automation`
- `custom`

### Lifecycle

```text
draft -> queued -> running -> review -> accepted
                 |         |
                 |         -> rejected
                 -> interrupted -> queued
```

Push-back sends a review task back to `queued` with operator feedback attached.

## Creating Tasks

### Web UI

Open `/tasks` and use **New Task**. The form supports:

- title
- description
- type
- acceptance criteria
- optional goal
- `autoStart`
- advanced overrides such as model and token budget

`autoStart: true` queues the task immediately. Otherwise it remains in `draft` until started manually.

### API

```http
POST /api/tasks
Content-Type: application/json

{
  "title": "Refactor the auth middleware tests",
  "description": "Tighten rate-limit and cookie coverage without changing behavior.",
  "type": "coding",
  "acceptanceCriteria": "All auth tests pass and analyzer stays clean.",
  "autoStart": true
}
```

Tasks can also be linked to a goal with `goalId`.

### Per-Task Overrides

When creating a task (via API or web UI), you can set per-task overrides in `configJson`:

| Key | Type | Default | Purpose |
|-----|------|---------|---------|
| `model` | `string` | global `agent.model` | Model override for this specific task |
| `tokenBudget` | `int` | unlimited | Maximum total token spend; task auto-fails if exceeded (`budget` is a deprecated alias) |

```http
POST /api/tasks
Content-Type: application/json

{
  "title": "Deep security audit of auth module",
  "description": "Analyze all auth code paths for vulnerabilities.",
  "type": "analysis",
  "autoStart": true,
  "configJson": {
    "model": "opus",
    "tokenBudget": 500000
  }
}
```

The web UI's **New Task** dialog exposes these as "Advanced" fields.

## Execution Model

Tasks run on dedicated harness instances from the `HarnessPool`, separate from the primary harness used for interactive chat, cron, and channels. For a full comparison of task runners vs subagents (the other agent model), see [Agents](agents.md).

- `tasks.max_concurrent` controls how many background task runners are started (each is an independent claude binary subprocess)
- the primary interactive chat runner (index 0) is never acquired by the task executor
- each task type maps to a container security profile (see below)
- `/tasks` shows runner state through the agent pool and runner metrics panels

### Container Profile Routing

Each task type maps to a security profile that determines container isolation:

| Task Type | Profile | Mounts |
|-----------|---------|--------|
| `research` | `restricted` | No workspace mount |
| `coding` | `workspace` | `/workspace:rw`, `/project:ro` |
| `writing` | `workspace` | `/workspace:rw`, `/project:ro` |
| `analysis` | `workspace` | `/workspace:rw`, `/project:ro` |
| `automation` | `workspace` | `/workspace:rw`, `/project:ro` |
| `custom` | `workspace` | `/workspace:rw`, `/project:ro` |

In pool mode, the task executor matches a task's profile to a runner started with that profile. A `research` task will only run on a `restricted`-profile runner -- it won't accidentally get a `workspace` runner with filesystem access.

## Coding Tasks and Worktrees

Coding tasks run inside an isolated git worktree:

- `tasks.worktree.base_ref` chooses the base branch or ref
- `tasks.worktree.stale_timeout_hours` controls when abandoned worktrees are considered stale
- `tasks.worktree.merge_strategy` chooses `squash` or `merge` for accepted work

The worktree path is guarded so file operations stay contained to the task's assigned checkout.

## Review Workflow

When execution finishes, the task enters `review` with artifacts attached:

- **Accept**: finalizes the task and, for coding tasks, merges the worktree back into the base ref
- **Reject**: closes the task without re-queueing it
- **Push Back**: requires a comment and returns the task to `queued`

The task detail page combines:

- recent session messages (most recent messages from the execution transcript, not the full history)
- structured diff output when available
- raw or rendered artifacts
- review controls

## Diff Review and Merge Conflicts

Coding tasks typically attach a structured diff artifact for review. If the final merge hits conflicts, DartClaw preserves a `conflict.json` artifact and keeps the task in review so the operator can resolve the worktree manually.

## Automation and Scheduling

Recurring tasks are scheduled using `type: task` jobs under `scheduling.jobs`. This is the unified model — both prompt-based jobs and task-based jobs live in the same `scheduling.jobs` list.

```yaml
tasks:
  max_concurrent: 3
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
        description: Review maintenance items and prepare a coding task if changes are needed.
        type: coding
        acceptance_criteria: Tests stay green and the worktree is ready for review.
        auto_start: true
```

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
        type: analysis
```

See [Scheduling](scheduling.md) for the broader scheduler model.

## Goals and Observability

- Tasks can be grouped under goals for planning and reporting
- `/tasks` shows review counts and runner utilization
- task detail pages expose recent session messages plus artifacts for operator review

## Configuration Summary

These task-specific runtime keys come from `DartclawConfig`:

- `tasks.max_concurrent`
- `tasks.worktree.base_ref`
- `tasks.worktree.stale_timeout_hours`
- `tasks.worktree.merge_strategy`
- `scheduling.jobs` (with `type: task` entries for scheduled recurring tasks)

See also [Configuration](configuration.md), [Scheduling](scheduling.md), and [Web UI & API](web-ui-and-api.md).
