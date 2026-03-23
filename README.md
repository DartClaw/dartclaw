# DartClaw

_Agentic powers. No dependency black holes. Secure by design._

DartClaw is a security-minded agent runtime — a single AOT-compiled Dart binary with zero Node.js or npm in the chain. No sprawling dependency tree, no supply-chain roulette. Just Dart's batteries-included stdlib, container isolation, a guard chain that blocks by default, and API keys the agent never sees — because "I told the LLM to behave" is not a security model.

**Multi-provider, pluggable.** Ships with harnesses for Claude Code (JSONL) and Codex (JSON-RPC). Swap the brain, keep the cage — the harness abstraction is runtime-agnostic, so adding new providers means implementing one class.

> **Status**: v0.13 — Multi-provider agent harnesses (Claude Code + Codex), crowd coding, runtime governance. Pre-release. See [CHANGELOG](CHANGELOG.md).

## Architecture

```
                                                          ┌─── claude binary (JSONL)
User ─→ HTTP / WhatsApp / Signal / Google Chat ─→ Dart Host ─→ Guards ─→ Container ─┤
                                                  │                      │           └─── codex binary (JSON-RPC)
                                            Guard Chain            network:none
                                            Audit Logger         Credential Proxy
                                           Content Guard          Mount Allowlist
                                           Rate Limiter
                                           Loop Detector
```

Two layers with clear trust boundaries:
- **Dart host** -- state (file-based + SQLite), HTTP API, web UI, security policy, scheduling, channels, task orchestration, runtime governance
- **Agent runtime** -- reasoning, tool execution, bash commands (in per-type Docker containers or host process)

The Dart host communicates with agent runtimes through the `AgentHarness` abstract interface. `HarnessFactory` instantiates the right harness by provider ID — `ClaudeCodeHarness` (bidirectional JSONL over stdin/stdout) or `CodexHarness` (JSON-RPC via `codex app-server`). Guards evaluate provider-agnostic canonical tool names, so the same security policy applies regardless of which agent is running. The `HarnessPool` manages a heterogeneous mix of workers, with per-task and per-session provider overrides.

## Key Features

- **Multi-provider harnesses** -- Claude Code (JSONL) and Codex (JSON-RPC) out of the box; `HarnessFactory` + `ProtocolAdapter` abstraction for adding more; heterogeneous worker pool with per-task and per-session provider overrides; canonical tool taxonomy so guards are provider-agnostic
- **Defense-in-depth security** -- per-type container isolation (`workspace` and `restricted` profiles), Docker `network:none` + `--cap-drop ALL`, guard chain (command/file/network/content), credential proxy, HTTP auth, canonical tool names across providers
- **Crowd coding** -- multiple users in a WhatsApp group, Signal group, or Google Chat Space collaboratively steer an AI agent; thread-bound task sessions, sender attribution, slash commands from chat
- **Runtime governance** -- per-sender and global rate limiting, daily token budgets (warn/block modes), loop detection (turn depth, token velocity, tool fingerprinting); emergency controls (`/stop`, `/pause`, `/resume`)
- **Task orchestration** -- background AI tasks with review queue; 6 task types (coding/research/writing/analysis/automation/custom); goal hierarchy for context injection; state machine lifecycle with push-back; provider override per task
- **Parallel execution** -- `HarnessPool` manages heterogeneous agent instances across providers; configurable per-provider `pool_size`; per-session turn serialization; container dispatch routing
- **Coding tasks** -- git worktree isolation per task; `FileGuard` integration; structured diff review; configurable merge strategy (squash/merge); conflict detection
- **Task dashboard** -- review queue, status filters, SSE live updates, provider badges; task detail with embedded chat, artifact panel, review controls
- **Agent observability** -- per-harness metrics (tokens, turns, errors, cost); provider status API; capability-aware cost display (USD for Claude, token counts for Codex)
- **Web chat UI** -- HTMX + SSE streaming, markdown rendering, syntax highlighting, light/dark theme, context usage warnings
- **Channels** -- WhatsApp (GOWA sidecar), Signal (signal-cli), Google Chat (Workspace Events API + Pub/Sub for full space participation); DM/group access control, configurable session scoping, mention gating
- **Session management** -- per-session locks, concurrent turns, configurable scoping (DM/group/per-contact), automatic maintenance (pruning, count cap, disk budget, cron retention)
- **Scheduling** -- cron jobs (prompt and task types), heartbeat checklist, workspace git sync; scheduled tasks auto-enter review queue
- **Search & memory** -- dedicated search agent with tool policy cascade; FTS5 default, QMD opt-in for vector search; agent-driven memory consolidation
- **Context management** -- compact instructions for long sessions, exploration summaries for large files, context warning banners
- **Crash recovery** -- cursor-based message replay, harness auto-restart with exponential backoff, provider-aware thread recreation
- **AOT compilation** -- single native binary, zero runtime dependencies
- **Customizable** -- 5-level customization ladder from behavior files to source code; composed config model with typed sections; extension config registration for plugins

