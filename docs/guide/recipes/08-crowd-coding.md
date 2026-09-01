# Recipe 8: Using DartClaw in a Group

## Overview

Crowd coding is a supported, opt-in way to let a trusted group steer one DartClaw instance from a shared channel. The
normal channel, task, workflow, governance, and emergency-control surfaces do the work; crowd coding does not add a
second command language.

Participants make requests in ordinary language. The agent decides when to call the registered task and workflow tools.
Facilitators retain deterministic controls for stopping, pausing, resuming, inspecting, resetting, and binding work even
when the model is unavailable.

## Features Used

- [Google Chat Spaces](../google-chat.md) for a shared room and threaded replies
- Shared group sessions so every participant contributes to the same conversation
- [Task tools](../tasks.md#agent-tool-surface) for creating, listing, reviewing, binding, and unbinding background work
- `workflow_list` and `workflow_run` for listing and starting workflows
- Multi-sender governance: fair queuing, rate limits, budgets, loop detection, and administrator controls
- Optional project bindings for work in an external repository

## Prerequisites

- DartClaw installed and running (see [Getting Started](../getting-started.md))
- A Google Cloud project with the Chat API enabled (see [Google Chat setup](../google-chat.md))
- A Google Chat Space and a configured service account for the bot
- A trusted set of participants; crowd coding grants several people access to the same agent and workspace
- Optionally, a configured project repository

## Configuration Scenarios

Start with this complete configuration, then add a `projects:` entry if the group will work in another repository.

### Scenario A: Shared Group Session

```yaml
data_dir: ~/.dartclaw

agent:
  model: sonnet
  max_turns: 100

providers:
  claude:
    pool_size: 5

features:
  thread_binding:
    enabled: true

governance:
  crowd_coding:
    model: sonnet
    effort: medium
  queue_strategy: fair
  admin_senders:
    - "users/123456789012345"
  rate_limits:
    per_sender:
      messages: 10
      window: 5m
      max_queued: 5
      max_pause_queued: 10
    global:
      turns: 30
      window: 1h
  budget:
    daily_tokens: 500000
    action: block
    timezone: America/New_York
  loop_detection:
    enabled: true
    max_consecutive_turns: 5
    max_tokens_per_minute: 10000
    velocity_window_minutes: 2
    max_consecutive_identical_tool_calls: 5
    action: abort

channels:
  google_chat:
    enabled: true
    service_account: ${GOOGLE_CHAT_SERVICE_ACCOUNT}
    group_access: open
    require_mention: false
    space_events:
      enabled: true

sessions:
  group_scope: shared

tasks:
  completion_action: accept

guards:
  enabled: true
  content:
    enabled: true
```

This is a shared-session configuration. Every ordinary message enters the same group session. When someone asks for
background work, the agent calls `task_create`; when someone asks for a workflow, it uses `workflow_list` or
`workflow_run`. See [Tasks](../tasks.md#agent-tool-surface) for the exact tool contracts.

### Scenario B: External Repository

Add a project to Scenario A when the group should work against a repository other than DartClaw's local workspace:

```yaml
projects:
  workshop-repo:
    remote: git@github.com:org/workshop-repo.git
    branch: main
    credentials: github-main
    clone:
      strategy: shallow
    pr:
      strategy: github-pr
      draft: true
      labels: [workshop, agent]
```

Before inviting participants, verify the credential can clone and push, start DartClaw, and confirm the project is
ready on `/projects`. Worktree and publication behavior comes from the task or workflow request; group-channel origin
alone does not imply an isolated worktree.

## Behavior Files

Put the following guidance in the group workspace. It teaches the agent how to use its registered tools without
inventing host-side chat syntax.

### SOUL.md -- Group Session

```markdown
# Group Coding Assistant

## Your Role

Help a trusted group work on one codebase. Ask concise clarifying questions when requests conflict or omit a necessary
choice. Keep the room informed about what you are changing and what needs human attention.

## Tasks and Workflows

- For background work, call `task_create` with the agreed description and project.
- Use `task_list` and `review_list` to retrieve full task IDs and current state.
- When the group asks for a review decision, call `task_review` with the full task ID and requested disposition.
- Use `task_bind` only when the request supplies the full task ID, channel type, and thread identity.
- Use `task_unbind` with the full task ID to remove all of that task's thread bindings.
- Use `workflow_list` to discover workflows and `workflow_run` to start the chosen definition with its variables.
- Never claim a task, binding, review, or workflow action succeeded until its tool result confirms it.

## Group Conduct

- Attribute competing proposals to their authors and summarize the trade-off before acting.
- Do not let the most recent message silently override a decision the group already made.
- Prefer small, reviewable changes and report tests or validation you actually ran.

## Git Discipline

- Inspect the repository state before editing.
- Do not overwrite unrelated work.
- Commit only the files changed for the agreed request.
```

### TOOLS.md (all scenarios)

```markdown
# Project Context

## Repository

- Project: <name>
- Working directory: <absolute path>
- Default branch: main

## Conventions

- Read the repository's AGENTS.md or CLAUDE.md before editing.
- Run the repository's targeted checks before reporting completion.
- Preserve unrelated work in a shared workspace.

## Available DartClaw Actions

- Tasks: `task_create`, `task_list`, `review_list`, `task_review`, `task_bind`, `task_unbind`
- Workflows: `workflow_list`, `workflow_run`
- Media delivery: `attach_media`
```

## Workflow

### Setup (all scenarios)

1. Start DartClaw and verify the Google Chat channel is connected.
2. Invite participants to the Space and explain that the room shares one agent session.
3. Confirm the facilitator is listed in `governance.admin_senders`.
4. Ask the agent to list available workflows and tasks. Confirm its tool results appear in the room.
5. Make one disposable task request and verify it appears on `/tasks` before beginning the session.

### Running the session

Participants ask for work in ordinary language. For example: “Create a background task to add a health endpoint to the
workshop project.” The agent calls `task_create` and reports the returned full ID. Later requests to inspect or decide
the task cause it to call `review_list`, `task_list`, or `task_review`.

To start a workflow, ask the agent what workflows are available, select one, and provide its required inputs. The agent
calls `workflow_list` and `workflow_run`. The web launch forms at `/workflows` and the standalone CLI remain available
for operators who want deterministic workflow initiation.

### Deterministic controls (all scenarios)

- Google Chat app commands are `/new <description>`, `/reset`, `/status`, `/stop`, `/pause`, and `/resume`. Register
  those six command IDs in the Chat app configuration before the workshop.
- The bridge-reserved text commands are `/stop`, `/pause`, `/resume`, `/bind <full-task-id>`, and `/unbind`. They are
  consumed before pause queueing and per-sender rate limiting. `/bind` and `/unbind` are text commands, not Google Chat
  app commands.
- `/stop` cancels active work and clears queued messages. All five bridge-reserved commands are admin-only when
  `admin_senders` is non-empty.
- `/pause` stops queue draining while preserving queued messages; `/resume` resumes it.
- `/status` reports the current runtime state, `/new` creates and starts a Google Chat task, and `/reset` starts a fresh
  shared session context.

WhatsApp and Signal use the bridge-reserved text-command path documented in their channel guides.

### Cross-channel binding

Thread binding is opt-in and requires `features.thread_binding.enabled: true`, as set in Scenario A. `/bind` and
`/unbind` remain deterministic commands. `/bind` requires the complete task ID; retrieve it through
`task_list`, `review_list`, the task page, or the API. The agent-facing `task_bind` and `task_unbind` tools are separate:
`task_bind` requires the full task ID plus explicit channel and thread identifiers; `task_unbind` requires only the full
task ID and removes all bindings for that task.

Thread replies route to a bound task session before ordinary session routing. See [Tasks](../tasks.md#agent-tool-surface)
for the command, tool, and API forms.

## Governance Tuning Guide

### Model Routing

`governance.crowd_coding.model` and `.effort` set the default for group turns. Session, channel, group, or task settings
can supply a more specific model where documented. Keep one economical default and override only requests that need a
stronger model.

### Per-Group Configuration

Structured allowlist entries can name a group and tune its model or effort:

```yaml
channels:
  google_chat:
    group_allowlist:
      - id: spaces/AAABBBCCC
        name: Engineering Room
        model: sonnet
        effort: medium
      - spaces/DDDEEEFFF
```

Plain string entries remain valid. Channel-specific group identifiers are documented in the Google Chat, WhatsApp, and
Signal guides.

### Rate Limits

`governance.rate_limits.per_sender` prevents one participant from filling the queue, while
`governance.rate_limits.global` caps total turn starts. Admin senders and bridge-reserved text commands (`/stop`,
`/pause`, `/resume`, `/bind`, and `/unbind`) are exempt from the per-sender check; review requests and the Google Chat
`/new`, `/reset`, and `/status` commands receive no bridge exemption. Rate-limit state is in memory and resets when the
server restarts.

`governance.queue_strategy: fair` drains one queued item per sender in rotation. Use
`per_sender.max_queued` and `max_pause_queued` to bound how much of either queue a participant can occupy.

### Token Budget

`governance.budget.daily_tokens` bounds daily use in the configured timezone. `action: block` prevents new turns after
the budget is exhausted; `action: warn` records the limit without stopping new turns. An in-flight turn may finish past
the threshold because enforcement occurs before the next turn starts.

### Loop Detection

`governance.loop_detection` bounds repeated autonomous activity. Use `action: abort` for a workshop where cost control
matters, and `warn` only when a facilitator is actively monitoring the session.

### Admin Senders

List facilitator identities under `governance.admin_senders`. An empty list grants administrator command access to all
participants, which is suitable only for a small trusted room. Google Chat identities use the `users/<numeric-id>` form.

## Customization Tips

- Increase a provider's `pool_size` only when the session needs concurrent task or logical-agent capacity.
- Use project bindings to keep workshop work out of DartClaw's own workspace.
- Use `attach_media` when the agent needs to send an existing workspace file to a configured channel recipient.
- Keep the shared session short enough to remain coherent; use `/reset` between unrelated exercises.
- Run isolated code changes through a task or workflow that explicitly requests a worktree.

## Provider Configuration for Codex

Codex provider settings are instance policy, not crowd-coding syntax. Configure the provider under `providers.codex`
and choose the desired approval and sandbox policy for the deployment. See [Configuration](../configuration.md) and
[Security](../security.md) before exposing a shared room.

## Gotchas & Limitations

- Crowd coding is supported but intentionally opt-in. A shared sender population has authority over one agent and often
  one workspace; use allowlists, guards, and administrator identities.
- A shared session does not provide per-contribution rollback. Use an explicit worktree-backed task or workflow when
  changes must be isolated.
- `/bind` needs a full task ID and a supported thread context. It does not resolve an ID prefix.
- Task review-ready notifications on WhatsApp and Signal do not currently include a prescribed call to action. Teach
  participants to ask the agent for pending reviews or use the task UI; do not rely on notification wording.
- Per-sender and global rate-limit counters reset at restart.
- Workspace git sync covers the configured workspace, not every project directory.
- Provider capacity is shared by group turns, tasks, and workflows; a full pool queues later work.
