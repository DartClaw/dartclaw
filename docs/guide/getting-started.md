# Getting Started

DartClaw is a security-focused agent runtime for Claude Code. A Dart host coordinates state, security, and the web UI while a native agent CLI handles turns.

## Prerequisites

| Dependency | Version | Purpose |
|-----------|---------|---------|
| Dart SDK | ^3.11.0 | Host runtime |
| `claude` CLI | Latest | Agent binary |
| SQLite | System lib | Search index |

Install Dart, Claude Code, and SQLite:

```bash
brew tap dart-lang/dart && brew install dart
# Agent CLI example (Claude)
curl -fsSL https://claude.ai/install.sh | bash
sudo apt-get install libsqlite3-dev
```

Auth: run `claude login` or `claude setup-token`, or export `ANTHROPIC_API_KEY`.

## Quick Start

```bash
# Clone and install
git clone <repo-url> && cd dartclaw
dart pub get

# Start server
dart run dartclaw_cli:dartclaw serve

# Open http://127.0.0.1:3000
```

## First Session

1. Open [http://127.0.0.1:3000](http://127.0.0.1:3000)
2. Click **New Chat**
3. Type a message, then press **Ctrl+Enter** or **Cmd+Enter** on macOS
4. The agent responds with streaming text via SSE

See `examples/` for ready-made configs such as dev, production, and personal assistant setups.

## Data Storage

```
~/.dartclaw/
  dartclaw.yaml
  workspace/   Behavior files that shape the agent
  sessions/
  logs/
  search.db
```

See [Workspace](workspace.md) for how the behavior files are assembled into prompts and kept in sync.

## What's Next?

- [Workspace](workspace.md) - Learn how behavior files shape the agent.
- [Configuration](configuration.md) - See `dartclaw.yaml`, provider selection, environment variables, and CLI flags.
- [Security](security.md) - Review guard chains, container isolation, and credential handling.
- [WhatsApp](whatsapp.md) - Set up the GOWA-backed WhatsApp channel.
- [Signal](signal.md) - Configure signal-cli and access control.
- [Google Chat](google-chat.md) - Connect Google Chat spaces and slash commands.
- [Scheduling](scheduling.md) - Configure heartbeat and cron-based delivery.
- [Tasks](tasks.md) - Understand task lifecycle and review workflows.
- [Architecture](architecture.md) - Read the 2-layer system overview and protocol flow.
- [Recipes](recipes/) - Browse copy-pasteable workflow examples.
- [Full Guide Index](README.md) - Jump to the full guide catalog.
