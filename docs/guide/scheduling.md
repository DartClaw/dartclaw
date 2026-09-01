# Scheduling

DartClaw supports periodic tasks via the built-in heartbeat job and cron-style job scheduling.

## Heartbeat

The heartbeat is a built-in scheduled job that checks `HEARTBEAT.md` at regular intervals (default: 30 minutes). A
non-empty checklist runs in a session unique to that cycle; a missing, empty, or unreadable checklist skips the fire
entirely -- it is not recorded as a failure and does not consume a retry.

### Configuration

```yaml
scheduling:
  heartbeat:
    enabled: true              # default; takes effect at runtime, no restart
    interval_minutes: 30       # default; requires a restart
```

`enabled` can be flipped at runtime from the Scheduling page or `PATCH /api/config`, in either direction and from either
boot state. `interval_minutes` requires a restart: a scheduled job's schedule is fixed when the job is registered, which
is the same contract the rest of `scheduling.*` already has.

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
2. If present and non-empty, dispatch to a session unique to that cycle, keyed `agent:main:cron:` plus a URI-encoded `heartbeat:<ISO8601>`
3. Otherwise end the fire quietly and stay on schedule

Workspace git sync runs on [its own schedule](workspace.md#git-sync), not on the heartbeat cycle -- turning the
heartbeat off leaves workspace versioning running.

Heartbeat does not curate personal memory. Enable the opt-in `memory-curation` job (`memory.curation.enabled`) when semantic curation is intended; use `memory_observe` for journal-style capture.

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

### Memory curation

`memory.curation.enabled` registers a built-in `memory-curation` prompt job on `memory.curation.schedule` (default
`0 3 * * *`, after the journal's 22:00 default so a run sees that night's observations). It behaves like every other
built-in prompt job: pause and resume it from the Scheduling page, run it on demand with `dartclaw jobs run
memory-curation`, and observe the run in the server logs; the built-in job's delivery is `none` and is not configurable. It keeps no durable run record.

Each fire composes its own prompt from a bounded snapshot of the current corpus, and the entries in that snapshot are
the only ones the run may change. A `memory_apply` call from the run naming any other entry is refused as a whole set,
with the offending operation reporting that its target or source was not in the bounded snapshot — the run cannot
rewrite entries it was never shown. The scope covers only that run: an ordinary `memory_apply` caller is unaffected.

While `memory.curation.enabled` is set, a `scheduling.jobs` entry claiming the `memory-curation` ID is refused at config
load as a duplicate job ID, the same way `memory-journal` is.

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
        description: Review maintenance items and prepare a code change if needed.
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
