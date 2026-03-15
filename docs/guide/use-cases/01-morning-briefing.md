# Use-Case 1: Morning Briefing

## Overview

A daily cron job delivers a morning briefing at a configured time. The agent summarizes weather, calendar items, news, or whatever your SOUL.md instructs -- delivered via WhatsApp or the web UI.

## Features Used

- [Cron scheduling](../scheduling.md) -- triggers the briefing at a set time
- [MEMORY.md](../workspace.md) -- provides context persistence between briefings
- [Delivery modes](../scheduling.md#delivery-modes) -- `announce` sends results to the active session or channel
- [Search agent](../search.md) -- enables web lookups for news, weather, etc.
- [Channels](../whatsapp.md) -- optional delivery via WhatsApp, Signal, or [Google Chat](../google-chat.md) (web UI works too)

## Configuration

Add this to your `dartclaw.yaml`:

```yaml
scheduling:
  jobs:
    - id: morning-briefing
      prompt: >
        Prepare my morning briefing. Include:
        1. A brief weather summary for my location (check USER.md for timezone/location)
        2. Any important dates or reminders from MEMORY.md
        3. A concise news summary on topics I care about (check SOUL.md for interests)
        Format for mobile reading: short paragraphs, bullet points, no headers.
      schedule:
        type: cron
        expression: "0 7 * * *"
      delivery: announce

# Search agent for web lookups (defaults are fine)
agent:
  agents:
    search:
      tools: [WebSearch, WebFetch]

# Channel delivery (optional -- web UI works without any of these)
# Uncomment the channel(s) you use:
# channels:
#   whatsapp:
#     enabled: true
#   signal:
#     enabled: true
#     phone_number: "+1234567890"
#   google_chat:
#     enabled: true
#     service_account: ${GOOGLE_CHAT_SERVICE_ACCOUNT}
```

## Behavior Files

### SOUL.md

```markdown
You are a personal assistant who prepares daily briefings.

## Expertise
- Summarizing information concisely for mobile reading
- Tracking personal interests and recurring topics

## Interests to Track
- Technology and AI news
- Local weather and events
- Project deadlines and milestones

## Communication Style
- Concise and scannable -- optimize for reading on a phone
- Use bullet points, not paragraphs
- Lead with the most important items
```

### USER.md

```markdown
# User Context
- Name: [Your name]
- Timezone: Europe/Berlin (UTC+1/+2)
- Location: Berlin, Germany
- Prefers concise answers
```

## Cron Prompts

The prompt is defined in the `dartclaw.yaml` config above. It instructs the agent to:

1. Check USER.md for timezone and location context
2. Use the search agent to look up weather and news
3. Review MEMORY.md for reminders and recurring items
4. Format the output for mobile reading (short, scannable)

## Workflow

1. **Cron fires at 7:00 AM** (server-local time)
2. **Isolated session created** for the cron job (visible in the web UI sidebar)
3. **Agent reads behavior files** -- SOUL.md for personality/interests, USER.md for location, MEMORY.md for context
4. **Agent uses search agent** to look up weather, news, or other web sources
5. **Agent composes briefing** -- concise, mobile-friendly format
6. **Result delivered via `announce`** to the active channel (WhatsApp, Signal, or Google Chat) or web session

## Customization Tips

- **Change the time**: Edit the cron expression. `0 6 * * *` for 6 AM, `0 8 * * 1-5` for weekdays only at 8 AM
- **Add/remove briefing sections**: Edit the prompt in `dartclaw.yaml` to include or exclude topics
- **Switch delivery mode**: Use `delivery: none` to log only (no push notification), or `delivery: webhook` for external integrations
- **Add specific news sources**: Add URLs to TOOLS.md so the agent knows where to look
- **Skip weekends**: Change cron to `0 7 * * 1-5` (Monday through Friday)

## Gotchas & Limitations

- **`announce` delivery is not yet implemented**: `delivery: announce` currently logs the result but does not route it to channels or web sessions. Job results are accessible via cron session history in the web UI sidebar. Use `delivery: webhook` for active push delivery. Channel routing for announce is planned
- **Timezone is server-local**: The cron expression uses the server's timezone, not the user's. If your server is in UTC but you want 7 AM Berlin time, adjust the expression accordingly
- **Search agent results go through content-guard**: Web content is filtered before the agent sees it. Some sources may be partially truncated
- **No state between briefings**: Each cron run is an isolated session. The agent relies on MEMORY.md for continuity, not previous briefing sessions
