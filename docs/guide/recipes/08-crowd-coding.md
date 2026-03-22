# Recipe 8: Crowd Coding

## Overview

Crowd coding lets a group of people collaboratively steer one DartClaw agent to build software together. Participants send instructions and feedback through a Google Chat Space; the agent creates tasks, writes code in isolated git worktrees, and posts results back to the Space for review. Facilitators can control the session with slash commands (`/stop`, `/pause`, `/resume`) and tune governance settings to match group size and session duration.

This recipe is designed for workshop organizers, hackathon facilitators, and teams who want to run structured coding sessions with a shared AI agent.

## Features Used

- [Google Chat Spaces](../google-chat.md) -- receives messages from all Space members
- [Channel-to-task triggers](../tasks.md) -- `task:` prefix creates a coding task from a message
- [Task orchestration](../tasks.md) -- parallel task execution with accept/reject review cycle
- Governance -- rate limits, token budgets, loop detection, and emergency controls (see [Configuration](../configuration.md))
- Thread binding -- task notification threads become the review channel for that task
- Emergency controls -- `/stop`, `/pause`, `/resume` for session management
- [Session scoping](../configuration.md) -- all Space participants share one session
- [Input sanitizer / content guard](../security.md) -- filters inbound messages for safety

## Prerequisites