## Prerequisites

- **Dart SDK** >= 3.11.0
- **Agent CLI** -- at least one: `claude` (Claude Code) or `codex` (OpenAI Codex CLI)
- **SQLite** -- system library (bundled on macOS/most Linux)
- **Docker** -- optional, for container isolation
- **API key** -- `ANTHROPIC_API_KEY` and/or `OPENAI_API_KEY` depending on configured providers

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
apps/dartclaw_cli/              CLI app (serve, status, deploy, token commands)
packages/
  dartclaw/                     Published umbrella — re-exports core + models + storage
  dartclaw_core/                Harness, protocol adapters, guards, channels,
                                agents, scheduling, governance (sqlite3-free)
  dartclaw_models/              Pure data classes: Session, Message, SessionKey (zero deps)
  dartclaw_storage/             SQLite3-backed: MemoryService, SearchDb, FTS5/QMD, pruner
  dartclaw_server/              HTTP API (Shelf), web UI (HTMX/Trellis), SSE, tasks, turns
  dartclaw_config/              Config parsing, typed sections, extension registration
  dartclaw_security/            Guard implementations, input sanitizer, content classifier
  dartclaw_whatsapp/            WhatsApp channel (GOWA sidecar)
  dartclaw_signal/              Signal channel (signal-cli sidecar)
  dartclaw_google_chat/         Google Chat channel (Workspace Events + Pub/Sub)
  dartclaw_testing/             Shared test fakes and utilities
docs/                           User guide, SDK guide, specs, ADRs
```

Dart pub workspace — all packages share dependencies and resolve locally.

## Configuration

DartClaw uses `dartclaw.yaml` with typed config sections, and behavior files for agent personality:

```yaml
# dartclaw.yaml (minimal)
server:
  port: 3000
agent:
  provider: claude          # default provider
providers:
  claude:
    executable: claude
    pool_size: 2
  codex:
    executable: codex
    pool_size: 1
credentials:
  anthropic: ${ANTHROPIC_API_KEY}
  openai: ${OPENAI_API_KEY}
security:
  guards:
    enabled: true
scheduling:
  heartbeat:
    interval_minutes: 30
