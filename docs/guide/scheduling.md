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

    - id: remind-dentist              # runs once, then removes its own entry
      schedule:
        type: once
        at: "2026-09-02T15:00:00"     # ISO-8601 instant
      prompt: "Remind me about the dentist"
      delivery: announce
```

A job created, edited or deleted through the `schedule_upsert` tool, the jobs API or the Scheduling page is loaded into
the running server before the write is answered — no restart, and no restart marker. The one exception is a tool
write under `scheduling.mutation.approval: operator`, which is parked until you approve it (below). A hand edit of
`dartclaw.yaml` still needs a restart: file reloads treat the whole `scheduling` section as restart-tier. On a lane
that reads untrusted channel content, turn approval on — or withhold `schedule_upsert` outright via
`agent.disallowed_tools` — see
[Hardening the primary agent for untrusted channels](security.md#hardening-the-primary-agent-for-untrusted-channels).

### Operator approval for tool writes

```yaml
scheduling:
  mutation:
    approval: operator          # none (default) | operator
```

Under `operator`, a `schedule_upsert` call from a model turn is validated exactly as today but not written: the job body
is parked in `<data_dir>/pending-schedule-changes.json` together with who asked (the MCP caller's identity, or the tool
name for the primary lane) and when, and the tool answers `{"id": ..., "pending": true, "changeId": ...}` instead of
`loaded`. Nothing changes in `dartclaw.yaml` or the running scheduler until you settle the change on the Scheduling
page, where a **Pending Changes** section lists every parked write with Approve and Reject buttons. Approve commits the
parked body through the same write path an unparked write takes, so the job is live when the toast appears; Reject
discards it. Both need an admin session. A parked change survives a restart. Approval re-checks only what host state
can have changed since parking — a one-time instant that has since passed, or a job id that has since become a
built-in — and refuses with the reason while leaving the change pending for an explicit Reject.

The pending list shows the full body being authorized: schedule, prompt or task title and description, task acceptance
criteria and auto-start choice, delivery, model, and effort. Parking accepts at most 100 changes or 1 MiB of compact
serialized UTF-8 JSON, whichever is reached first. A full queue refuses the new tool request and preserves every
existing request. A legacy file already over either limit still loads with a warning and remains settleable; new
requests stay refused until settlements bring it within both limits.

Approval removes the pending record durably before reporting success. If that removal fails after the config write,
DartClaw restores the previous `scheduling.jobs` value and reloads the resulting YAML. The error names any rollback or
runtime reload failure instead of claiming that the approval was cleanly rejected.

The mode gates the tool alone. The jobs API and the Scheduling page are authenticated operator surfaces and always
commit directly, whatever the key says. The default `none` keeps every surface as it was.

### One-time jobs

A `once` job fires at a single instant and then removes itself: it is unloaded and its `scheduling.jobs` entry is
deleted, whatever the outcome of that one fire — completed, failed after its retries, skipped because a previous run
was still going, or started on demand. An entry whose instant has already passed when the server composes its jobs
(after downtime, say) is reported as missed in the log and removed rather than warned about at every start.

Through the tool, the API and the page, a one-time job is written by passing `at` instead of `schedule`. Exactly one of
the two is accepted, and `at` must be an ISO-8601 instant in the future.

### Delivery Modes

| Mode | Behavior |
|------|----------|
| `announce` | Result streamed to connected web clients (SSE) and sent to every DM channel session's peer. The text is also recorded in each DM session it reached, so that session's next turn re-reads it from the transcript (that turn starts a fresh provider conversation). |
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
fire. For a recurring job it does not change the timer or pause state, so paused jobs can be tested while remaining
paused. A job created or edited through the API is runnable at once.

Only one execution of a job can run at a time. A second request is rejected, and a scheduled fire that lands while an
on-demand run is active is skipped; the next recurring fire remains on schedule. For a one-time job the on-demand run
*is* its fire: the job is unloaded and its entry removed, so the pending instant never arrives.

### Memory curation

`memory.curation.enabled` registers a built-in `memory-curation` prompt job on `memory.curation.schedule` (default
`0 3 * * *`, after the journal's 22:00 default so a run sees that night's observations). It behaves like every other
built-in prompt job: pause and resume it from the Scheduling page, run it on demand with `dartclaw jobs run
memory-curation`, and observe the run in the server logs; the built-in job's delivery is `none` and is not configurable. It keeps no durable run record.
A refused `memory_apply` change set is logged at WARNING by `MemoryApplyService` with the failure kind and reason (for
every caller, not only this job), so a run that proposes nothing acceptable is visible without reading the model's reply.

Each fire composes its own prompt from a bounded snapshot of the current corpus, and the entries in that snapshot are
the only ones the run may change. A `memory_apply` call from the run naming any other entry is refused as a whole set,
with the offending operation reporting that its target or source was not in the bounded snapshot — the run cannot
rewrite entries it was never shown. The scope covers only that run: an ordinary `memory_apply` caller is unaffected.

While `memory.curation.enabled` is set, a `scheduling.jobs` entry claiming the `memory-curation` ID is refused at config
load as a duplicate job ID, the same way `memory-journal` is.

### Shell jobs

A `type: shell` entry runs a command instead of a model turn. It exists for a credentialed data feed the agent only
reads — a process holding a token that fetches data on a schedule — so the feed lives on the scheduler the deployment
already runs, with the same cron and interval schedules, `enabled`, `retry.*`, failure alerting and on-demand run as
every other job.

```yaml
scheduling:
  jobs:
    - id: mail-feed
      type: shell
      schedule: "*/15 * * * *"
      command:
        - /usr/local/bin/hey
        - mail
        - --json
      env:
        FEED_TOKEN: mail-api-key
      output: mail.json
      timeout_seconds: 60
      retry:
        attempts: 2
        delay_seconds: 30
