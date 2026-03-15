# Daily Memory Journal

## Overview

An end-of-day cron job that consolidates the day's conversations into structured MEMORY.md entries. Combined with git sync, this creates an automatic backup of your agent's accumulated knowledge.

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

memory_max_bytes: 65536

scheduling:
  heartbeat:
    enabled: true
    interval_minutes: 60
  jobs:
    - id: daily-journal
      prompt: >
        Review today's activity and update MEMORY.md with structured entries.
        For each notable item, categorize it as one of: decisions, insights,
        action-items, or learnings. Use the memory_save tool to write entries.
        Include timestamps. Be selective -- only record things worth remembering.
      schedule:
        type: cron
        expression: "0 22 * * *"
      delivery: none

workspace:
  git_sync:
    enabled: true
    push_enabled: true
```

This configuration is modeled after the [`examples/personal-assistant.yaml`](../../../examples/personal-assistant.yaml) pattern, which includes a similar daily-journal and weekly-review setup.

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

The journal prompt (from the config above) instructs the agent to:

> Review today's activity and update MEMORY.md with structured entries. For each notable item, categorize it as one of: decisions, insights, action-items, or learnings. Use the memory_save tool to write entries. Include timestamps. Be selective -- only record things worth remembering.

The agent uses `memory_save` to append entries in MEMORY.md's timestamped format:

```markdown
## decisions
- [2026-03-03 22:00] Chose shelf over dart_frog for HTTP routing

## action-items
- [2026-03-03 22:00] Set up CI pipeline for dartclaw_core
```

## Workflow

1. **Cron fires at 10:00 PM** (server-local time) based on `expression: "0 22 * * *"`
2. **Isolated session created** for the journal job
3. **Agent reviews context** from MEMORY.md and behavior files
4. **Agent writes structured entries** to MEMORY.md via `memory_save`, categorizing insights, decisions, and action items
5. **Heartbeat triggers consolidation** if MEMORY.md exceeds `memory_max_bytes` (64KB in this config) -- the agent deduplicates and reorganizes entries
6. **Git sync commits changes** to the workspace repository
7. **Push to remote** if a remote is configured and `push_enabled: true`

## Customization Tips

- **Adjust journal time**: Change the cron expression -- `0 23 * * *` for 11 PM, `0 22 * * 1-5` for weekdays only
- **Change categories**: Edit the prompt to use different categories (e.g., `bugs`, `ideas`, `meetings`)
- **Add a weekly review**: Add a second job (see `examples/personal-assistant.yaml` for the `weekly-review` pattern):
  ```yaml
  - id: weekly-review
    prompt: "Summarize this week's activity, highlight patterns, and suggest focus areas for next week."
    schedule:
      type: cron
      expression: "0 10 * * 1"
    delivery: announce
  ```
- **Increase memory cap**: Set `memory_max_bytes: 131072` (128KB) if you generate a lot of entries before consolidation
- **Disable push**: Set `push_enabled: false` if you want local git history only

## Gotchas & Limitations

- **`memory_save` appends entries** -- deduplication only happens during memory consolidation in the heartbeat cycle, not during the journal job itself
- **Git sync requires a remote** for push -- run `git remote add origin <url>` in `~/.dartclaw/workspace/` to set it up
- **Journal job sees an isolated session** -- it does not have access to your main session's chat history directly. It reviews context via MEMORY.md and behavior files
- **Consolidation threshold** -- consolidation runs during heartbeat only when MEMORY.md exceeds `memory_max_bytes`. If you set a very high cap, consolidation may never trigger
- **Session maintenance** -- long-running assistant setups accumulate many sessions (including cron sessions). Configure `sessions.maintenance` to auto-prune old sessions. See [Common Patterns](_common-patterns.md#session-maintenance) for details
