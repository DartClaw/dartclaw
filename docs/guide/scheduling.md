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

## Scheduled Task Templates

If you want the scheduler to create reviewable tasks instead of running prompt jobs directly, use `automation.scheduled_tasks`. Each entry creates a normal task template on a cron schedule, so the result goes through the standard `/tasks` review flow.

See [Tasks](tasks.md) for the task lifecycle, worktree behavior, and the `automation.scheduled_tasks` schema.

## Session Maintenance

When configured, session maintenance runs as a built-in scheduled job alongside user-defined cron jobs.

### Configuration

```yaml
sessions:
  maintenance:
    mode: warn               # warn | enforce | disabled
    prune_after_days: 30     # archive inactive sessions (0 = disabled)
    max_sessions: 0          # cap active sessions (0 = unlimited)
    max_disk_mb: 0           # disk budget in MB (0 = unlimited)
    cron_retention_hours: 168 # clean orphaned cron sessions (0 = disabled)
    schedule: "0 3 * * *"   # cron expression (empty = disabled)
```

### Pipeline

Maintenance runs four stages in order:

1. **Prune stale** — archive sessions with no activity for `prune_after_days`
2. **Count cap** — archive the oldest sessions when count exceeds `max_sessions`
3. **Cron retention** — delete cron sessions whose job is no longer configured and older than `cron_retention_hours`
4. **Disk budget** — delete archived sessions to stay within `max_disk_mb`

Protected sessions (main, active channel, active cron) are never pruned.

### Modes

| Mode | Behavior |
|------|----------|
| `warn` | Log what would happen but don't modify sessions |
| `enforce` | Apply archival and deletion |
| `disabled` | Skip maintenance entirely |

### CLI

Run maintenance manually without a running server:

```
dartclaw sessions cleanup           # uses config mode
dartclaw sessions cleanup --dry-run # force warn mode
dartclaw sessions cleanup --enforce # force enforce mode
```

The CLI derives protected sessions from config (enabled channels and configured jobs) so it can run safely offline.
