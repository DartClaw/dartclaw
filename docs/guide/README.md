# DartClaw User Guide

An experimental, security-conscious AI agent runtime built with Dart. This guide covers installation, configuration, daily use, and extending DartClaw for your workflow.

## Start Here

| If you want to... | Read this |
|---|---|
| Get DartClaw running for the first time | [Getting Started](getting-started.md) |
| Set up a personal assistant with scheduled briefings, journaling, and research | [Personal Assistant Guide](recipes/00-personal-assistant.md) |
| Understand how DartClaw works | [Architecture](architecture.md) |

## Core Guides

| Guide | What it covers |
|-------|---------------|
| [Getting Started](getting-started.md) | Standalone binary install, source-based dev path, first session |
| [Configuration](configuration.md) | `dartclaw.yaml` reference, environment variables, CLI flags |
| [CLI Operations](cli-operations.md) | Connected vs standalone CLI mode, authentication, server detection, headless operations |
| [Workspace](workspace.md) | Behavior files (SOUL.md, AGENTS.md, USER.md, TOOLS.md, MEMORY.md, HEARTBEAT.md), prompt assembly, git sync |
| [Security](security.md) | Guard chain, container isolation, credential proxy, input sanitizer, content guard |

## Features

| Guide | What it covers |
|-------|---------------|
| [Agents](agents.md) | Providers (Claude, Codex), subagent delegation, custom agents, task runners, choosing the right model |
| [Scheduling](scheduling.md) | Heartbeat, cron jobs, delivery modes |
| [Search & Memory](search.md) | Search agent, FTS5/QMD hybrid search, memory consolidation |
| [Tasks](tasks.md) | Task lifecycle, review workflow, coding tasks, worktrees |
| [Workflows](workflows.md) | Writing custom workflows, progressive refinement, YAML field reference, built-in workflows |
| [Projects & Git](projects-and-git.md) | Project directory, git worktrees, branch management, merge strategies |
| [Canvas](canvas.md) | Shareable visual canvas for workshops: share links, projector display, task board, stats |
| [Web UI & API](web-ui-and-api.md) | Interface features, REST API endpoints, SSE streaming |

## Channels

| Guide | What it covers |
|-------|---------------|
| [WhatsApp](whatsapp.md) | GOWA sidecar setup, QR pairing, DM/group access control |
| [Signal](signal.md) | signal-cli setup, registration, sealed-sender, voice verification |
| [Google Chat](google-chat.md) | GCP service account, JWT verification, Cards v2, slash commands |

## Recipes

Ready-to-use workflow recipes with copy-pasteable configs:

| Guide | Description |
|-------|-------------|
| [**Personal Assistant**](recipes/00-personal-assistant.md) | Turnkey setup: briefings + journaling + research + reflection |
| [Morning Briefing](recipes/01-morning-briefing.md) | Daily news/weather delivery |
| [Daily Memory Journal](recipes/02-daily-memory-journal.md) | End-of-day knowledge consolidation |
| [Scheduled Task Queue](recipes/03-scheduled-task-queue.md) | Multi-job automation pipeline |
| [Knowledge Inbox](recipes/04-knowledge-inbox.md) | Automated web monitoring |
| [Contact/CRM Tracker](recipes/05-contact-crm-tracker.md) | WhatsApp/Signal contact management |
| [Research Assistant](recipes/06-research-assistant.md) | Interactive research with persistent memory |
| [Nightly Reflection](recipes/07-nightly-reflection.md) | Self-improvement via error/learning analysis |

See also: [Common Patterns](recipes/_common-patterns.md) | [Troubleshooting](recipes/_troubleshooting.md)

## Extending

| Guide | What it covers |
|-------|---------------|
| [Customization](customization.md) | L1-L5 customization ladder: behavior files to source code |
| [Deployment](deployment.md) | LaunchDaemon, systemd, egress firewall |

## SDK Guide

Building custom agents with DartClaw as a library? See the [SDK Guide](../sdk/quick-start.md).
