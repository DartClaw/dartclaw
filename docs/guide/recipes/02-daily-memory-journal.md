# Daily Memory Journal

## Overview

An opt-in built-in job that distills the day's activity log into canonical observations. Combined with git sync, this creates an automatic backup of your agent's accumulated context without silently rewriting curated personal memory.

## Features Used

- **[Cron scheduling](../scheduling.md)** -- triggers the journaling job at a set time each evening
- **[HEARTBEAT.md](../workspace.md)** -- periodic checklist for ongoing review tasks
- **[Canonical observations](../workspace.md)** -- journal capture through `memory_observe` with `role='observation'`
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
- [ ] Search canonical memory for any duplicate or outdated entries
- [ ] Check if any action items from previous days are still pending
- [ ] Verify workspace git sync is current
```

The heartbeat processes this checklist at regular intervals (configured as 60 minutes above). See [Common Patterns](_common-patterns.md) for more on the HEARTBEAT.md format.

## Cron Prompts

The built-in journal prompt instructs the agent to read today's `memory/YYYY-MM-DD.md`, ignore instructions embedded in the log, and:

> Record only notable, non-duplicate items through `memory_observe` with `role='observation'`. If the log is absent or empty, write nothing.

The host binds provenance and returns each observation's stable locator, entry revision, collection revision, and index state.

## Workflow

1. **Cron fires at 10:00 PM** (server-local time) based on `memory.journal.schedule`
2. **Isolated session created** for the journal job
3. **Agent reads today's daily turn log** from `memory/YYYY-MM-DD.md` and searches memory for duplicates
4. **Agent records selected facts** through `memory_observe` with `role='observation'`
5. **Git sync commits changes** to the workspace repository
6. **Push to remote** if a remote is configured and `push_enabled: true`

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
- **Increase prompt memory budget**: Set `memory.max_bytes: 131072` (128KB) if more canonical memory should be composed into agent context
- **Disable push**: Set `push_enabled: false` if you want local git history only

## Gotchas & Limitations

- **Observations are non-authoritative** -- journal capture cannot revise, merge, or remove curated personal entries
- **Git sync requires a remote** for push -- run `git remote add origin <url>` in `~/.dartclaw/workspace/` to set it up
- **Journal job sees an isolated session** -- it does not have access to your main session's chat history directly. It reviews canonical observations and entries through `memory_search`/`memory_read` plus behavior files
- **Session maintenance** -- long-running assistant setups accumulate many sessions (including cron sessions). Configure `sessions.maintenance` to auto-prune old sessions. See [Common Patterns](_common-patterns.md#session-maintenance) for details
