# Recipe 8: Crowd Coding

## Overview

Crowd coding lets a group of people collaboratively steer one DartClaw agent through a Google Chat Space. This recipe supports three session styles:

- **Structured Coding** (Scenarios A & B) -- participants send `task: <description>` to create isolated coding tasks with worktrees, accept/reject review cycles, and thread binding. Changes merge to main (A) or create PRs on an external repo (B)
- **Freeform Ideation** (Scenario C) -- no tasks, no worktrees. The agent works directly on `main` in a shared conversation. Changes are auto-committed and pushed on a heartbeat interval. Lowest friction, best for brainstorming and drafting

All scenarios share governance controls (rate limits, token budgets, loop detection) and emergency commands (`/stop`, `/pause`, `/resume`).

Version 0.14.3 adds four crowd-coding upgrades on top of that baseline: per-context model routing, sender-fair queueing, explicit cross-channel task binding, and an optional advisor observer.

This recipe is designed for workshop organizers, hackathon facilitators, and teams who want to run collaborative sessions with a shared AI agent.

## Features Used

**All scenarios:**
- [Google Chat Spaces](../google-chat.md) -- receives messages from all Space members
- Governance -- rate limits, token budgets, loop detection, and emergency controls (see [Configuration](../configuration.md))
- Model routing -- crowd-coding defaults plus per-scope and per-channel model/effort overrides
- Queue fairness -- sender-aware debounce, per-sender queue caps, and fair scheduling
- Emergency controls -- `/stop`, `/pause`, `/resume` for session management
- [Session scoping](../configuration.md) -- all Space participants share one session
- [Input sanitizer / content guard](../security.md) -- filters inbound messages for safety

**Scenarios A & B (Structured Coding):**
- [Channel-to-task triggers](../tasks.md) -- `task:` prefix creates a coding task from a message
- [Task orchestration](../tasks.md) -- parallel task execution with accept/reject review cycle
- Thread binding -- task notification threads become the review channel for that task
- Cross-channel binding -- `/bind <taskId>` and `/unbind` can attach WhatsApp groups, Signal groups, or Google Chat threads to an existing task session
- Advisor agent -- optional observer that posts structured `[Advisor]` insights to the canvas and bound channels
- Shareable canvas -- standalone live canvas page with share-token links for projected screens and participant phones (0.14.2+)

**Scenario B only (External Repo):**
- [Multi-project support](../configuration.md) -- register external repos as projects; tasks create worktrees from fresh clones, accepted work is pushed as PRs (0.14+)

**Scenario C (Freeform Ideation):**
- Workspace git sync -- auto-commit and push changes on heartbeat interval
- [Heartbeat scheduling](../configuration.md) -- periodic cycle triggers git commit + push

## Prerequisites