```

Behavior files in `~/.dartclaw/workspace/`: `SOUL.md` (identity), `AGENTS.md` (safety rules), `USER.md` (user context), `TOOLS.md` (environment), `MEMORY.md` (agent knowledge), `HEARTBEAT.md` (periodic tasks). See [Configuration guide](docs/guide/configuration.md) for the full reference.

## Documentation

### User Guide ([full index](docs/guide/README.md))
- **[Getting Started](docs/guide/getting-started.md)** -- installation, first run, overview
- **[Configuration](docs/guide/configuration.md)** -- dartclaw.yaml reference, typed config sections, environment variables
- **[Workspace](docs/guide/workspace.md)** -- behavior files, memory, prompt assembly
- **[Security](docs/guide/security.md)** -- guards, containers, credential proxy, canonical tool taxonomy
- **[Tasks](docs/guide/tasks.md)** -- task orchestration, review workflow, coding tasks, provider overrides
- **[Agents](docs/guide/agents.md)** -- subagent delegation, model selection, provider-aware pool
- **[Channels](docs/guide/whatsapp.md)** -- [WhatsApp](docs/guide/whatsapp.md) / [Signal](docs/guide/signal.md) / [Google Chat](docs/guide/google-chat.md) setup and access control
- **[Scheduling](docs/guide/scheduling.md)** -- heartbeat, cron jobs
- **[Search & Memory](docs/guide/search.md)** -- search agent, FTS5/QMD hybrid search
- **[Projects & Git](docs/guide/projects-and-git.md)** -- project directory, worktrees, branch management
- **[Deployment](docs/guide/deployment.md)** -- LaunchDaemon, systemd, egress firewall
- **[Customization](docs/guide/customization.md)** -- L1-L5 customization ladder

### Recipes ([index](docs/guide/recipes/README.md))
- **[Personal Assistant](docs/guide/recipes/00-personal-assistant.md)** -- turnkey setup: briefings + journaling + research + reflection
- **[Crowd Coding](docs/guide/recipes/08-crowd-coding.md)** -- multi-user collaborative AI agent steering via chat
- [Morning Briefing](docs/guide/recipes/01-morning-briefing.md) / [Daily Journal](docs/guide/recipes/02-daily-memory-journal.md) / [Task Queue](docs/guide/recipes/03-scheduled-task-queue.md) / [Knowledge Inbox](docs/guide/recipes/04-knowledge-inbox.md) / [CRM Tracker](docs/guide/recipes/05-contact-crm-tracker.md) / [Research Assistant](docs/guide/recipes/06-research-assistant.md) / [Nightly Reflection](docs/guide/recipes/07-nightly-reflection.md)

### SDK Guide
- **[Quick Start](docs/sdk/quick-start.md)** -- build your first agent in under 30 lines
- **[Package Guide](docs/sdk/packages.md)** -- which package to depend on
- **[Examples](examples/sdk/)** -- runnable SDK example projects

### Architecture & Specs
- **[Architecture](docs/guide/architecture.md)** -- 2-layer model, multi-provider, design decisions
- **[Web UI & API](docs/guide/web-ui-and-api.md)** -- interface features, REST endpoints, provider status API
- **[ADRs](docs/adrs/)** -- architecture decision records

## Security Model

Defense-in-depth with multiple independent layers:

1. **Container isolation** -- Docker `network:none`, `--cap-drop ALL`, read-only root, mount allowlist
2. **Credential isolation** -- multi-provider credentials via `CredentialRegistry`; API keys on Unix socket, never in container env
3. **Guard chain** -- command, file, network, content guards operating on canonical tool names (provider-agnostic, fail-closed)
4. **Content-guard** -- LLM classification at agent boundaries
5. **Runtime governance** -- per-sender rate limiting, token budgets, loop detection; `/stop` emergency kill
6. **HTTP auth** -- token-based + session cookies
7. **System prompt safety rules** -- injected every turn, not overridable

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
- **Cole Medin** — his work on building agentic systems and especially his case for building your own agent runtime rather than depending on ever-shifting frameworks. DartClaw exists partly because of that argument
- **Daniel Miessler** — creator of PAI and a relentless voice for treating AI security as real security, not vibes. The defense-in-depth model here owes a debt to that thinking
- **[claude_agent_sdk](https://github.com/nshkrdotcom/claude_agent_sdk)** — early exploration of driving the Claude Code binary directly via JSONL, which validated the approach DartClaw's harness is built on

## License

MIT
