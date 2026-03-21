# Getting Started

DartClaw is a security-focused agent runtime for Claude. Dart orchestrator (AOT-compiled, zero npm) drives the native `claude` CLI binary via JSONL control protocol.

Designed for always-on deployment on a Mac Mini or Linux server as a personal AI assistant with web UI, WhatsApp, scheduling, and defense-in-depth security.

## Architecture

```
User --> HTTP/WhatsApp --> Dart Host --> Guards --> claude binary
                            |                        |
                      Guard Chain              Tool execution
                      Audit Logger            Bash, files, MCP
                      Content Guard
```

Two layers with clear trust boundaries:
- **Dart host** -- state, HTTP API, web UI, security, scheduling, channels
- **claude binary** -- agent reasoning, tool execution, bash commands

Communication via bidirectional JSONL over stdin/stdout.

## Prerequisites

### Required

| Dependency | Version | Purpose |
|-----------|---------|---------|
| Dart SDK | >= 3.7.0 | Host runtime + AOT compilation |
| `claude` CLI | Latest | Agent harness (native binary) |
| SQLite | System lib | Search index (pre-installed on macOS/most Linux) |

### Optional

| Dependency | Purpose |
|-----------|---------|
| Docker | Container isolation (`network:none`, `--cap-drop ALL`) |
| GOWA | WhatsApp channel (Go binary, wraps whatsmeow) |
| QMD | Hybrid vector search (opt-in, FTS5 is default) |

### Install

```bash
# Dart SDK (macOS)
brew tap dart-lang/dart && brew install dart

# Claude CLI
curl -fsSL https://claude.ai/install.sh | bash

# SQLite (Debian/Ubuntu -- pre-installed on macOS)
sudo apt-get install libsqlite3-dev
```

### Authentication

Pick one:

- **Claude CLI OAuth** (recommended for Pro/Max subscribers):
  ```bash
  claude login          # interactive (opens browser)
  claude setup-token    # headless/remote servers
  ```

- **API Key** (pay-as-you-go):
  ```bash
  export ANTHROPIC_API_KEY="sk-ant-..."
  ```

## Quick Start

```bash
# Clone and install
git clone <repo-url> && cd dartclaw
dart pub get

# Start server
dart run dartclaw_cli:dartclaw serve

# Open http://127.0.0.1:3000
```

See `examples/` for ready-made configs (dev, production, personal-assistant).

### AOT Compilation (Production)

```bash
dart compile exe apps/dartclaw_cli/bin/dartclaw.dart -o dartclaw
./dartclaw serve
```

Zero runtime dependencies -- no Dart SDK needed on the target machine.

### Verify

```bash
dart analyze            # zero issues expected
dart test packages/dartclaw_core
dart test packages/dartclaw_server
dart test apps/dartclaw_cli
```

## First Session

1. Open [http://127.0.0.1:3000](http://127.0.0.1:3000)
2. Click **"Create your first session"**
3. Type a message, press **Ctrl+Enter** (or **Cmd+Enter** on macOS)
4. Agent responds with streaming text via SSE

## What Happens Under the Hood

1. Browser POSTs to `/api/sessions/:id/send`
2. Dart server stores message, composes system prompt from behavior files
3. Dart server sends message to `claude` binary via JSONL stdin
4. `claude` binary executes the turn (tools, bash, files)
5. Events stream back via JSONL stdout: text deltas, tool use, tool results
6. Dart server forwards as SSE frames to browser
7. Browser renders markdown with syntax highlighting

## Data Storage

```
~/.dartclaw/
  dartclaw.yaml          Configuration
  workspace/
    SOUL.md              Agent identity
    AGENTS.md            Safety rules
    USER.md              User context
    TOOLS.md             Environment notes
    MEMORY.md            Persistent memory (agent-written)
    HEARTBEAT.md         Periodic tasks
  sessions/              Session transcripts (NDJSON)
  logs/                  Structured logs
  dartclaw.db            SQLite search index
```

See [Workspace](workspace.md) for details on each file.

## CLI Commands

```bash
dartclaw serve                    # Start web server (default: localhost:3000)
dartclaw serve --port 8080        # Custom port
dartclaw --config dev.yaml serve  # Use specific config file
dartclaw status                   # Sessions, DB path, worker state
dartclaw rebuild-index            # Rebuild FTS5 search index
dartclaw token show               # Show auth token
dartclaw token rotate             # Generate new auth token
dartclaw deploy setup             # Deployment wizard
```

## Troubleshooting

### "No authentication configured"
Verify auth: `echo $ANTHROPIC_API_KEY` or `claude auth status`.

### Port already in use
```bash
dartclaw serve --port 8081
```

### "dart analyze" reports issues
Run `dart pub get` first. Check Dart SDK >= 3.7.0.

## Guide Contents

- **[Configuration](configuration.md)** -- dartclaw.yaml, guards, scheduling
- **[Workspace](workspace.md)** -- behavior files, memory, prompt assembly
- **[Security](security.md)** -- guards, containers, credential proxy
- **[WhatsApp](whatsapp.md)** -- GOWA setup, pairing, access control
- **[Signal](signal.md)** -- signal-cli setup, registration, access control
- **[Google Chat](google-chat.md)** -- Chat app setup, JWT verification, service account config
- **[Agents](agents.md)** -- subagent delegation, custom agents, task runners, model hierarchy
- **[Scheduling](scheduling.md)** -- heartbeat, cron jobs, delivery modes
- **[Tasks](tasks.md)** -- task lifecycle, review workflow, worktrees, automation
- **[Search & Memory](search.md)** -- search agent, content-guard, FTS5/QMD
- **[Deployment](deployment.md)** -- LaunchDaemon, systemd, egress firewall
- **[Customization](customization.md)** -- L1-L5 customization ladder
- **[Recipes](recipes/)** -- practical workflow recipes: briefing, journaling, task automation
- **[Web UI & API](web-ui-and-api.md)** -- interface features, REST endpoints
- **[Architecture](architecture.md)** -- 2-layer model, design decisions
