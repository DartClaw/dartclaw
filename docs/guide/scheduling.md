# Scheduling

DartClaw supports periodic tasks via the heartbeat scheduler and cron-style job scheduling.

## Heartbeat

The heartbeat scheduler checks `HEARTBEAT.md` at regular intervals (default: 30 minutes). A non-empty checklist creates
an isolated session; missing or empty checklists skip the agent turn while workspace git sync can still run.

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
2. If present and non-empty, dispatch to an isolated session (`agent:main:heartbeat:<ISO8601>`)
3. Attempt to commit workspace changes if git sync is enabled, even when the checklist was missing or empty

Heartbeat does not autonomously curate personal memory. Run the immutable `memory-curation` system action explicitly when semantic curation is intended; use `memory_observe` for journal-style capture.

## Cron Jobs

Schedule recurring tasks with cron expressions, intervals, or one-time triggers.

The canonical job form uses `id:` and a structured `schedule:` block. The parser also
accepts `name:` as a compatibility alias for `id:`, and a bare cron string (e.g.
`schedule: "0 18 * * *"`) as a compatibility alias for `{type: cron, expression: ...}`.
Prefer the canonical form for new configs.

```yaml
scheduling:
  jobs:
    - id: daily-summary              # canonical key; name: is an accepted compatibility alias
      schedule:                      # structured form is canonical; bare string is an alias
        type: cron
        expression: "0 18 * * *"    # 6 PM daily
      prompt: "Summarize today's activity from the daily log"
      delivery: announce             # announce | webhook | none

    - id: health-check
      schedule:
        type: interval
        minutes: 5
      prompt: "Check system health"
      delivery: none
```

### Delivery Modes

| Mode | Behavior |
|------|----------|
| `announce` | Result sent to the active session or default channel |
| `webhook` | Result POSTed to a configured URL |
| `none` | Result logged but not delivered |

### Per-Job Model and Effort Overrides

Individual jobs can override the global `agent.model` and `agent.effort` settings:

```yaml
scheduling:
  jobs:
    - id: daily-summary
      schedule:
        type: cron
        expression: "0 18 * * *"
      prompt: "Summarize today's activity"
      delivery: announce
      model: claude-haiku-3   # override model for cost savings
      effort: low             # override effort level — passed verbatim to provider (Claude: low|medium|high|xhigh|max; Codex: low|medium|high|xhigh)
```

If not specified, the job inherits the global `agent.model` and `agent.effort` values.

Each scheduled job runs in its own session, isolated from user conversations.

### Run a job on demand

Run a configured prompt job immediately from the Scheduling page, the HTTP API, or the CLI:

```bash
dartclaw jobs run daily-summary
```

An on-demand run uses the same isolated cron session, retry policy, delivery mode, and failure alerts as a scheduled
fire. It does not change the job's timer or pause state, so paused jobs can be tested while remaining paused. A job
created or edited through the API requires a server restart before it can run.

Only one execution of a job can run at a time. A second request is rejected, and a scheduled fire that lands while an
on-demand run is active is skipped; the next recurring fire remains on schedule. For a one-time job, a fire skipped in
this window is lost. Outside that window, an on-demand run neither consumes nor cancels its pending one-time fire.

The same run endpoint exposes the immutable `memory-curation` system action. It creates one bounded, isolated proposal turn and lets the host apply the proposal atomically. It has no cron schedule, retry, delivery, pause/toggle state, or YAML form, and its reserved ID cannot be used by a configured job. A second request while it runs is rejected. Failures and conflicts require another explicit request; DartClaw never starts curation from heartbeat, memory size, or job completion.

Job list/show responses join its persisted lifecycle with current index health. A successful canonical commit therefore
remains `succeeded` even when the independent derived index is `degraded`; follow the index repair action instead of
replaying the committed curation.

## Scheduled Task Jobs

To schedule reviewable tasks (instead of prompt jobs that run and deliver immediately), add a job with `type: task` to `scheduling.jobs`. The task goes through the standard `/tasks` review flow when it runs.

```yaml
scheduling:
  jobs:
    - id: daily-maintenance-review
      type: task
      schedule: "0 9 * * 1-5"
      enabled: true
      task:
        title: Daily maintenance review
        task_type: "coding"
        description: Review maintenance items and prepare a coding task if changes are needed.
        acceptance_criteria: Tests stay green and the worktree is ready for review.
        auto_start: true
```

Task jobs identify by `id` (rather than `name`) and do not use the `delivery` or `prompt` fields. See [Tasks](tasks.md) for the task lifecycle, worktree behavior, and the full task job schema.

## Session Maintenance

When configured, session maintenance runs as a built-in scheduled job alongside user-defined cron jobs.

### Configuration

```yaml
sessions:
  maintenance:
    mode: warn               # warn | enforce
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

Set `schedule: ""` to disable automated maintenance entirely.

### CLI

Run maintenance manually without a running server:

```
dartclaw sessions cleanup           # uses config mode
dartclaw sessions cleanup --dry-run # force warn mode
dartclaw sessions cleanup --enforce # force enforce mode
```

The CLI derives protected sessions from config (enabled channels and configured jobs) so it can run safely offline.
