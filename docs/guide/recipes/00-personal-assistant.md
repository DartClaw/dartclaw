# Personal Assistant & Knowledge Base

## Overview

A turnkey personal AI assistant that remembers, researches, and reports -- combining DartClaw's core building blocks into a single coherent setup. This composite guide gives you a complete `dartclaw.yaml` and behavior files to get a daily-driver assistant running immediately, with scheduled briefings, knowledge curation, journaling, and self-improvement.

This guide combines patterns from four individual recipes:
- [Morning Briefing](01-morning-briefing.md) -- daily summary delivered to your phone or web UI
- [Daily Memory Journal](02-daily-memory-journal.md) -- end-of-day observation capture
- [Knowledge Inbox](04-knowledge-inbox.md) -- automated web monitoring and curation
- [Nightly Reflection](07-nightly-reflection.md) -- self-improvement via error and learning analysis

Each is documented in detail in its own guide; this one shows how they work together.

## What You Get

| Pillar | Schedule | What It Does |
|--------|----------|-------------|
| Morning Briefing | 7:00 AM daily | Summarizes weather, news, reminders, and pending items |
| Knowledge Inbox | 12:00 PM daily | Searches the web for topics you care about, saves new findings |
| Daily Journal | 10:00 PM daily | Records selected observations from the day's activity |
| Nightly Reflection | 3:00 AM daily | Reviews errors and learnings, detects patterns, saves insights |
| Heartbeat | Every 60 min | Processes maintenance tasks and git sync |

Plus:
- **Interactive research** -- ask questions anytime via web UI or channel; the agent searches the web and builds on previous research
- **Persistent memory** -- everything the agent learns is saved and searchable
- **Git-backed workspace** -- automatic versioning of memory, learnings, and behavior files
- **Channel access** -- reach your assistant from WhatsApp, Signal, or Google Chat (optional)

## A Day in the Life

Here is how the assistant works across a typical 24-hour period:

**3:00 AM – Nightly Reflection.** The agent reviews `errors.md`, retrieves canonical learnings through `memory_search`/`memory_read`, cross-references previous reflections, and saves 3-5 actionable insights. Uses Sonnet for cost efficiency.

**7:00 AM -- Morning Briefing.** The agent reads your USER.md (timezone, location, interests), searches canonical memory for reminders and pending action items, searches the web for weather and news, and delivers a concise briefing via `announce` to your phone (WhatsApp/Signal/Google Chat) or web UI.

**8:30 AM -- You message from your phone.** "What did we decide about the database migration?" The agent searches memory, finds the relevant journal entry from last Tuesday, and responds with context.

**12:00 PM -- Knowledge Inbox.** The agent scans your tracked topics (defined in SOUL.md), searches the web for new developments, evaluates against existing memory to avoid duplicates, and saves genuinely new findings.

**2:15 PM -- Interactive research via web UI.** You ask the agent to compare two libraries. It searches the web, cross-references with previously saved research, and synthesizes a structured comparison. Key findings are saved to memory.

**10:00 PM -- Daily Journal.** The agent reviews the day's context and records selected observations through `memory_observe`. Curated personal memory changes only through an explicit `memory_apply` request.

**Every 60 minutes -- Heartbeat.** Processes the HEARTBEAT.md checklist (check for stale entries, verify git sync, review pending items). Git sync commits and pushes workspace changes.

## Configuration

Copy this complete `dartclaw.yaml` to get started. All four pillars are included -- comment out any you don't need.