- DartClaw 0.12+ installed and running (see [Getting Started](../getting-started.md))
- Google Cloud project with Chat API enabled (see [Google Chat setup](../google-chat.md))
- A Google Chat Space (not a group DM) -- [create one here](https://chat.google.com)
- GCP service account configured for the DartClaw Chat bot

Note: Thread binding (task follow-up via reply threads) only works in Google Chat Spaces. Governance features (rate limits, budgets, loop detection) work on all channels.

## Configuration

Add this to your `dartclaw.yaml`:

```yaml
data_dir: ~/.dartclaw

agent:
  model: sonnet
  max_turns: 100

# Governance -- rate limits, budgets, loop detection, emergency controls
governance:
  admin_senders:
    - "users/123456789012345"           # facilitator's Google Chat user ID
    # - "users/987654321098765"         # co-facilitator (optional)
    # Leave empty to grant all participants admin access (suitable for small trusted groups)
  rate_limits:
    per_sender:
      messages: 10                      # max 10 messages per 5-minute window per person
      window: 5m
    global:
      turns: 30                         # max 30 agent turns per hour across all participants
      window: 1h
  budget:
    daily_tokens: 500000                # 500K tokens for a ~2-hour workshop
    action: block                       # block new turns when budget exhausted
    timezone: "America/New_York"        # budget resets at midnight in this timezone
  loop_detection:
    enabled: true
    max_consecutive_turns: 5
    max_tokens_per_minute: 10000
    velocity_window_minutes: 2
    max_consecutive_identical_tool_calls: 5
    action: abort                       # abort turn + fail task when loop detected

# Thread binding -- replies in task notification threads go to that task's session
features:
  thread_binding:
    enabled: true

# Google Chat Space configuration
channels:
  google_chat:
    enabled: true
    service_account: ${GOOGLE_CHAT_SERVICE_ACCOUNT}
    group_access: open                  # all Space members can interact
    require_mention: false              # respond to all messages (not just @mentions)
    task_trigger:
      enabled: true
      prefix: "task:"                   # "task: build a login page" creates a task
      default_type: coding
      auto_start: true                  # tasks start immediately without manual approval
    space_events:
      enabled: true                     # receive all Space messages

# All Space participants share one agent session
sessions:
  group_scope: shared

# Task execution
tasks:
  max_concurrent: 5                     # up to 5 parallel tasks

# Security
guards:
  enabled: true
  input_sanitizer:
    enabled: true
  content:
    enabled: true
```

## Behavior Files

Place these in your workspace directory (configured at `data_dir`):

### SOUL.md

```markdown
You are a collaborative coding agent working with a group of people in a shared coding session.

## Your Role
- Receive coding requests from multiple participants in a Google Chat Space
- Create tasks for each request and execute them in isolated branches
- Post results back to the Space for review
- Accept feedback via thread replies and incorporate it into your work

## How Tasks Work
When someone sends "task: <description>", you create a coding task and begin working on it.
Each task runs in an isolated git worktree on its own branch. When complete, you post a summary
to the Space thread. Participants can then reply with:
- "accept" -- merge the changes to main
- "reject" -- discard the changes
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
```

### TOOLS.md

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

1. **Create a Google Chat Space** -- in Google Chat, create a new Space (not a group DM). Give it a name relevant to your coding session.

2. **Add the DartClaw bot to the Space** -- follow the [Google Chat setup guide](../google-chat.md) to create the GCP project, configure the service account, and add the bot to your Space. The bot must be added as a Space member.

3. **Register slash commands in GCP** -- in the GCP Chat app configuration, register these slash commands (this is a manual step that cannot be automated):
   - `/stop` -- immediately halt all in-flight tasks
   - `/pause` -- pause message processing (queue up to 200 messages)
   - `/resume` -- resume processing queued messages
   - `/status` -- show current session state and active tasks
   - `/new` -- start a fresh session (clears history)
   - `/reset` -- archive the current session and start a fresh conversation

4. **Configure DartClaw** -- copy the configuration example above into your `dartclaw.yaml`. Set your Google Chat user ID in `governance.admin_senders` (see [Finding Your Sender ID](#admin-senders) below). Adjust `budget.daily_tokens` and `rate_limits` for your group size.

5. **Set up behavior files** -- copy the SOUL.md and TOOLS.md examples above into your workspace directory. Update TOOLS.md with your actual project details.

6. **Start DartClaw** -- run the server:

   ```bash
   dart run dartclaw_cli:dartclaw serve --port 3000
   ```

7. **Verify the bot responds** -- send a test message in the Space (e.g., "hello"). The bot should acknowledge. If not, check the server logs and confirm `space_events.enabled: true`.

8. **Run your first crowd task** -- a participant sends:

   ```
   task: build a hello world page at /hello that returns "Hello, world!"
   ```

   DartClaw creates a task, starts working in an isolated branch, and posts a notification to the Space with a link to the task in the web UI.

9. **Interact via thread** -- participants can reply directly in the notification thread to give feedback or ask questions. With `features.thread_binding.enabled: true`, all replies in that thread go to the task's session.

10. **Review the result** -- when the agent completes the task, it posts a summary and diff to the thread. Reply with:
    - `accept` -- merges the changes to main and closes the task
    - `reject` -- discards the branch and closes the task
    - `push back: the page should use the project's CSS framework, not inline styles` -- agent revises and resubmits for review

11. **Emergency controls** -- if anything goes wrong, the facilitator (or any admin sender) can use:
    - `/stop` -- immediately aborts all in-flight tasks. Use when the agent is doing something unexpected
    - `/pause` -- queues incoming messages without processing them. Use to buy time while you assess
    - `/resume` -- resumes processing from the queue. Messages sent during pause are delivered in order

## Governance Tuning Guide

### Rate Limits

Adjust `governance.rate_limits` based on your group size. Recommended starting points:

| Group Size | `per_sender.messages` | `per_sender.window` | `global.turns` | `global.window` |
|------------|----------------------|---------------------|----------------|-----------------|
| Small lab (5--10) | 10 | 5m | 30 | 1h |
| Workshop (10--20) | 5 | 5m | 30 | 1h |
| Hackathon (20--30) | 3 | 5m | 20 | 1h |

Rate limit state resets on server restart. Review commands (`accept`, `reject`, `push back`), `/status`, and `/stop` are not rate-limited.

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
    max_consecutive_turns: 5           # abort if agent takes >5 turns without a tool result
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

## Customization Tips

- **Adjust concurrency**: Lower `tasks.max_concurrent` (e.g., 2) to keep sessions focused; raise it (up to 10) for large hackathons with many parallel tracks
- **Warn vs block budget**: Use `action: warn` for exploratory workshops where you want cost visibility without interrupting flow; use `action: block` for budget-constrained events
- **Multi-channel governance**: Add WhatsApp or Signal participants alongside Google Chat -- governance (rate limits, budgets, loop detection) applies across all channels uniformly. Thread binding remains Google Chat Spaces only
- **Scheduled exercises**: Add a `scheduling` block with cron jobs to auto-create tasks at set times (e.g., one task per 30 minutes for a structured workshop exercise)
- **Session maintenance**: For multi-day hackathons, configure `sessions.maintenance` to prune old sessions and keep the workspace clean
- **Disable loop detection for trusted agents**: If running long autonomous tasks in a trusted environment, set `loop_detection.enabled: false` to avoid false positives

## Gotchas & Limitations

- **Thread binding is Google Chat Spaces only**: Replies in notification threads are routed to the task session only in Google Chat Spaces. In DMs, WhatsApp, and Signal, all messages go to the shared group session
- **Slash commands require GCP pre-registration**: `/stop`, `/pause`, `/resume`, `/status`, `/new`, and `/reset` must be manually registered in the GCP Chat app configuration before they work. This cannot be done automatically
- **Empty `admin_senders` = all are admins**: Convenient for small trusted groups, but anyone can run `/stop` in a larger workshop. Add specific user IDs before public events
- **Budget enforcement is pre-turn**: The token budget check happens before a turn starts. An in-flight turn may overshoot the budget by the cost of that single turn
- **Pause queue has a 200-message hard cap**: Messages sent while paused are queued up to 200. Messages beyond that cap are acknowledged with a "queue full" notice and not processed. Use `/stop` instead if you need to halt processing entirely
- **Rate limit state resets on server restart**: Per-sender and global counters are in-memory only. A restart clears all rate limit history -- useful for resetting between sessions, but unexpected during rolling restarts
- **`push back` transitions task to running**: When a participant sends `push back: <feedback>`, the task moves from `review` back to `running` -- it is not a new task. The agent revises the existing work and resubmits for review
- **No contributor dashboard yet**: Per-participant contribution stats and leaderboards are planned for 0.13. Currently, attribution is visible in task metadata (`created_by`) and Google Chat Cards v2 ("Requested by" field)
