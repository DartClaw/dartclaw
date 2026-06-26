# Recipe 7: Nightly Reflection

## Overview

A nightly cron job that reviews the day's errors and learnings, synthesizes patterns, and saves actionable insights to memory. Reflection isn't a dedicated feature -- it's a configured use of general-purpose building blocks: cron scheduling + errors.md + learnings.md + memory_save.

## Features Used

- [Cron scheduling](../scheduling.md) -- triggers nightly reflection
- [Self-improvement files](../workspace.md) -- errors.md (auto-populated on failures) and learnings.md (populated via memory_save)
- [MEMORY.md](../workspace.md) -- stores reflection insights for persistence
- [Per-job model selection](../scheduling.md) -- Sonnet recommended for cost-efficient routine analysis

## Configuration

Add this to your `dartclaw.yaml`:

```yaml
scheduling:
  jobs:
    - id: nightly-reflection
      prompt: >
        Perform your nightly reflection:
        1. Read errors.md for any patterns or recurring issues from today
        2. Read learnings.md for insights accumulated today
        3. Cross-reference with MEMORY.md -- are there recurring themes?
        4. Synthesize your analysis:
           - What went well today?
           - What patterns or recurring issues are emerging?
           - What should change in behavior or approach?
        5. Save your conclusions to memory using memory_save with category='reflection'
        Keep your analysis concise -- 3-5 bullet points maximum.
        If errors.md and learnings.md are both empty, skip the reflection and do nothing.
      schedule:
        type: cron
        expression: "0 3 * * *"
      delivery: none

# Sets the global default; a job can override it with a per-job `model:` (and `effort:`) field
agent:
  model: sonnet                  # default for all turns: chat, cron, heartbeat
```

## Behavior Files

### SOUL.md

Add a reflection section to your existing SOUL.md:

```markdown
## Reflection Guidelines
When performing nightly reflection:
- Focus on actionable insights, not just listing errors
- Look for patterns across multiple days (check MEMORY.md for previous reflections)
- Be honest about recurring issues -- if the same error appears repeatedly, flag it prominently
- Distinguish between one-off errors (dismiss) and systematic issues (investigate)
- Keep reflections concise -- the goal is pattern detection, not journaling
```

No dedicated AGENTS.md needed -- the reflection job uses the main agent's standard configuration.

## Cron Prompts

The prompt is defined in the `dartclaw.yaml` config above. It instructs the agent to:

1. Read errors.md for failures, guard blocks, and crashes from the day
2. Read learnings.md for insights accumulated during the day
3. Cross-reference with previous reflections in MEMORY.md
4. Synthesize patterns into 3-5 actionable bullet points
5. Save conclusions via memory_save with `category='reflection'`
6. Skip entirely if both files are empty (no wasted tokens)

## Workflow

1. **Cron fires at 3:00 AM** (server-local time -- chosen to avoid peak usage)
2. **Isolated session created** for the cron job (visible in the web UI sidebar)
3. **Agent reads behavior files** -- SOUL.md for reflection guidelines, MEMORY.md for context
4. **Agent reads errors.md** -- auto-populated by SelfImprovementService on turn failures, guard blocks, and crashes (capped at 50 entries)
5. **Agent reads learnings.md** -- populated via memory_save with `category='learning'` during normal operation
6. **Agent synthesizes patterns** -- cross-references with previous reflections in MEMORY.md
7. **Conclusions saved** to MEMORY.md via memory_save with `category='reflection'`
8. **Session completes** -- no delivery (insights stored for future context)

## Customization Tips

- **Change timing**: `0 23 * * *` runs at 11 PM (same-day reflection). `0 6 * * *` runs at 6 AM (review yesterday before starting)
- **Add delivery**: Set `delivery: announce` to push the reflection summary to WhatsApp, Signal, Google Chat, or the web UI
- **Weekly instead of nightly**: Change to `0 3 * * 0` (Sunday at 3 AM) for weekly reflection with broader pattern analysis
- **Use Opus for deeper analysis**: Add `model: opus` to the job for more thorough reflection without raising the global model (higher cost on that job only)
- **Add git sync**: Set `workspace.git_sync.enabled: true` so reflections are committed alongside other workspace changes during heartbeat
- **Customize error categories**: Update SOUL.md reflection guidelines to prioritize certain error types over others

## Gotchas & Limitations

- **errors.md is capped at 50 entries**: SelfImprovementService trims oldest entries when the cap is reached. If your system generates many errors, older ones may be lost before the nightly reflection runs. Consider running reflection more frequently in high-error environments
- **learnings.md must be explicitly populated**: Unlike errors.md (auto-populated), learnings.md only gets entries when the agent explicitly uses memory_save with `category='learning'`. If your workflow doesn't generate learnings, this file will be empty
- **Empty files = no-op**: The prompt instructs the agent to skip reflection if both files are empty. This is intentional -- no wasted tokens on days with no activity
- **Model inheritance**: A job without a `model:`/`effort:` field inherits the global `agent.model`/`agent.effort`. Set a per-job `model:` to run reflection on a cheaper (or pricier) model than interactive chat
- **Timezone is server-local**: The 3 AM cron uses server time. Adjust for your timezone if the server is in a different location
- **No errors.md cleanup**: The reflection job reads but does not modify errors.md or learnings.md. These files continue to accumulate until their caps are reached or you manually clear them
