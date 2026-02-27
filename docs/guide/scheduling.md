# Scheduling

DartClaw supports periodic tasks via the heartbeat scheduler and cron-style job scheduling.

## Heartbeat

The heartbeat scheduler processes `HEARTBEAT.md` at regular intervals (default: 30 minutes). Each run creates an isolated session.

### Configuration

```yaml
scheduling:
  heartbeat:
    enabled: true              # default
    interval_minutes: 30       # default
```

### HEARTBEAT.md Format

Write a checklist of tasks for the agent to process:

```markdown
- [ ] Check server health at https://status.example.com
- [ ] Review error logs from the last hour
- [ ] Summarize any new GitHub issues in #dartclaw
```

The agent processes the entire checklist in a single turn. Results are logged but not persisted to the main session.

### Heartbeat Lifecycle

1. Read `HEARTBEAT.md` from workspace
2. Skip if missing or empty
3. Dispatch to isolated session (`agent:main:heartbeat:<ISO8601>`)
4. Run memory consolidation (if MEMORY.md > 32KB)
5. Git commit workspace changes (if git sync enabled)

## Cron Jobs

Schedule recurring tasks with cron expressions, intervals, or one-time triggers.

```yaml
scheduling:
  jobs:
    - name: daily-summary
      schedule: "0 18 * * *"     # 6 PM daily
      prompt: "Summarize today's activity from the daily log"
      delivery: announce         # announce | webhook | none

    - name: health-check
      schedule:
        every: 5m               # interval shorthand
      prompt: "Check system health"
      delivery: none
```

### Delivery Modes

| Mode | Behavior |
|------|----------|
| `announce` | Result sent to the active session or default channel |
| `webhook` | Result POSTed to a configured URL |
| `none` | Result logged but not delivered |

### Isolated Sessions

Each scheduled job runs in its own session, isolated from user conversations. Session keys follow the pattern `agent:main:cron:<job-name>:<ISO8601>`.