```yaml
# DartClaw Personal Assistant
# Usage: dartclaw --config dartclaw.yaml serve
name: Jarvis
data_dir: ~/.dartclaw-assistant

# --- Agent ---
agent:
  model: sonnet
  max_turns: 100
  agents:
    search:
      tools: [WebSearch, WebFetch]
      model: haiku                      # cheap + fast for web lookups

# --- Memory ---
memory:
  max_bytes: 65536                   # 64KB included in composed agent context

# --- Sessions ---
sessions:
  idle_timeout_minutes: 480           # 8-hour timeout for long-running sessions
  dm_scope: per-contact               # separate DM sessions per contact
  group_scope: shared                 # shared session per group
  maintenance:
    mode: enforce
    prune_after_days: 90              # archive sessions older than 90 days
    max_sessions: 500

# --- Workspace ---
workspace:
  git_sync:
    enabled: true
    push_enabled: true                # push to remote (set up git remote first)

# --- Search ---
search:
  backend: fts5                       # or 'qmd' for semantic hybrid search

# --- Scheduling ---
scheduling:
  heartbeat:
    enabled: true
    interval_minutes: 60

  jobs:
    # Pillar 1: Morning Briefing (7 AM daily)
    - id: morning-briefing
      prompt: >
        Prepare my morning briefing. Include:
        1. A brief weather summary for my location (check USER.md for timezone/location)
        2. Any important dates, reminders, or pending action items found with memory_search
        3. A concise news summary on topics I care about (check SOUL.md for interests)
        4. Any overnight reflection insights worth noting
        Format for mobile reading: short paragraphs, bullet points, no headers.
      schedule:
        type: cron
        expression: "0 7 * * *"
      delivery: announce

    # Pillar 2: Knowledge Inbox (12 PM daily)
    - id: knowledge-inbox
      prompt: >
        Run your daily knowledge scan. For each topic in SOUL.md under "## Topics to Track":
        1. Use WebSearch to find recent developments (last 24 hours if possible)
        2. For the most relevant results, use WebFetch to get full content
        3. Use memory_search to evaluate each finding: Is this new? Does it relate to an existing canonical entry?
        4. Record genuinely new and important findings using memory_observe with role='observation'
        5. Skip duplicates or information already in memory
        Format: "[Topic] Brief summary with source URL"
      schedule:
        type: cron
        expression: "0 12 * * *"
      delivery: none

    # Pillar 3: Daily Journal (10 PM daily)
    - id: daily-journal
      prompt: >
        Review today's activity and record notable observations.
        Use memory_observe with role='observation'. Be selective -- only record
        things worth remembering.
      schedule:
        type: cron
        expression: "0 22 * * *"
      delivery: none

    # Pillar 4: Nightly Reflection (3 AM daily)
    - id: nightly-reflection
      prompt: >
        Perform your nightly reflection:
        1. Read errors.md for patterns or recurring issues
        2. Use memory_search and memory_read to retrieve canonical learnings accumulated today
        3. Search canonical memory for previous reflections and recurring themes
        4. Synthesize: What went well? What patterns are emerging? What should change?
        5. Read the current collection revision and add conclusions through
           memory_apply under topic 'reflection'
        Keep analysis concise – 3-5 bullet points. Skip if errors.md is empty and no relevant canonical learnings are found.
      schedule:
        type: cron
        expression: "0 3 * * *"
      delivery: none

    # Optional: Weekly Review (Monday 10 AM)
    - id: weekly-review
      prompt: >
        Summarize this week's activity. Use memory_search and memory_read to review
        the week's canonical observations and reflections. Highlight: key decisions made,
        recurring themes, outstanding action items, and suggested focus areas
        for next week. Read the current collection revision and add the summary
        through memory_apply under topic 'weekly-review'.
      schedule:
        type: cron
        expression: "0 10 * * 1"
      delivery: announce

# --- Guards ---
guards:
  enabled: true
  fail_open: false
  content:
    enabled: true
    model: haiku
  input_sanitizer:
    enabled: true
    channels_only: true               # only scan channel messages; web UI bypasses

# --- Channels (optional -- uncomment what you use) ---
# channels:
#   whatsapp:
#     enabled: true
#     dm_access: pairing
#     task_trigger:                    # create tasks from WhatsApp (0.9+)
#       enabled: true
#       prefix: "task:"
#       auto_start: true
#   signal:
#     enabled: true
#     phone_number: "+1234567890"
#     dm_access: allowlist
#   google_chat:
#     enabled: true
#     service_account: ${GOOGLE_CHAT_SERVICE_ACCOUNT}
#     dm_access: allowlist
```

## Behavior Files

Place these in your workspace directory (`~/.dartclaw-assistant/workspace/` by default).

### SOUL.md

