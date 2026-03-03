# Use-Case Cookbook

Practical workflow guides for common DartClaw automation patterns. Each use-case is self-contained with copy-pasteable configuration, behavior file examples, and step-by-step workflow descriptions.

## Prerequisites

- DartClaw installed and running (see [Getting Started](../getting-started.md))
- Basic familiarity with `dartclaw.yaml` configuration (see [Configuration](../configuration.md))
- Workspace behavior files set up (see [Workspace](../workspace.md))

## Decision Tree

**What do you want to do?**

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

## Use-Cases

| # | Name | Features Used | Complexity |
|---|------|---------------|------------|
| 1 | [Morning Briefing](01-morning-briefing.md) | Cron scheduling, MEMORY.md, WhatsApp/web delivery, search agent | Low |
| 2 | [Daily Memory Journal](02-daily-memory-journal.md) | Cron scheduling, HEARTBEAT.md, memory consolidation, git sync | Low |
| 3 | [Scheduled Task Queue](03-scheduled-task-queue.md) | Multiple cron/interval jobs, HEARTBEAT.md, delivery modes | Low |
| 4 | [Knowledge Inbox](04-knowledge-inbox.md) | Search agent, content-guard, memory_save, cron scheduling | Medium |
| 5 | [Contact/CRM Tracker](05-contact-crm-tracker.md) | WhatsApp DM allowlist, memory_save, memory search | Medium |
| 6 | [Research Assistant](06-research-assistant.md) | Search agent (tool policy cascade), memory, web UI | Medium |
| 7 | [Nightly Reflection](07-nightly-reflection.md) | Cron scheduling, errors.md, learnings.md, memory_save | Low |

## Shared Patterns

See [Common Patterns](_common-patterns.md) for reusable templates and testing guides shared across use-cases.
