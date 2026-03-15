# Research Assistant

## Overview

An interactive research workflow powered by the search agent and memory system. Ask research questions via the web UI, and the agent searches the web, synthesizes findings, and saves them to memory for future reference. Persistent memory means previous research informs future queries.

## Features Used

- **[Search agent](../search.md)** -- performs web searches with `WebSearch` and `WebFetch` via the tool policy cascade
- **[Content-guard](../security.md)** -- scans search results at the agent boundary for safety
- **[MEMORY.md](../workspace.md)** -- stores research findings persistently via `memory_save`
- **[Memory search](../search.md#memory-search)** -- retrieves previous research via FTS5 (or QMD hybrid search)
- **[Web UI](../web-ui-and-api.md)** -- interactive chat interface for research sessions

## Configuration

Add this to your `dartclaw.yaml`:

```yaml
data_dir: ~/.dartclaw

agent:
  model: sonnet
  max_turns: 100
  agents:
    search:
      tools: [WebSearch, WebFetch]
      model: haiku
      max_concurrent: 2
      max_response_bytes: 5242880

guards:
  content:
    enabled: true
    model: claude-haiku-4-5-20251001

memory_max_bytes: 65536

sessions:
  idle_timeout_minutes: 480           # long timeout for research sessions
  maintenance:
    mode: enforce
    prune_after_days: 90

scheduling:
  heartbeat:
    enabled: true
    interval_minutes: 30
```

## Behavior Files

### SOUL.md

```markdown
You are a research analyst who finds, synthesizes, and organizes information.

## Expertise
- Breaking complex questions into searchable sub-queries
- Evaluating source credibility and cross-referencing claims
- Synthesizing information from multiple sources into coherent summaries
- Building on previous research stored in MEMORY.md

## Research Process
When asked a research question:
1. Check MEMORY.md for any previous research on this topic
2. Break the question into 2-3 specific search queries
3. Use the search agent to find relevant sources
4. Cross-reference findings across multiple sources
5. Synthesize a clear, structured answer
6. Save key findings to MEMORY.md for future reference

## Communication Style
- Lead with the answer, then provide supporting evidence
- Cite sources with URLs
- Flag uncertainty or conflicting information explicitly
- Use structured headings for multi-part answers
```

### AGENTS.md

```markdown
## Search Agent Behavior
- The search agent has access to WebSearch and WebFetch only
- Prefer authoritative sources (official docs, academic papers, established media)
- Do not follow links to file downloads or executable content
- If a search returns no useful results, try alternative search terms before reporting failure
```

## Cron Prompts

This use-case is interactive (driven by user questions in the web UI), not cron-driven. However, you can add a scheduled research job for recurring topics:

```yaml
scheduling:
  jobs:
    - id: weekly-research-update
      prompt: >
        Review the research topics in MEMORY.md. For each topic researched in
        the last 7 days, search for any new developments or updates. Save new
        findings and note any changes from previous research.
      schedule:
        type: cron
        expression: "0 9 * * 1"
      delivery: announce
```

## Workflow

1. **User opens web UI** and starts a new session or continues an existing one
2. **User asks a research question** (e.g., "Compare Dart shelf vs dart_frog for HTTP servers")
3. **Agent checks MEMORY.md** for previous research on the topic
4. **Agent breaks the question** into specific search queries
5. **Agent spawns search agent** to perform web searches
6. **Content-guard scans results** at the agent boundary -- unsafe content is blocked
7. **Agent synthesizes findings** from multiple sources into a structured answer
8. **Agent saves key findings** to MEMORY.md via `memory_save` for future reference
9. **User follows up** with clarifying questions in the same session -- the agent builds on its previous answer and saved research

## Customization Tips

- **Use a more capable search model**: Change `agents.search.model` to `sonnet` for complex research requiring better synthesis (higher cost per search)
- **Increase search concurrency**: Set `max_concurrent: 4` for faster parallel searches (uses more API calls)
- **Add topic focus**: Edit SOUL.md's "Research Process" to prioritize certain source types (e.g., "prefer peer-reviewed papers" or "focus on official documentation")
- **Enable QMD hybrid search**: Add `search.backend: qmd` for semantic memory retrieval -- better for finding conceptually related previous research
- **Add research templates**: Include structured templates in TOOLS.md for common research formats (comparison tables, literature reviews, technical evaluations)
- **Connect a messaging channel**: Add WhatsApp, Signal, or Google Chat so you can ask research questions on the go -- the agent uses the same search agent and memory. With `task_trigger` enabled (0.9+), send `task: research <topic>` to create a background research task

## Gotchas & Limitations

- **Search agent tool budget**: Each search agent turn has a limited number of tool calls. Complex queries may require follow-up questions to cover all angles
- **Content-guard filtering**: Some web content may be partially filtered by the content-guard. The agent will note when results seem incomplete
- **No permanent document storage**: Research is stored as text in MEMORY.md, not as separate files or PDFs. For large research projects, consider increasing `memory_max_bytes`
- **Web content is ephemeral**: URLs found during research may become unavailable later. The agent saves summaries, not cached copies of web pages
- **Search model matters**: The default Haiku model for the search agent is fast and cheap but less capable at complex synthesis. Upgrade to Sonnet for research requiring nuanced understanding
- **Memory consolidation may restructure entries**: Heartbeat consolidation merges duplicate entries. Research findings saved across multiple sessions may be consolidated into a single entry
