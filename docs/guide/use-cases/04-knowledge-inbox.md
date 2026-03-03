# Use-Case 4: Knowledge Inbox

## Overview

An automated knowledge curation system. A cron job periodically searches the web for topics you care about, filters content through the content-guard for safety, and saves relevant findings to memory. You can then search your accumulated knowledge base via the web UI or memory_search.

## Features Used

- [Cron scheduling](../scheduling.md) -- triggers periodic search and curation
- [Search agent](../search.md) -- performs web lookups via WebSearch and WebFetch
- [Content guard](../security.md) -- filters web content before it reaches the agent
- [MEMORY.md](../workspace.md) -- stores curated findings for persistence
- [Memory search](../search.md) -- retrieves stored findings on demand

## Configuration

Add this to your `dartclaw.yaml`:

```yaml
scheduling:
  jobs:
    - id: knowledge-inbox
      prompt: >
        Run your daily knowledge scan. For each topic in SOUL.md under "## Topics to Track":
        1. Use WebSearch to find recent developments (last 24 hours if possible)
        2. For the most relevant results, use WebFetch to get full content
        3. Evaluate each finding: Is this new information? Does it relate to existing MEMORY.md entries?
        4. Save genuinely new and important findings using memory_save with category='knowledge-inbox'
        5. Skip duplicates or information already in memory
        Format each saved entry as: "[Topic] Brief summary of the finding with source URL"
      schedule:
        type: cron
        expression: "0 12 * * *"
      delivery: none

# Search agent config
agent:
  agents:
    search:
      tools: [WebSearch, WebFetch]

# Content guard filters web content (enabled by default)
guards:
  content_guard:
    enabled: true
```

## Behavior Files

### SOUL.md

```markdown
You are a knowledge curator who monitors topics of interest and distills relevant findings.

## Expertise
- Identifying genuinely new or noteworthy information
- Distinguishing signal from noise in web search results
- Summarizing findings concisely with proper attribution

## Topics to Track
- Dart language updates and ecosystem changes
- AI agent frameworks and tooling
- Home server and self-hosting developments
- Security vulnerabilities in common tools

## Curation Standards
- Only save findings that are genuinely new (not already in MEMORY.md)
- Always include the source URL
- Prefer primary sources over aggregators
- One finding per memory_save call (keeps entries atomic and searchable)
```

### USER.md

```markdown
# User Context
- Interests: Software engineering, AI, self-hosting
- Preferred depth: Technical summaries, not surface-level news
- Language: English
```

## Cron Prompts

The prompt is defined in the `dartclaw.yaml` config above. It instructs the agent to:

1. Read SOUL.md for the list of topics to track
2. Search the web for each topic using the search agent
3. Evaluate relevance against existing MEMORY.md entries
4. Save new findings via memory_save with `category='knowledge-inbox'`
5. Skip duplicates and already-known information

## Workflow

1. **Cron fires at 12:00 PM** (server-local time)
2. **Isolated session created** with key `agent:main:cron:knowledge-inbox:<ISO8601>`
3. **Agent reads behavior files** -- SOUL.md for topics, MEMORY.md for existing knowledge
4. **Agent searches each topic** via search agent (WebSearch for discovery, WebFetch for full content)
5. **Content-guard filters** web content for safety before the agent processes it
6. **Agent evaluates findings** against existing memory -- only saves genuinely new information
7. **New findings saved** via memory_save with `category='knowledge-inbox'` and source URLs
8. **Session completes** -- no delivery (findings are stored, not pushed)
9. **User queries later** via web UI chat or memory_search to retrieve accumulated knowledge

## Customization Tips

- **Change frequency**: `0 */6 * * *` runs every 6 hours for more frequent monitoring
- **Add delivery**: Change `delivery: announce` to push a summary of new findings to WhatsApp or web UI
- **Narrow topics**: Be specific in SOUL.md -- "Dart 3.x pattern matching" finds more targeted results than "Dart"
- **Exclude sources**: Add an "Ignore" section to SOUL.md listing domains to skip
- **Search depth**: Add `max_results: 5` to the search agent config to limit per-topic results

## Gotchas & Limitations

- **Content-guard may truncate**: Large web pages are filtered by content-guard. Some content may be partially available. The agent should note when a source was truncated
- **Search agent tool budget**: Each cron turn has a tool call budget. With many topics, the agent may not complete all searches in one run. Prioritize topics in SOUL.md order
- **No real-time monitoring**: This is periodic, not real-time. For time-sensitive topics, increase cron frequency
- **Duplicate detection is heuristic**: The agent checks MEMORY.md for existing knowledge, but may occasionally save similar-but-not-identical findings. Memory pruning (if enabled) handles deduplication over time
- **Web availability**: Search results depend on web access and site availability. Some sources may be temporarily unreachable