```markdown
# Agent Identity

You are a personal AI assistant and knowledge companion.

## Expertise
- Summarizing information concisely for quick consumption
- Tracking decisions, insights, and action items across conversations
- Researching topics thoroughly and building on prior findings
- Detecting patterns in errors and learnings over time

## Topics to Track
- [Your interests -- e.g., "AI agent frameworks and tooling"]
- [Your domain -- e.g., "Dart language updates"]
- [Your hobbies -- e.g., "Home automation and self-hosting"]

## Communication Style
- Concise and scannable -- optimize for mobile reading when delivering briefings
- Structured with categories and timestamps for journal entries
- Lead with the answer, then supporting evidence for research
- Flag uncertainty explicitly

## Reflection Guidelines
- Focus on actionable insights, not just listing errors
- Look for patterns across multiple days
- Be honest about recurring issues -- flag prominently if the same error appears repeatedly
- Distinguish one-off errors (dismiss) from systematic issues (investigate)

## Curation Standards
- Search canonical memory first and save only genuinely new findings
- Always include source URLs for web-sourced knowledge
- Prefer primary sources over aggregators
- One finding per `memory_observe` call (keeps observations independently identifiable and searchable)
```

### USER.md

```markdown
# User Context
- Name: [Your name]
- Timezone: [e.g., Europe/Berlin (UTC+1/+2)]
- Location: [e.g., Berlin, Germany]
- Preferred depth: Technical summaries, not surface-level news
- Prefers concise, actionable answers

# Goals & Focus Areas
- [Current project or focus -- e.g., "Building a home lab"]
- [Learning goal -- e.g., "Getting better at Dart async patterns"]

# Contact Directory (if using WhatsApp/Signal CRM)
- [Name] ([phone]): [role/context]
```

### HEARTBEAT.md

```markdown
- [ ] Search canonical memory for duplicate or outdated entries
- [ ] Check if any action items from previous days are still pending
- [ ] Verify workspace git sync is current
```

### AGENTS.md

The retrieval-precedence rule is what makes the memory-first lookup in the 8:30 AM scenario actually happen -- without it, agents tend to answer personal-context questions with web search.

```markdown
## Retrieval Precedence
**Memory before web.** Anything about the user, their projects, notes, decisions, or past
conversations: look in memory and the workspace first -- `memory_search`, read the file if you
know it, `Grep` the workspace if you don't. Use web search only when the question is genuinely
about the outside world, or memory came up empty -- and say which it was.

## Search Agent Behavior
- Prefer authoritative sources (official docs, academic papers, established media)
- Do not follow links to file downloads or executable content
- If a search returns no useful results, try alternative terms before reporting failure
```

## Getting Started

1. **Copy the config** above into `~/.dartclaw-assistant/dartclaw.yaml` (adjust `data_dir` to your preference)

2. **Create behavior files** in your workspace:
   ```bash
   mkdir -p ~/.dartclaw-assistant/workspace
   # Copy SOUL.md, USER.md, HEARTBEAT.md, AGENTS.md into that directory
   ```

3. **Edit USER.md** with your name, timezone, location, and interests

4. **Edit SOUL.md** "Topics to Track" with subjects you want the knowledge inbox to monitor

5. **Set up git sync** (optional but recommended):
   ```bash
   cd ~/.dartclaw-assistant/workspace
   git init && git remote add origin <your-repo-url>
   ```

6. **Start the server**:
   ```bash
   dartclaw --config ~/.dartclaw-assistant/dartclaw.yaml serve
   ```

7. **Test a job** -- change one cron job to a short interval, verify it fires, then revert:
   ```yaml
   # Temporarily use an interval for testing:
   schedule:
     type: interval
     minutes: 1
   ```

