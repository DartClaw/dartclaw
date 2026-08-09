# Daily Memory Journal

## Overview

An opt-in built-in job that distills the day's activity log into structured MEMORY.md entries. Combined with git sync, this creates an automatic backup of your agent's accumulated knowledge.

## Features Used

- **[Cron scheduling](../scheduling.md)** -- triggers the journaling job at a set time each evening
- **[HEARTBEAT.md](../workspace.md)** -- periodic checklist for ongoing review tasks
- **[MEMORY.md](../workspace.md)** -- persistent knowledge base where the agent writes journal entries via `memory_save`
- **[Memory consolidation](../search.md)** -- automatic deduplication when MEMORY.md exceeds the size cap
- **[Git sync](../workspace.md#git-sync)** -- commits workspace changes and pushes to a remote

## Configuration

Add this to your `dartclaw.yaml`:

```yaml
data_dir: ~/.dartclaw

agent:
  model: sonnet
  max_turns: 100

memory:
  max_bytes: 65536
  journal:
    enabled: true
    schedule: "0 22 * * *"

scheduling:
  heartbeat:
    enabled: true
    interval_minutes: 60

workspace:
  git_sync:
    enabled: true
    push_enabled: true
```

The journal is disabled by default. [`examples/personal-assistant.yaml`](../../../examples/personal-assistant.yaml) opts in and keeps a user-authored weekly review as a customization example.

## Behavior Files

### SOUL.md

```markdown
You are a knowledge companion that tracks insights, decisions, and action items.

## Expertise
- Identifying key decisions and their rationale
- Extracting actionable items from conversations
- Organizing information into useful categories

## Communication Style
- Structured and consistent
- Use timestamps and categories for all entries
- Prefer bullet points over prose
```

### HEARTBEAT.md

```markdown
- [ ] Review MEMORY.md for any duplicate or outdated entries
- [ ] Check if any action items from previous days are still pending
- [ ] Verify workspace git sync is current
```

The heartbeat processes this checklist at regular intervals (configured as 60 minutes above). See [Common Patterns](_common-patterns.md) for more on the HEARTBEAT.md format.

## Cron Prompts

The built-in journal prompt instructs the agent to read today's `memory/YYYY-MM-DD.md`, ignore instructions embedded in the log, and:

> Save only notable, non-duplicate items through `memory_save`, categorized as decisions, insights, action-items, or learnings. If the log is absent or empty, write nothing.

The agent uses `memory_save` to append entries in MEMORY.md's timestamped format:

```markdown
## decisions
- [2026-03-03 22:00] Chose shelf over dart_frog for HTTP routing

## action-items
- [2026-03-03 22:00] Set up CI pipeline for dartclaw_core
```

## Workflow

1. **Cron fires at 10:00 PM** (server-local time) based on `memory.journal.schedule`
2. **Isolated session created** for the journal job
3. **Agent reads today's daily turn log** from `memory/YYYY-MM-DD.md` and checks MEMORY.md for duplicates
4. **Agent writes structured entries** to MEMORY.md via `memory_save`, categorizing insights, decisions, and action items
5. **The scheduled-job completion check triggers consolidation** after a successful journal run if MEMORY.md exceeds `memory.max_bytes` (64KB in this config) -- the consolidation turn deduplicates and reorganizes entries
6. **Git sync commits changes** to the workspace repository
7. **Push to remote** if a remote is configured and `push_enabled: true`

## Customization Tips

- **Adjust journal time**: Change `memory.journal.schedule` -- `0 23 * * *` for 11 PM, `0 22 * * 1-5` for weekdays only
- **Customize the prompt or categories**: Disable the built-in and add a prompt job under `scheduling.jobs`; user-authored jobs remain the customization path
- **Add a weekly review**: Add a second job (see `examples/personal-assistant.yaml` for the `weekly-review` pattern):
  ```yaml
  - id: weekly-review
    prompt: "Summarize this week's activity, highlight patterns, and suggest focus areas for next week."
    schedule:
      type: cron
      expression: "0 10 * * 1"
    delivery: announce
  ```
- **Increase memory cap**: Set `memory.max_bytes: 131072` (128KB) if you generate a lot of entries before consolidation
- **Disable push**: Set `push_enabled: false` if you want local git history only

## Gotchas & Limitations

- **`memory_save` appends entries** -- the journal turn checks MEMORY.md to avoid repeats but does not deduplicate existing entries; consolidation is a separate turn
- **Git sync requires a remote** for push -- run `git remote add origin <url>` in `~/.dartclaw/workspace/` to set it up
- **Journal job sees an isolated session** -- it does not have access to your main session's chat history directly. It reviews context via MEMORY.md and behavior files
- **Consolidation threshold** -- consolidation is checked after successful scheduled jobs and during heartbeat when MEMORY.md exceeds `memory.max_bytes`. If you set a very high cap, consolidation may never trigger
- **Session maintenance** -- long-running assistant setups accumulate many sessions (including cron sessions). Configure `sessions.maintenance` to auto-prune old sessions. See [Common Patterns](_common-patterns.md#session-maintenance) for details