```

**The command.** `command` is an argument vector, executable first and by absolute path — no shell is involved, so
nothing is quoted, word-split or glob-expanded. There is no `stdin`, no `PATH` knob and no streaming output. The
command runs with the data directory as its working directory.

**The credential.** Each `env` value names a `credentials.<name>` entry — never the secret itself. Only an
`api_key` entry with a non-empty value can be presented; an entry that is absent, is a `github-token`, or resolves to
an empty value is refused, and the whole job is skipped with the reason in the log. The resolved value reaches the
child process and nothing else: it is not written back to `dartclaw.yaml` and never appears in the job's logged
result. The child sees only the named credentials plus a minimal environment (`PATH`, `HOME`, `TZ` and similar) —
the server's own `*_TOKEN`, `*_API_KEY` and `*_SECRET` variables are stripped before the credential is overlaid.

**The output.** `output` is a path under `<data_dir>/feeds/`; an absolute path, or one that escapes `feeds/`, is
refused at parse. On a clean run the command's stdout replaces that file atomically. On POSIX hosts the file is
owner-only; on Windows it inherits the data directory's ACLs. The agent reads it as an ordinary file with `file_read`
– no new permission is needed.

**When a fire fails.** A non-zero exit, a timeout, stdout over 16 MiB, stdout that is not valid UTF-8, an unwritable
output, an exit-0 run whose output pipe another process still holds open two seconds later (a backgrounded helper
with inherited stdio), **and an exit-0 run that wrote nothing to stdout** all fail the fire. Each is retried per `retry.*` and then
raises the usual failure alert, and none of them writes a file: the previous run's feed stays exactly as it was. Zero
bytes is deliberately in that list — a legitimately empty payload is still `[]` or `{}`, and silently replacing a good
feed with an empty file would give the agent an authoritative-looking empty answer with no alert. The logged result of
a good run names the byte count and the exit code, never the document.

`timeout_seconds` defaults to 300. A command that outruns it is terminated (SIGTERM, then SIGKILL) and the fire fails.

**No one-time schedule.** A shell job must be recurring — cron or interval. A one-time (`at:`) job removes its own
entry from `dartclaw.yaml` once its instant is behind it, and a shell entry is the operator's to write and remove, so
`at` on a `type: shell` entry is refused at parse and the entry is not loaded. Every other job kind still takes it.

**File-only.** A `type: shell` entry exists only by editing `dartclaw.yaml`. Every write surface refuses one — the
jobs API, the Scheduling page and the `schedule_upsert` tool — so the kind is unreachable from chat. The Scheduling
page lists a shell job as a run-only row: it can be run on demand, not edited or deleted. Because `scheduling` is a
restart-tier section, a hand edit is applied at the next restart.

**Trust and limits.** The command is operator-declared configuration carrying the same trust as `credentials.*`: no
guard runs over it, and nothing validates what it does. A containerized agent lane does not see the host data
directory, so a feed under `<data_dir>/feeds/` is readable by host-lane agents only; there is no `feeds/` mount
convention for containers.

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