See [Common Patterns: Cron Testing Guide](_common-patterns.md#cron-testing-guide) for detailed testing steps.

## Customization

### Enable or disable pillars

Comment out any `jobs:` entry you don't need. Each pillar is independent.

### Add a messaging channel

Uncomment the `channels:` section and configure WhatsApp, Signal, or Google Chat. The morning briefing will deliver to connected channels via `announce`. See:
- [WhatsApp setup](../whatsapp.md)
- [Signal setup](../signal.md)
- [Google Chat setup](../google-chat.md)

### Create tasks from your phone (0.9+)

With `task_trigger` enabled on a channel, send messages like `task: Research Dart isolate patterns` from WhatsApp/Signal/Google Chat to create background tasks. Review results with `accept` or `reject` directly from the channel. See the [Scheduled Task Queue](03-scheduled-task-queue.md) guide for more on the task system.

### Adjust memory context and curation

- **Increase memory cap**: Set `memory.max_bytes: 131072` (128KB) if you generate lots of entries
- **Semantic search**: Set `search.backend: qmd` for concept-based retrieval (requires QMD service)
- **Curate duplicates**: read current revisions, then use one explicit `memory_apply` merge operation

### Use a cheaper model for scheduled jobs

Each job accepts per-job `model:` and `effort:` overrides that take precedence over the global `agent.model`. Set `model: haiku` on a job to run it cheaply while interactive chat keeps the more capable global model. See [Agents](../agents.md) for the full model hierarchy.

### Add a contact/CRM tracker

Add the [Contact/CRM Tracker](05-contact-crm-tracker.md) pattern alongside this config. It uses WhatsApp DM messages to extract and track contacts, action items, and follow-ups.

## Going Deeper

### Individual recipe guides

Each pillar is documented in full detail in its own guide -- configuration options, workflow steps, gotchas, and customization tips:

| Guide | What it covers |
|-------|---------------|
| [Morning Briefing](01-morning-briefing.md) | Delivery modes, WhatsApp/Google Chat setup, news source customization |
| [Daily Memory Journal](02-daily-memory-journal.md) | Observation capture and git sync setup |
| [Scheduled Task Queue](03-scheduled-task-queue.md) | Multiple job orchestration, concurrency limits, webhook delivery, task system |
| [Knowledge Inbox](04-knowledge-inbox.md) | Topic tracking, content-guard filtering, duplicate detection |
| [Contact/CRM Tracker](05-contact-crm-tracker.md) | WhatsApp CRM, allowlist management, action item tracking |
| [Research Assistant](06-research-assistant.md) | Interactive research, search agent tuning, QMD hybrid search |
| [Nightly Reflection](07-nightly-reflection.md) | Error analysis, learning patterns, model override |

### Personal AI landscape

DartClaw's memory system uses keyword-based search (FTS5 BM25, with QMD hybrid opt-in). This is a solid foundation, and the architecture is designed for future enhancements. The landscape research (maintained in the project's specs repo) compares DartClaw to systems like Letta, Khoj, Mem0, Zep, Alfred, and PAI -- covering memory tiers (keyword → graph+vector → constitutional), identity systems, behavioral learning, and proactive AI patterns. Future roadmap items (0.11+) include expanded USER.md sections, implicit sentiment scoring, and inbox-drop knowledge ingestion.

### Common patterns

See [Common Patterns](_common-patterns.md) for reusable templates (SOUL.md, HEARTBEAT.md), cron testing, and memory routing.

## Monitoring & Troubleshooting

Once running, verify your assistant is working:

- **Health Dashboard** (`/health-dashboard`) -- server uptime, guard audit log, system status
- **Memory Dashboard** (`/memory`) -- canonical corpus, bounded prompt-index usage, entry counts, and index health
- **Settings** (`/settings`) -- channel connection status, scheduling job list

For detailed monitoring guidance, see [Monitoring Your Assistant](_common-patterns.md#monitoring-your-assistant). For common issues (jobs not firing, announce not delivering, memory conflicts), see [Troubleshooting](_troubleshooting.md).

## Gotchas & Limitations

- **`announce` delivery targets active channel DMs**: `delivery: announce` broadcasts the result to web UI clients (SSE) and pushes it to active DM sessions on registered channels (WhatsApp/Signal/Google Chat). It does not reach contacts that have no active session, and group sessions are skipped. Use `delivery: webhook` for active push to an external endpoint
- **Timezone is server-local**: All cron expressions use the server's timezone. Adjust expressions if your server timezone differs from yours
- **Jobs run in isolated sessions**: Scheduled jobs do not share session state directly; intentionally captured observations remain available through the memory tools. The daily journal cannot read your main session's chat history; it reviews context via behavior files and memory
- **Curation is explicit**: heartbeat and journal jobs do not autonomously revise, merge, or remove personal memory
- **Content-guard may truncate web content**: Large pages fetched by the search agent are filtered by content-guard. The knowledge inbox agent should note when a source was truncated
- **Git sync requires a remote**: Run `git remote add origin <url>` in your workspace directory before enabling `push_enabled`
- **Model override scope**: Jobs default to the global `agent.model` but accept per-job `model:` and `effort:` overrides. Built-in heartbeat callbacks run without an agent turn, so they have no model. To reduce cron costs, set `model:` on individual jobs or lower `agent.model` globally
