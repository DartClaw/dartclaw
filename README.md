# DartClaw

_Because your AI agent shouldn't sit on a treacherous dependency iceberg._

DartClaw is a security-focused agent runtime — a single AOT-compiled Dart binary with zero Node.js or npm in the chain. No sprawling dependency tree, no supply-chain roulette. Just Dart's batteries-included stdlib, container isolation, a guard chain that blocks by default, and API keys the agent never sees — because "I told the LLM to behave" is not a security model.

_**Opinionated (Claude Code), but pluggable.**_
The harness architecture currently drives Claude's native CLI binary via JSONL control protocol, but is designed to leash any agent runtime — Pi, local models, that hot new AI your timeline won't shut up about. Swap the brain, keep the cage.

> **Status**: v0.7 — configurable session scoping, session maintenance, event bus infrastructure, channel DM access management.

## Architecture

```
User --> HTTP/WhatsApp/Signal --> Dart Host --> Guards --> Container --> claude binary
                              |                         |
                        Guard Chain               network:none
                        Audit Logger            Credential Proxy
                       Content Guard             Mount Allowlist
```

Two layers with clear trust boundaries:
- **Dart host** -- state (file-based + SQLite via `dartclaw_storage`), HTTP API, web UI, security policy, scheduling, channels
- **Agent runtime** -- reasoning, tool execution, bash commands (optionally in Docker container)

The Dart host communicates with the agent runtime through the `AgentHarness` abstract interface. The current implementation (`ClaudeCodeHarness`) drives the native `claude` CLI binary via bidirectional JSONL over stdin/stdout. The harness abstraction is runtime-agnostic — the rest of the system (server, turn manager, health checks, guards) depends only on the interface, never on a specific runtime. This means alternative agent runtimes (e.g. Pi, local models, or other AI CLIs) can be integrated by implementing a new harness class without modifying any consuming code.

## Key Features

- **Defense-in-depth security** -- Docker container isolation (`network:none`, `--cap-drop ALL`), guard chain (command/file/network/content), credential proxy, HTTP auth
- **Web chat UI** -- HTMX + SSE streaming, markdown rendering, syntax highlighting, light/dark theme
- **WhatsApp channel** -- via GOWA sidecar (whatsmeow), DM/group access control, mention gating, pairing flow
- **Signal channel** -- via signal-cli, DM/group access control, sealed-sender normalization, voice verification, pairing
- **Configurable session scoping** -- DM scope (shared/per-contact/per-channel-contact), group scope (shared/per-member), per-channel overrides
- **Session maintenance** -- automatic pruning, count cap, disk budget, cron retention, warn/enforce modes, CLI cleanup command
- **Scheduling** -- cron jobs, heartbeat checklist, workspace git sync
- **Search agent** -- dedicated 2-agent pattern with tool policy cascade, content-guard at boundary
- **Hybrid memory** -- FTS5 default, QMD opt-in for vector search, agent-driven consolidation
- **Session management** -- per-session locks, concurrent turns, reset policies, archiving, event-driven lifecycle
- **Crash recovery** -- cursor-based message replay, harness auto-restart with exponential backoff
- **AOT compilation** -- single native binary, zero runtime dependencies
- **Customizable** -- 5-level customization ladder from behavior files to source code

## Prerequisites

- **Dart SDK (for building)** >= 3.11.0
- **Claude CLI** (`claude` binary in PATH)
- **SQLite** -- system library (bundled on macOS/most Linux)
- **Docker** -- optional, for container isolation
- **ANTHROPIC_API_KEY** or Claude CLI OAuth session

## Quick Start

```bash
git clone <repo-url> && cd dartclaw
dart pub get
export ANTHROPIC_API_KEY="sk-ant-..."
dart run dartclaw_cli:dartclaw serve
# Open http://127.0.0.1:3000
```

### AOT Binary

```bash
dart compile exe apps/dartclaw_cli/bin/dartclaw.dart -o dartclaw
./dartclaw serve
```

## Project Structure

