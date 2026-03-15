# Common Patterns

Reusable snippets and patterns shared across use-cases. For full details on behavior files, see [Workspace](../workspace.md). For scheduling configuration, see [Scheduling](../scheduling.md).

## SOUL.md Template

A starting template for agent identity. Customize the personality, expertise, and communication style for your use-case.

```markdown
# Agent Identity

You are [role description -- e.g., "a personal assistant", "a system administrator"].

## Expertise
- [Domain expertise relevant to the use-case]
- [Tools and systems you work with]

## Communication Style
- [Tone -- e.g., "concise and actionable", "detailed and thorough"]
- [Format preferences -- e.g., "use bullet points", "include timestamps"]

## Boundaries
- Focus on [primary responsibility]
- Do not [things to avoid]
```

The agent can update SOUL.md over time. It is re-read every turn -- edit live without restarting. See [Workspace](../workspace.md) for prompt assembly order.

### Example: A real daily-driver SOUL.md

Here is a fleshed-out example that goes beyond placeholders:

```markdown
# Agent Identity

You are a personal AI assistant for a software engineer focused on backend systems and developer tooling.

## Expertise
- Dart, Go, and Python development
- System architecture and API design
- Infrastructure: Docker, systemd, Caddy, SQLite
- Security: container isolation, credential management, supply chain

## Topics to Track
- Dart language updates (especially Dart 3.x features, macros progress)
- AI agent frameworks: LangChain, CrewAI, Claude Agent SDK updates
- Self-hosting: Coolify, Traefik, Tailscale announcements
- Security advisories for tools I use (sqlite3, shelf, signal-cli)

## Communication Style
- Technical depth by default -- I understand code, don't oversimplify
- Lead with the answer, then supporting reasoning
- Use code snippets when they clarify faster than prose
- For briefings: bullet points, no headers, mobile-optimized

## Boundaries
- Do not track celebrity news, sports, or entertainment
- Do not generate motivational quotes or filler content
- If unsure about a finding, say so rather than guessing
```

Notice the level of specificity: concrete technologies, explicit exclusions, and formatting preferences. The more specific your SOUL.md, the more useful your assistant becomes.

## HEARTBEAT.md Format

HEARTBEAT.md uses a checklist format. The heartbeat scheduler processes the entire file in a single turn at configured intervals.

```markdown
- [ ] Check server health at https://status.example.com
- [ ] Review error logs from the last hour
- [ ] Summarize any new issues or alerts
```

Key points:
- The agent processes all items in one run -- individual task completion is not tracked between heartbeat runs
- Results are logged but not persisted to the main session
- Missing or empty HEARTBEAT.md is silently skipped
- Default heartbeat interval is 30 minutes (configurable via `scheduling.heartbeat.interval_minutes`)

See [Scheduling](../scheduling.md) for the full heartbeat lifecycle.

## Cron Testing Guide

When setting up scheduled jobs, test with short intervals before deploying with production timing.

### Step 1: Use a short interval for testing

```yaml
scheduling:
  jobs:
    - id: my-job
      prompt: "Test prompt"
      schedule:
        type: interval
        minutes: 1
      delivery: none
```

### Step 2: Enable verbose logging

```yaml
logging:
  level: FINE
```

Check logs for job execution entries to confirm the job fires correctly.

### Step 3: Test delivery modes incrementally

1. Start with `delivery: none` -- verify the job runs and produces output in logs
2. Switch to `delivery: announce` -- verify output appears in active session or channel
3. If using `delivery: webhook`, verify your endpoint is reachable first

### Cron Expression Quick Reference

Cron uses 5-field format: `minute hour day-of-month month day-of-week`

| Pattern | Expression | Description |
|---------|-----------|-------------|
| Daily at 7 AM | `0 7 * * *` | Every day at 07:00 |
| Weekdays at 9 AM | `0 9 * * 1-5` | Monday through Friday at 09:00 |
| Every 30 minutes | `*/30 * * * *` | On the hour and half hour |
| Sunday at 3 AM | `0 3 * * 0` | Weekly maintenance window |
| First of month | `0 8 1 * *` | Monthly at 08:00 on the 1st |

### Step 4: Switch to production timing

Replace the test interval with your target cron expression and set the log level back to `INFO`.

## Memory Consolidation

MEMORY.md is the agent's persistent knowledge base, written via the `memory_save` tool. When MEMORY.md exceeds 32KB (configurable via `memory_max_bytes`), consolidation runs during the next heartbeat cycle -- the agent deduplicates and reorganizes entries automatically.

Key points:
- `memory_save` appends new entries; consolidation merges duplicates
- Consolidation only runs during heartbeat (not during regular sessions)
- Entries are structured as timestamped items grouped by category
- Git sync (if enabled) commits workspace changes after heartbeat

**Note on config layout**: `memory_max_bytes` is a top-level key, while memory pruning settings are nested under `memory.pruning`. These are related but configured separately:

```yaml
# Top-level: consolidation threshold for MEMORY.md
memory_max_bytes: 65536

# Nested: automated memory entry pruning (archive old entries)
memory:
  pruning:
    enabled: true
    archive_after_days: 90
    schedule: "0 3 * * *"
```

See [Search & Memory](../search.md) for search agent integration and memory retrieval.

## Session Maintenance

DartClaw automatically manages session lifecycle when `sessions.maintenance` is configured. This prevents unbounded disk growth from long-running assistant setups.

```yaml
sessions:
  maintenance:
    mode: enforce              # 'warn' logs but does not delete; 'enforce' prunes
    prune_after_days: 90       # archive sessions older than this
    max_sessions: 500          # cap total session count
    max_disk_mb: 0             # 0 = disabled; set a limit for disk-constrained environments
    cron_retention_hours: 24   # keep cron job sessions for this long before pruning
    schedule: "0 3 * * *"      # when to run maintenance
```

Key points:
- Maintenance runs on a cron schedule, separate from heartbeat
- Protected session types (active channels, recent web sessions) are never pruned
- `warn` mode is useful for seeing what would be pruned before committing to `enforce`
- The `dartclaw sessions cleanup` CLI command supports `--dry-run` for manual inspection

See [Configuration](../configuration.md) for full session config reference.

## Channel-to-Task Integration (0.9+)

With `task_trigger` enabled on a channel, users can create background tasks from WhatsApp, Signal, or Google Chat by sending messages with a configured prefix:

```
task: Research Dart isolate performance patterns
task: coding Fix the login page CSS
```

Review completed tasks directly from the channel:
```
accept          (if only one task is in review)
accept abc123   (if multiple tasks are in review)
reject abc123
```

Enable per channel in `dartclaw.yaml`:

```yaml
channels:
  whatsapp:
    task_trigger:
      enabled: true
      prefix: "task:"            # prefix that triggers task creation
      default_type: research     # type when not specified
      auto_start: true           # start immediately or queue as draft
```

See [Scheduled Task Queue](03-scheduled-task-queue.md) for more on the task system.

## Heartbeat vs Cron Jobs

DartClaw has two independent scheduling mechanisms. They serve different purposes:

| | Heartbeat | Cron Jobs |
|---|---|---|
| **Input** | Processes `HEARTBEAT.md` checklist | Runs a specific prompt from `dartclaw.yaml` |
| **Purpose** | Ongoing maintenance (memory consolidation, git sync, checklist review) | Time-of-day tasks with unique prompts (briefings, reports, scans) |
| **Schedule** | Fixed interval (`interval_minutes`) | Cron expression or interval per job |
| **Memory consolidation** | Triggers automatically when MEMORY.md exceeds cap | Does not trigger consolidation |
| **Git sync** | Commits workspace changes after each run | Does not trigger git sync |
| **Delivery** | Results logged only | Configurable: `none`, `announce` (planned), `webhook` |
| **Session** | New isolated session each run | Same session reused per job ID (history accumulates) |

**When to use which:**
- Use **heartbeat** for the "background maintenance loop" -- memory housekeeping, git sync, and recurring checks that don't need specific delivery
- Use **cron jobs** for "things that happen at specific times" -- morning briefings, daily journals, weekly reviews, knowledge scans

They can (and typically do) run together. Heartbeat handles the plumbing; cron jobs handle the content.

## Monitoring Your Assistant

Once your assistant is running, use these built-in tools to verify it's working:

### Web UI dashboards

- **Health Dashboard** (`/health-dashboard`) -- server uptime, guard audit log (recent blocks), system status. Check here first if something seems wrong
- **Memory Dashboard** (`/memory`) -- MEMORY.md size vs budget, entry counts, pruner history, search index status. Useful for verifying that journaling and knowledge inbox jobs are actually writing entries
- **Task Dashboard** (`/tasks`) -- active and completed tasks, review queue. Shows task execution status if you're using the task system
- **Settings** (`/settings`) -- channel connection status, guard configuration, scheduling job list. Verify channels are connected and jobs are registered

### Logs

Enable verbose logging temporarily to debug scheduling issues:

```yaml
logging:
  level: FINE
```

Key log patterns to look for:
- `CronScheduler` -- job firing events
- `HeartbeatScheduler` -- heartbeat cycle events
- `MemoryConsolidation` -- consolidation triggers
- `GitSync` -- commit and push events
- `announce` -- delivery routing decisions

### Agent metrics (0.8+)

The agent metrics API shows per-agent activity:
- `GET /api/agents` -- list all agents with status (idle/busy) and turn counts
- `GET /api/agents/<id>` -- detailed metrics for a specific agent

The `/tasks` page shows an agent overview section with real-time status.

### Periodic health check

Add a simple self-check to your HEARTBEAT.md:

```markdown
- [ ] Verify MEMORY.md has been updated in the last 24 hours
- [ ] Check that the most recent cron session completed successfully
- [ ] Review error counts in errors.md
```

## Troubleshooting

See [Troubleshooting](_troubleshooting.md) for common issues and solutions.