- DartClaw 0.14.3+ installed and running (see [Getting Started](../getting-started.md)). 0.12+ works for basic local-repo crowd coding, but model routing, queue fairness, cross-channel binding, and advisor support require 0.14.3
- Google Cloud project with Chat API enabled (see [Google Chat setup](../google-chat.md))
- A Google Chat Space (not a group DM) -- [create one here](https://chat.google.com)
- GCP service account configured for the DartClaw Chat bot
- (Optional) A target git repository for participants to work against. Without one, tasks run against DartClaw's own working directory

Note: Thread binding (task follow-up via reply threads) only works in Google Chat Spaces. Governance features (rate limits, budgets, loop detection) work on all channels.

## Configuration Scenarios

Pick a scenario that matches your session style. Each is a complete `dartclaw.yaml`.

### Scenario A: Structured Coding (Local Repo)

The default crowd coding setup. Participants send `task: <description>` to create isolated coding tasks with worktrees, accept/reject review cycles, and thread binding. Changes merge to the local repo on accept.

```yaml
data_dir: ~/.dartclaw

agent:
  model: sonnet
  max_turns: 100

governance:
  crowd_coding:
    model: sonnet                    # default model for shared crowd-coding group turns
    effort: medium
  queue_strategy: fair              # round-robin across senders instead of pure FIFO
  admin_senders:
    - "users/123456789012345"           # facilitator's Google Chat user ID
    # Leave empty to grant all participants admin access (suitable for small trusted groups)
  rate_limits:
    per_sender:
      messages: 10                      # max 10 messages per 5-minute window per person
      window: 5m
      max_queued: 5                     # cap queued entries per sender (0 = disabled)
      max_pause_queued: 10              # cap paused-queue entries per sender
    global:
      turns: 30                         # max 30 agent turns per hour across all participants
      window: 1h
  budget:
    daily_tokens: 500000                # 500K tokens for a ~2-hour workshop
    action: block                       # block new turns when budget exhausted
    timezone: "UTC-5"                    # UTC-offset only; IANA names not supported        # budget resets at midnight in this timezone
  loop_detection:
    enabled: true
    max_consecutive_turns: 5
    max_tokens_per_minute: 10000
    velocity_window_minutes: 2
    max_consecutive_identical_tool_calls: 5
    action: abort                       # abort turn + fail task when loop detected

features:
  thread_binding:
    enabled: true

advisor:
  enabled: true
  model: sonnet
  effort: medium
  triggers: [periodic, task_review, explicit]
  periodic_interval_minutes: 10
  max_window_turns: 12
  max_prior_reflections: 3

channels:
  google_chat:
    enabled: true
    service_account: ${GOOGLE_CHAT_SERVICE_ACCOUNT}
    group_access: open
    require_mention: false
    task_trigger:
      enabled: true
      prefix: "task:"
      default_type: "coding"
      auto_start: true
    space_events:
      enabled: true

sessions:
  group_scope: shared
  # model: haiku                        # optional scope-level override
  # channels:
  #   googlechat:
  #     model: opus                    # per-channel override beats sessions.model

tasks:
  max_concurrent: 5
  completion_action: accept           # auto-accept completed tasks (skip manual review cycle)

guards:
  enabled: true
  input_sanitizer:
    enabled: true
  content:
    enabled: true
```

### Scenario B: Structured Coding + External Repo (0.14+)

Same task-based workflow as Scenario A, but tasks target an external repository. On accept, the branch is pushed to the remote and a PR is created. Requires DartClaw 0.14+.

Add this `projects:` block to Scenario A's config:

```yaml
# Target repository -- tasks create worktrees from a fresh clone of this repo.
# On accept, the branch is pushed and a PR is created.
projects:
  workshop-repo:
    remote: git@github.com:org/workshop-repo.git
    branch: main
    credentials: github-main              # github-token credential reference
    clone:
      depth: 1                            # shallow clone — faster initial setup
    pr:
      strategy: github-pr                 # accepted tasks create GitHub PRs
      draft: true                         # PRs start as drafts for facilitator review
      labels: [workshop, agent]
```

Everything else (governance, channels, sessions, tasks, guards) stays the same as Scenario A.

Add this optional `canvas:` block when you want a live workshop view outside the authenticated web UI:

```yaml
base_url: https://workshop.example.com

canvas:
  enabled: true
  share:
    default_permission: interact
    default_ttl: 8h
    max_connections: 50
    auto_share: true
    show_qr: true
  workshop_mode:
    task_board: true
    show_contributor_stats: true
    show_budget_bar: true
```

What this enables:
- Agent-created share links like `https://workshop.example.com/canvas/<token>` that work without web UI login
- A projection-friendly standalone canvas page with live SSE updates
- Built-in workshop templates for a task board and stats bar
- An authenticated `/canvas-admin` dashboard page for facilitators with iframe preview and share-link controls

For full canvas configuration, security model, MCP tool reference, and troubleshooting, see the [Canvas guide](../canvas.md).

**Pre-flight checklist** for Scenario B:
- Export `GITHUB_TOKEN` and point a `github-token` credential entry at it
- Verify the token can read and push to the target repository
- Trigger initial clone before the workshop: start the server and create a test task, then verify `GET /api/projects` shows `status: ready`

### Scenario C: Freeform Ideation

No tasks, no worktrees, no accept/reject flow. The agent works directly on `main` in the local workspace as a shared conversation. Everyone talks to the same session; the agent edits files in place. Changes are auto-committed and pushed on a heartbeat interval.

Best for: brainstorming, drafting specs/docs, ideation workshops, exploratory sessions where you want low friction and don't need per-contribution isolation.

```yaml
data_dir: ~/.dartclaw

agent:
  model: sonnet
  max_turns: 100

governance:
  admin_senders:
    - "users/123456789012345"           # facilitator's Google Chat user ID
  rate_limits:
    per_sender:
      messages: 10
      window: 5m
    global:
      turns: 30
      window: 1h
  budget:
    daily_tokens: 500000
    action: warn                        # warn instead of block — don't interrupt ideation flow
    timezone: "UTC-5"                    # UTC-offset only; IANA names not supported
  loop_detection:
    enabled: true
    max_consecutive_turns: 8            # higher threshold — ideation turns can be longer
    max_tokens_per_minute: 15000
    velocity_window_minutes: 2
    max_consecutive_identical_tool_calls: 5
    action: warn                        # warn only — no tasks to fail

channels:
  google_chat:
    enabled: true
    service_account: ${GOOGLE_CHAT_SERVICE_ACCOUNT}
    group_access: open
    require_mention: false              # all messages reach the agent
    task_trigger:
      enabled: false                    # no task creation — just conversation
    space_events:
      enabled: true

sessions:
  group_scope: shared                   # everyone shares one session

# Auto-commit and push workspace changes on every heartbeat cycle
workspace:
  git_sync:
    enabled: true                       # commit changes to local repo
    push_enabled: true                  # push to remote after commit

scheduling:
  heartbeat:
    enabled: true
    interval_minutes: 5                 # commit + push every 5 minutes during active use

guards:
  enabled: true
  input_sanitizer:
    enabled: true
  content:
    enabled: true
```

**How Scenario C works:**
- Every message from the Space goes to the shared session — no `task:` prefix needed
- The agent edits files directly on `main` (no worktree, no branch)
- Every 5 minutes, the heartbeat triggers `WorkspaceGitSync` which runs `git add . && git commit && git push`
- Commit message format: `"DartClaw auto-commit: <ISO8601-timestamp>"`
- `/stop`, `/pause`, `/resume` still work for session control
- There is no accept/reject flow — everything the agent writes goes straight to `main`

**Trade-offs vs. Scenario A/B:**
- Lower friction — no task creation ceremony, no review cycle
- No per-contribution isolation — you can't reject one person's idea without losing others made in the same heartbeat window
- Context accumulates in one session — run `/reset` every 60--90 minutes to prevent degradation
- Commits batch on the heartbeat interval (default 5 min) — at most 5 minutes of work is at risk if the server crashes

## Behavior Files

Place these in your workspace directory (configured at `data_dir`). Pick the SOUL.md that matches your scenario.

### SOUL.md -- Structured Coding (Scenarios A & B)

```markdown
You are a collaborative coding agent working with a group of people in a shared coding session.

## Your Role
- Receive coding requests from multiple participants in a Google Chat Space
- Create tasks for each request and execute them in isolated branches
- Post results back to the Space for review
- Accept feedback via thread replies and incorporate it into your work

## How Tasks Work
When someone sends "task: <description>", you create a coding task and begin working on it.
Each task runs in an isolated git worktree on its own branch, created from a fresh fetch of the
target repository. When complete, you post a summary to the Space thread. Participants can then
reply with:
- "accept" -- pushes the branch to the remote and creates a PR
- "reject" -- discards the changes
- "push back: <feedback>" -- revise the implementation based on feedback

## Working in a Group
- Multiple people may be working with you simultaneously
- Each task is independent and runs in its own isolated environment
- The facilitator can use /stop, /pause, and /resume to control the session
- If you receive conflicting instructions, proceed with the most recent task request

## Communication Style
- Be concise -- participants are reading in a chat interface
- When a task is complete, summarize what you built in 2-3 sentences
- Proactively flag blockers (missing context, ambiguous requirements)
- On push back, acknowledge the feedback and explain your revised approach

## Git Discipline
- After completing any code change, always commit with a clear, descriptive message
- If the project has a remote configured, push your branch after committing
- Do not wait to be asked to commit -- treat committing as part of completing work
```

### SOUL.md -- Freeform Ideation (Scenario C)

```markdown
You are a collaborative ideation agent working with a group of people in a shared brainstorming session.

## Your Role
- Receive ideas, feedback, and direction from multiple participants in a Google Chat Space
- Work directly on files in the workspace — drafting docs, specs, notes, or code as the group directs
- Synthesize input from multiple people into coherent output
- Build on previous discussion — reference earlier points by participant name when possible

## How This Session Works
Everyone talks to you in the same shared conversation. There are no tasks — you work on files directly.
Your changes are auto-committed and pushed to the remote on a regular interval (every few minutes).
There is no accept/reject flow — what you write goes straight to main.

## Communication Rules
- Be concise — participants are reading in a chat interface
- Acknowledge each participant's contribution
- When directions conflict, call out the conflict and ask the group to decide
- When the group converges on an idea, draft structured output immediately
- Flag when you're about to make a significant change to an existing file

## Git Discipline
- After making file changes, commit with a clear descriptive message
- If the project has a remote, push after committing
- Do not wait to be asked to commit -- treat it as part of completing work
- Note: workspace auto-commit (heartbeat) only covers behavioral files in the data directory,
  not the project directory. If they are separate, you must commit project changes yourself

## Output Style
- Prefer creating new files over modifying existing ones during ideation (easier to discard)
- Use clear file names that reflect the content: ideas-auth-flow.md, spec-user-model.md
- Mark assumptions explicitly: "[Assumption: ...]"
- Keep drafts rough — polish comes later
```

### TOOLS.md (all scenarios)

```markdown
# Project Context

## Repository
<!-- Replace with your actual project details -->
- Language: TypeScript / Python / Go (specify)
- Framework: React / FastAPI / Echo (specify)
- Entry point: src/index.ts (specify)
- Test command: npm test (specify)

## Conventions
- Branch naming: dartclaw/task-<id>
- Commit style: conventional commits (feat:, fix:, chore:)
- Code style: follow existing patterns in the repo

## Key Files
<!-- Add paths to important files participants will likely reference -->
- README.md -- project overview
- src/ -- main source code
- docs/ -- documentation
```

## Workflow

Steps 1--7 are common to all scenarios. Steps 8+ differ by scenario.

### Setup (all scenarios)

1. **Create a Google Chat Space** -- in Google Chat, create a new Space (not a group DM). Give it a name relevant to your coding session.

2. **Add the DartClaw bot to the Space** -- follow the [Google Chat setup guide](../google-chat.md) to create the GCP project, configure the service account, and add the bot to your Space. The bot must be added as a Space member.

3. **Register slash commands in GCP** -- follow the canonical slash-command setup in the [Google Chat guide](../google-chat.md#slash-commands). Crowd-coding sessions should register all 6 DartClaw slash commands with IDs 1-6: `1 /new` (typed task creation), `2 /reset` (session reset between exercise blocks), `3 /status`, `4 /pause`, `5 /resume`, and `6 /stop`.

4. **Configure DartClaw** -- copy the config for your chosen scenario into your `dartclaw.yaml`. Set your Google Chat user ID in `governance.admin_senders` (see [Finding Your Sender ID](#admin-senders) below). Adjust `budget.daily_tokens` and `rate_limits` for your group size.

5. **Set up behavior files** -- copy the matching SOUL.md and TOOLS.md into your workspace directory. Update TOOLS.md with your actual project details.

6. **Start DartClaw** -- run the server:

   ```bash
   dartclaw serve --port 3000
   ```

7. **Verify the bot responds** -- send a test message in the Space (e.g., "hello"). The bot should acknowledge. If not, check the server logs and confirm `space_events.enabled: true`.

### Running the session: Scenarios A & B (Structured Coding)

8. **Run your first crowd task** -- a participant sends:

   ```
   task: build a hello world page at /hello that returns "Hello, world!"
   ```

   DartClaw creates a task, starts working in an isolated branch, and posts a notification to the Space. If `canvas.enabled` is on, the facilitator can project `/canvas-admin` or share a public `/canvas/<token>` link for live task-board visibility without web UI login.

9. **Interact via thread** -- participants can reply directly in the notification thread to give feedback or ask questions. With `features.thread_binding.enabled: true`, all replies in that thread go to the task's session.

10. **Review the result** -- when the agent completes the task, it posts a summary and diff to the thread. Reply with:
    - `accept` -- for project-backed tasks (Scenario B): pushes the branch to the remote and creates a PR (URL shown in the task card). For local tasks (Scenario A): merges changes to main
    - `reject` -- discards the branch and closes the task
    - `push back: the page should use the project's CSS framework, not inline styles` -- agent revises and resubmits for review

### Running the session: Scenario C (Freeform Ideation)

8. **Just talk** -- participants send messages directly in the Space. No `task:` prefix needed. Everyone talks to the same shared session; the agent responds and edits files based on group direction.

   ```
   Let's draft a spec for the user authentication flow. Start with OAuth2 + magic links.
   ```

9. **Watch the workspace** -- the agent edits files directly on `main`. Project the web UI on a shared screen so everyone can see what the agent is working on. Use `git log` to see what's been auto-committed.

10. **Steer and refine** -- participants can redirect, refine, or correct the agent at any time. Since there's no task isolation, messages are processed in order within the shared session. If directions conflict, the agent will flag it.

11. **Periodic reset** -- run `/reset` every 60--90 minutes to start a fresh session. The accumulated context from many participants degrades response quality over time. Changes already committed to git are preserved.

### Emergency controls (all scenarios)

If anything goes wrong, the facilitator (or any admin sender) can use:
- `/stop` -- immediately aborts all in-flight turns/tasks. Use when the agent is doing something unexpected
- `/pause` -- queues incoming messages without processing them. Use to buy time while you assess
- `/resume` -- resumes processing from the queue. Messages sent during pause are delivered in order

### Cross-channel binding (0.14.3+)

When one task should stay visible across multiple channel surfaces, bind the current thread or group to that task session:

```text
/bind <taskId>
/unbind
```

- Google Chat binds the current thread
- WhatsApp and Signal bind the whole group conversation
- Binding is admin-only and idempotent for the same task
- Terminal task states remove all bindings automatically
- API equivalents exist at `GET/POST/DELETE /api/tasks/:taskId/bindings...`

## Governance Tuning Guide

### Model Routing

Model resolution for crowd coding (highest to lowest precedence):

```text
per-group (group_allowlist entry model)
> task configJson['model']
> sessions.channels.<type>.model
> sessions.model
> governance.crowd_coding.model
> agent.model
```

Use `governance.crowd_coding.model` for the default workshop cost/performance profile, then override only where needed. A common pattern is `haiku` for the shared group session, `sonnet` for the advisor, and a stronger task-level override only for difficult tasks.

### Per-Group Configuration

`group_allowlist` entries can be structured maps to set per-group model, effort, and project binding:

**WhatsApp / Signal:**
```yaml
channels:
  whatsapp:
    group_allowlist:
      - id: "120363041234567890@g.us"
        name: "Workshop A"
        model: haiku
        effort: low
      - "120363099999999999@g.us"   # plain string still works
```

**Google Chat:**
```yaml
channels:
  google_chat:
    group_allowlist:
      - id: "spaces/AAABBBCCC"
        name: "Engineering Room"
        model: sonnet
        effort: medium
      - "spaces/DDDEEEFFF"         # plain string still works
```

Groups with a `project` field create tasks in that project instead of the default. Groups without overrides behave identically to plain-string entries. See each channel's config reference for the full field list.

### Rate Limits

Adjust `governance.rate_limits` based on your group size. Recommended starting points:

| Group Size | `per_sender.messages` | `per_sender.window` | `global.turns` | `global.window` |
|------------|----------------------|---------------------|----------------|-----------------|
| Small lab (5--10) | 10 | 5m | 30 | 1h |
| Workshop (10--20) | 5 | 5m | 30 | 1h |
| Hackathon (20--30) | 3 | 5m | 20 | 1h |

Rate limit state resets on server restart. Review commands (`accept`, `reject`, `push back`), `/status`, and `/stop` are not rate-limited.

### Queue Fairness

Use sender fairness when many participants are posting at once.

- `governance.rate_limits.per_sender.max_queued` limits how many queued entries one person can occupy
- `governance.rate_limits.per_sender.max_pause_queued` does the same during `/pause`
- `governance.queue_strategy: fair` drains one sender entry at a time instead of letting one participant monopolize the queue

With `fair`, a backlog like `A,A,A,B,B,C` drains as `A,B,C,A,B,A`.

### Token Budget

Calculate `governance.budget.daily_tokens` based on your session duration and expected task complexity:

- Rough formula: `expected_tasks × avg_tokens_per_task`
- Typical task: 20K--50K tokens (simple feature), 50K--150K tokens (complex feature with tests)
- Recommended defaults:
  - 2-hour workshop: `500000` (500K)
  - Full-day hackathon: `1000000` (1M)

The agent warns participants at 80% budget consumption. At 100%, `action: block` prevents new turns from starting (in-flight turns may overshoot slightly). To extend the budget mid-session without restarting:

```bash
curl -X PATCH http://localhost:3000/api/config \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"governance": {"budget": {"daily_tokens": 1000000}}}'
```

Or use the web UI at `/settings` to adjust the budget live.

Use `action: warn` instead of `block` for exploratory sessions where you want visibility but not hard enforcement.

### Loop Detection

Enable loop detection for workshops to prevent runaway tasks:

```yaml
governance:
  loop_detection:
    enabled: true
    max_consecutive_turns: 5           # abort if agent takes >5 consecutive turns without human input
    max_tokens_per_minute: 10000       # abort if token velocity exceeds this threshold
    velocity_window_minutes: 2
    max_consecutive_identical_tool_calls: 5   # abort if same tool called >5 times in a row
    action: abort                      # abort + fail the task on loop detection
```

- Use `action: abort` for workshops (fail fast, don't waste budget)
- Use `action: warn` for exploration sessions (log and continue, monitor only)
- Disable entirely (`enabled: false`) for long-running autonomous tasks that legitimately need many turns

### Admin Senders

Admin senders can use `/stop`, `/pause`, `/resume`, and `/reset`. To find your Google Chat user ID:

1. Open the web UI at `/settings/channels/google_chat` -- recent message metadata shows sender IDs
2. Or check the server logs when you send a message: look for `sender:` in the channel log output
3. The format is `users/{numeric_id}` (e.g., `users/123456789012345`)

**Security note**: An empty `admin_senders` list grants admin access to all Space participants. This is fine for small trusted groups but a security risk for larger workshops -- add specific IDs before inviting external participants.

Admin sender format by channel (for multi-channel setups):
- Google Chat: `users/{numeric_id}`
- WhatsApp: E.164 phone without `+` + `@s.whatsapp.net` (e.g., `12125551234@s.whatsapp.net`)
- Signal: ACI UUID

### Advisor Agent

The advisor is a soft observer. It never blocks or overrides the main agent.

- `advisor.triggers` controls when it fires: `periodic`, `task_review`, `turn_depth`, `token_velocity`, `explicit`
- `@advisor ...` always triggers an explicit reply in the current thread or group
- Periodic and event-based advisor messages are broadcast to all channels currently bound to the task
- Advisor output is structured as status + observation + optional suggestion, and the same insight can also be pushed to the workshop canvas

## Customization Tips

- **Adjust concurrency**: Lower `tasks.max_concurrent` (e.g., 2) to keep sessions focused; raise it (up to 10) for large hackathons with many parallel tracks
- **Warn vs block budget**: Use `action: warn` for exploratory workshops where you want cost visibility without interrupting flow; use `action: block` for budget-constrained events
- **Multi-channel governance**: Add WhatsApp or Signal participants alongside Google Chat -- governance (rate limits, budgets, loop detection) applies across all channels uniformly. Thread binding remains Google Chat Spaces only
- **Cross-channel task rooms**: Start a task in Google Chat, then use `/bind` from a WhatsApp or Signal group if you want mobile participants to steer the same task session
- **Advisor-only facilitation layer**: Enable `advisor:` plus `canvas:` when you want a facilitator screen that surfaces observer insights without interrupting the primary conversation
- **Target an external repo** (0.14+): Add a `projects:` block to point tasks at a real codebase. Each task creates an isolated worktree from a fresh fetch. On accept, the branch is pushed and a PR is created. Without a `projects:` block, an implicit `_local` project uses DartClaw's working directory -- existing setups work unchanged
- **Dynamic project registration**: Register additional repos at runtime via `POST /api/projects` with the remote URL -- no server restart needed. Useful for hackathons where teams bring their own repos
- **PR strategy**: Set `pr.strategy: github-pr` for GitHub repos (creates draft PRs with configurable labels). Use `pr.strategy: branch-only` for non-GitHub remotes (pushes branch, stores branch name as artifact)
- **Scheduled exercises**: Add a `scheduling` block with cron jobs to auto-create tasks at set times (e.g., one task per 30 minutes for a structured workshop exercise)
- **Session maintenance**: For multi-day hackathons, configure `sessions.maintenance` to prune old sessions and keep the workspace clean
- **Disable loop detection for trusted agents**: If running long autonomous tasks in a trusted environment, set `loop_detection.enabled: false` to avoid false positives

## Provider Configuration for Codex

If using OpenAI models via Codex (`agent.provider: codex`), you **must** configure the approval policy and sandbox mode to avoid silent hangs during tool-use turns. This is caused by an upstream bug in Codex's app-server ([openai/codex#11816](https://github.com/openai/codex/issues/11816)) where tool approval requests block indefinitely when the client can't surface an interactive approval UI.

Add this to your config:

```yaml
agent:
  provider: codex
  model: gpt-4o

providers:
  codex:
    executable: codex
    pool_size: 2
    approval: never              # REQUIRED — prevents approval deadlock on tool-use turns
    sandbox: danger-full-access  # REQUIRED — prevents sandbox-related stalls

credentials:
  openai:
    api_key: ${CODEX_API_KEY}
```

**Why this is safe**: Setting `approval: never` disables Codex's *internal* approval gate, but DartClaw's own defense-in-depth remains fully active: guard chain (command, file, network, content guards), container isolation, `TaskFileGuard`, and input sanitizer all still evaluate every tool call.

**Also recommended for crowd-coding**: Reduce `worker_timeout` to limit blast radius if a turn hangs for any other reason (context compaction, orphaned processes):

```yaml
worker_timeout: 120              # 2 minutes instead of default 10 minutes
```

The default 600s timeout means a single stuck turn blocks the shared session for 10 minutes with no feedback. 120s is a better trade-off for interactive workshops.

## Gotchas & Limitations

- **Thread binding is Google Chat Spaces only**: Replies in notification threads are routed to the task session only in Google Chat Spaces. In DMs, WhatsApp, and Signal, all messages go to the shared group session
- **Bound-channel fan-out is task-scoped**: automatic advisor broadcasts use the task's current bindings. If nothing is bound, DartClaw falls back to the task's originating channel only
- **Slash commands require GCP pre-registration**: `/stop`, `/pause`, `/resume`, `/status`, `/new`, and `/reset` must be manually registered in the GCP Chat app configuration before they work. This cannot be done automatically
- **Empty `admin_senders` = all are admins**: Convenient for small trusted groups, but anyone can run `/stop` in a larger workshop. Add specific user IDs before public events
- **Budget enforcement is pre-turn**: The token budget check happens before a turn starts. An in-flight turn may overshoot the budget by the cost of that single turn
- **Pause queue has a 200-message hard cap**: Messages sent while paused are queued up to 200. Messages beyond that cap are acknowledged with a "queue full" notice and not processed. Use `/stop` instead if you need to halt processing entirely
- **Advisor turns use task-pool capacity**: when every task runner is busy, the advisor skips that trigger instead of queueing behind active work
- **Rate limit state resets on server restart**: Per-sender and global counters are in-memory only. A restart clears all rate limit history -- useful for resetting between sessions, but unexpected during rolling restarts
- **`push back` transitions task to running**: When a participant sends `push back: <feedback>`, the task moves from `review` back to `running` -- it is not a new task. The agent revises the existing work and resubmits for review
- **Project clone happens on first task**: When using `projects:`, the repo is cloned on first use (or server start). Large repos may take time -- verify the clone completes before the workshop starts by creating a test task
- **Auto-fetch cooldown is 5 minutes**: `WorktreeManager` fetches the latest from the remote before creating each worktree, but with a 5-minute cooldown. If someone pushes directly to the remote, it may take up to 5 minutes for DartClaw to see the change
- **GitHub automation uses explicit project credentials**: `github-pr` uses the configured `github-token` credential for clone/fetch/push/PR creation. It does not depend on `gh auth login`, `ssh-agent`, or an unlocked SSH key
- **Credentials are reference-based**: The `credentials:` field in `projects:` is a key name, not the credential itself. GitHub token credentials are injected at clone/push time through a non-interactive `GIT_ASKPASS` flow
- **Scenario C: no per-contribution rollback**: In freeform ideation mode, all agent edits go directly to `main`. You can `git revert` after the fact, but there's no accept/reject flow. This is by design — the low friction is the point
- **Workspace git sync ≠ project git sync**: `WorkspaceGitSync` only auto-commits files in `<data_dir>/workspace/` (behavioral files like SOUL.md, MEMORY.md). If your project directory is separate from the workspace, agent edits to project files are **not** auto-committed. Add "Git Discipline" instructions to SOUL.md (see Behavior Files above) to ensure the agent commits after making changes. For worktree-based tasks (Scenarios A & B), the task completion flow handles commit + push automatically
- **Scenario C: heartbeat = commit interval**: Workspace auto-commits happen every `scheduling.heartbeat.interval_minutes` (default 5 min), not after each turn. This only applies to the workspace directory — project files must be committed explicitly unless the workspace IS the project directory
- **Scenario C: push requires remote**: `workspace.git_sync.push_enabled` only pushes if an `origin` remote exists (`git remote get-url origin`). If the workspace has no remote configured, commits are local-only
- **Codex provider: `approval: never` is required**: Without it, Codex silently hangs on tool-use turns (file creation, shell commands) due to an upstream approval deadlock bug. See [Provider Configuration for Codex](#provider-configuration-for-codex) above
- **Codex stderr is not logged**: Codex error messages (invalid model, API failures) are currently discarded. If Codex turns fail silently, check the Codex process directly or review the OpenAI API dashboard for errors
