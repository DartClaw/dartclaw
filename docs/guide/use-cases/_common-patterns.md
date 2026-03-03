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

See [Search & Memory](../search.md) for search agent integration and memory retrieval.