```
apps/dartclaw_cli/          CLI app (serve, status, deploy, token commands)
packages/dartclaw_core/     Shared lib: harness, protocol, guards, channels,
                            agents, security, scheduling (sqlite3-free)
packages/dartclaw_models/   Shared models: session types, SessionKey (no heavy deps)
packages/dartclaw_storage/  SQLite3-backed storage: MemoryService, SearchDb,
                            FTS5/QMD backends, MemoryPruner
packages/dartclaw_server/   HTTP API (Shelf), web UI templates, SSE streaming,
                            turn orchestration, static assets
docs/                       Specs, ADRs, guidelines, user guide
```

Dart pub workspace -- all packages share dependencies and resolve locally.

## Configuration

DartClaw uses `dartclaw.yaml` for runtime config and behavior files for agent personality:

```yaml
# dartclaw.yaml (minimal)
port: 3000
host: localhost
guards:
  enabled: true
scheduling:
  heartbeat:
    interval_minutes: 30
```

Behavior files in `~/.dartclaw/workspace/`: `SOUL.md` (identity), `AGENTS.md` (safety rules), `USER.md` (user context), `TOOLS.md` (environment), `MEMORY.md` (agent knowledge), `HEARTBEAT.md` (periodic tasks).

## Documentation

### User Guide
- **[Getting Started](docs/guide/getting-started.md)** -- installation, first run, overview
- **[Configuration](docs/guide/configuration.md)** -- dartclaw.yaml, guards, scheduling
- **[Workspace](docs/guide/workspace.md)** -- behavior files, memory, prompt assembly
- **[Security](docs/guide/security.md)** -- guards, containers, credential proxy
- **[WhatsApp](docs/guide/whatsapp.md)** -- GOWA setup, pairing, access control
- **[Signal](docs/guide/signal.md)** -- signal-cli setup, pairing, sealed-sender normalization
- **[Scheduling](docs/guide/scheduling.md)** -- heartbeat, cron jobs
- **[Search & Memory](docs/guide/search.md)** -- search agent, FTS5/QMD
- **[Deployment](docs/guide/deployment.md)** -- LaunchDaemon, systemd, egress firewall
- **[Customization](docs/guide/customization.md)** -- L1-L5 customization ladder

### Architecture & Specs
- **[Architecture](docs/guide/architecture.md)** -- 2-layer model, design decisions
- **[Web UI & API](docs/guide/web-ui-and-api.md)** -- interface features, REST endpoints
- **[Feature Comparison](docs/specs/feature-comparison.md)** -- OpenClaw vs NanoClaw vs DartClaw
- **[ADRs](docs/adrs/)** -- architecture decision records

## Security Model

Defense-in-depth with multiple independent layers:

1. **Container isolation** -- Docker `network:none`, `--cap-drop ALL`, read-only root, mount allowlist
2. **Credential proxy** -- API keys on Unix socket, never in container env
3. **Guard chain** -- command, file, network, content guards (fail-closed)
4. **Content-guard** -- LLM classification at agent boundaries
5. **HTTP auth** -- token-based + session cookies
6. **System prompt safety rules** -- injected every turn, not overridable

Without Docker, guards serve as the primary boundary (pragmatic mode for development).

## Development

```bash
dart test packages/dartclaw_core
dart test packages/dartclaw_server
dart test apps/dartclaw_cli
dart format <file_or_dir>
dart analyze
```

## Inspirations & influences

Born from spending too much time wrangling AI agents and wondering why the tooling keeps making the same mistakes. These projects and people shaped how DartClaw thinks about the problem: 

- **[OpenClaw](https://github.com/OpenAgentsInc/openclaw)** and **[NanoClaw](https://github.com/cyanheads/nanoclaw)** — two earlier agent runtimes whose architectures, trade-offs, and battle scars directly informed DartClaw's design
- **Cole Medin** — his work around building agentic systems in general and especially his case for building your own agent runtime rather than depending on ever-shifting frameworks. DartClaw exists partly because of that argument
- **Daniel Miessler** — creator of PAI and a relentless voice for treating AI security as real security, not vibes. The defense-in-depth model here owes a debt to that thinking
- **[claude_agent_sdk](https://github.com/nshkrdotcom/claude_agent_sdk)** — early exploration of driving the Claude Code binary directly via JSONL, which validated the approach DartClaw's harness is built on

## License

MIT
