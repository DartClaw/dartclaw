# Recipes

Practical workflow recipes for common DartClaw automation patterns. Each recipe is self-contained with copy-pasteable configuration, behavior file examples, and step-by-step workflow descriptions.

## Prerequisites

- DartClaw installed and running (see [Getting Started](../getting-started.md))
- Basic familiarity with `dartclaw.yaml` configuration (see [Configuration](../configuration.md))
- Workspace behavior files set up (see [Workspace](../workspace.md))

## Quick Start: Personal Assistant

**Want a ready-to-go personal AI assistant?** Start here:

--> [**Personal Assistant & Knowledge Base**](00-personal-assistant.md) -- a complete, turnkey setup combining daily briefings, knowledge curation, journaling, and self-improvement into one config. Includes a "Day in the Life" walkthrough, combined behavior files, and step-by-step setup.

## Decision Tree

Already know what you want? Pick a specific recipe:

- Want a **daily briefing** delivered to your phone or web UI?
  --> [Morning Briefing](01-morning-briefing.md)

- Want the agent to **journal insights and track learnings** automatically?
  --> [Daily Memory Journal](02-daily-memory-journal.md)

- Want to **automate recurring tasks** on different schedules?
  --> [Scheduled Task Queue](03-scheduled-task-queue.md)

- Want a **knowledge inbox** that monitors sources and saves findings?
  --> [Knowledge Inbox](04-knowledge-inbox.md)

- Want a **contact/CRM tracker** via WhatsApp?
  --> [Contact/CRM Tracker](05-contact-crm-tracker.md)

- Want a **research assistant** with web search and memory?
  --> [Research Assistant](06-research-assistant.md)

- Want a **nightly reflection** that reviews errors and learnings?
  --> [Nightly Reflection](07-nightly-reflection.md)

- Want to run a **crowd coding session** with multiple people steering one agent?
  --> [Crowd Coding](08-crowd-coding.md)

## Recipes

| # | Name | Features Used | Complexity |
|---|------|---------------|------------|
| 0 | [**Personal Assistant**](00-personal-assistant.md) | Combines 1+2+4+7 into turnkey setup | Low |
| 1 | [Morning Briefing](01-morning-briefing.md) | Cron scheduling, MEMORY.md, WhatsApp/Signal/Google Chat delivery, search agent | Low |
| 2 | [Daily Memory Journal](02-daily-memory-journal.md) | Cron scheduling, HEARTBEAT.md, memory consolidation, git sync | Low |
| 3 | [Scheduled Task Queue](03-scheduled-task-queue.md) | Multiple cron/interval jobs, HEARTBEAT.md, delivery modes, task system | Low |
| 4 | [Knowledge Inbox](04-knowledge-inbox.md) | Search agent, content-guard, memory_save, cron scheduling | Medium |
| 5 | [Contact/CRM Tracker](05-contact-crm-tracker.md) | WhatsApp/Signal/Google Chat DM allowlist, memory_save, memory search | Medium |
| 6 | [Research Assistant](06-research-assistant.md) | Search agent (tool policy cascade), memory, web UI | Medium |
| 7 | [Nightly Reflection](07-nightly-reflection.md) | Cron scheduling, errors.md, learnings.md, memory_save | Low |
| 8 | [Crowd Coding](08-crowd-coding.md) | Google Chat Spaces, task triggers, governance, thread binding, emergency controls | Medium |

## Shared Patterns

See [Common Patterns](_common-patterns.md) for reusable templates, cron testing guides, heartbeat vs cron comparison, monitoring guidance, and memory consolidation details shared across recipes.

## Troubleshooting

See [Troubleshooting](_troubleshooting.md) for common issues: jobs not firing, announce not delivering, memory not consolidating, channel problems, and cost optimization.

## Further Reading

- **Personal AI & PKM Landscape Research** -- DartClaw's design draws on research into systems like Letta, Khoj, Mem0, Zep, Alfred, and PAI. Topics include memory tier analysis, identity systems, behavioral learning, and proactive AI patterns. See the [Personal Assistant composite guide](00-personal-assistant.md#going-deeper) for an overview of how these patterns inform DartClaw's architecture
