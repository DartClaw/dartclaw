# Agents

DartClaw has two distinct agent execution models: **subagents** for lightweight delegated work and **task runners** for structured background work with review flows. They serve different purposes, are configured differently, and run on different infrastructure.

## Subagents (Delegation)

Subagents are lightweight, sandboxed agents that the main agent delegates to via MCP tools. Each subagent has restricted tool access, its own session store, and a content-guard boundary — results are scanned before returning to the caller.

### How Delegation Works

```
Main agent turn (primary harness)
    │
    ├── sessions_send("search", "Find recent Dart 3.8 changes")
    │       │
    │       ▼
    │   SessionDelegate
    │       ├── Validates agent ID exists in agent.agents
    │       ├── Enforces SubagentLimits (concurrency, depth, children)
    │       ├── Dispatches turn to isolated session
    │       ├── Content-guard scans result at boundary
    │       └── Returns result (or blocks if unsafe)
    │
    └── Main agent continues with the search result
```

Two MCP tools trigger delegation:

| Tool | Behavior |
|------|----------|
| `sessions_send` | Synchronous — main agent blocks until the subagent completes and returns a result |
| `sessions_spawn` | Asynchronous — returns a session ID immediately; the subagent runs in the background |

### Built-in: Search Agent

The only pre-built subagent is `search` — a web search agent with `WebSearch` and `WebFetch` tools only. It defaults to the `haiku` model for cost efficiency.

If you don't configure any agents under `agent.agents`, DartClaw automatically registers the default search agent. If you define *any* agents in config, the default is not added — include `search` explicitly if you still want it.

See [Search & Memory](search.md) for search-specific details (content-guard, tool policy cascade, memory search).

### Defining Custom Subagents

You can define any number of subagents under `agent.agents`. Each gets a unique ID, tool sandbox, and optional model override:

```yaml
agent:
  agents:
    search:
      tools: [WebSearch, WebFetch]
      model: haiku
      max_concurrent: 2

    summarizer:
      description: "Summarizes long documents into concise briefs"
      prompt: >
        You are a summarization specialist. Read the provided content
        and produce a concise, structured summary. Include key facts,
        decisions, and action items. Never fabricate information.
      tools: [Read]
      model: haiku
      max_response_bytes: 1048576   # 1MB cap

    code-reviewer:
      description: "Reviews code changes for quality and security issues"
      prompt: >
        You are a code review assistant. Analyze the provided code
        for bugs, security issues, and style problems. Be specific
        about line numbers and suggest fixes.
      tools: [Read, Glob, Grep]
      denied_tools: [Bash, Write, Edit]
      model: sonnet
      max_concurrent: 1
```

The main agent delegates to these by name:

```
Main agent: sessions_send("summarizer", "Summarize this document: ...")
Main agent: sessions_send("code-reviewer", "Review the changes in src/auth/...")
```

### Subagent Configuration Reference

Each entry under `agent.agents.<id>` supports:

| Key | Default | Purpose |
|-----|---------|---------|
| `description` | `"Agent: <id>"` | Human-readable description sent to the runtime |
| `prompt` | *(search prompt)* | System prompt for the subagent |
| `tools` | *(see note)* | Allowlisted tools (closed set — only these are permitted) |
| `denied_tools` | `[]` | Explicitly blocked tools (overrides allowlist) |
| `model` | *(global agent.model)* | Model override for this subagent |
| `max_concurrent` | `1` | Max parallel instances of this subagent |
| `max_spawn_depth` | `0` | Whether this subagent can spawn its own children |
| `max_children_per_agent` | `0` | Max children this agent may own |
| `max_response_bytes` | `5242880` (5MB) | Response size cap before truncation |
| `session_store_path` | `agents/<id>/sessions` | Relative path for this agent's session files |

**Tools default behavior**: The `tools` allowlist default depends on the agent id. The built-in `search` agent defaults to `[WebSearch, WebFetch]`. All other agents default to an empty allowlist — meaning no tools are permitted unless explicitly listed. A startup warning is emitted for any non-search agent with an empty tools list, since it will not be able to use any tools.

Any unrecognized keys are preserved as `extra` and forwarded to the claude binary's initialize handshake.

### Tool Policy Cascade

Subagent tool access is evaluated through a 3-layer policy (most restrictive wins):

1. **Global deny** — `agent.disallowed_tools` blocks tools for all agents (main + subagents)
2. **Agent deny** — `denied_tools` per subagent blocks tools for that specific agent
3. **Sandbox allow** — `tools` per subagent is a closed allowlist; only listed tools are permitted

### Subagent Limits

Global limits prevent runaway spawning. The runtime derives these from your agent definitions:

| Limit | Value | How computed |
|-------|-------|-------------|
| `maxConcurrent` | sum of all agents' `max_concurrent` | e.g. search(2) + summarizer(1) = 3 |
| `maxSpawnDepth` | 1 | Hardcoded — subagents cannot spawn sub-subagents beyond one level |
| `maxChildrenPerAgent` | same as `maxConcurrent` | Each parent can own up to the global concurrent cap |

These are enforced by `SubagentLimits` in `SessionDelegate`. When limits are reached, delegation calls return an error — the main agent can retry later or proceed without the subagent. Per-agent `max_concurrent` provides finer-grained control (e.g. limit search to 2 while allowing 1 summarizer).

### Content-Guard Boundary

Every result returned via `sessions_send` passes through the content-guard before reaching the main agent. This prevents poisoned web content or prompt injection from propagating. If the guard blocks the result, the main agent receives an error message instead.

`sessions_spawn` (async) does not have this boundary scan — the spawned session runs independently.

## Task Runners (Background Work)

Task runners are a separate execution model for structured, reviewable background work. Unlike subagents (which are lightweight delegations within a turn), tasks are independent work units with their own lifecycle, artifacts, and review flow.

### How Tasks Differ from Subagents

| | Subagents | Task Runners |
|---|-----------|-------------|
| **Triggered by** | Main agent via `sessions_send`/`sessions_spawn` | Task queue (API, web UI, automation schedule) |
| **Execution** | Within the caller's turn | Independent background execution |
| **Harness** | Shared (main harness via SessionDelegate) | Dedicated harness from the pool |
| **Tool access** | Sandboxed (closed allowlist) | Full agent tools (same as main chat) |
| **Review** | None — result returned inline | Review workflow (accept/reject/push-back) |
| **Artifacts** | None | Structured diffs, files, logs |
| **Config** | `agent.agents.<id>` in YAML | `tasks.*` in YAML + per-task `configJson` at creation |
| **Lifecycle** | Fire-and-forget or sync wait | State machine (draft → queued → running → review → accepted) |

### Task Runner Pool

The `HarnessPool` manages multiple claude binary instances:

- **Runner 0** (primary) — reserved for interactive chat, cron jobs, and channel messages. Never acquired by the task executor.
- **Runners 1..N** (task pool) — acquired by `TaskExecutor` for background task execution. The pool size is controlled by `tasks.max_concurrent`.

```yaml
tasks:
  max_concurrent: 3    # creates 3 dedicated task runners
```

With `max_concurrent: 3`, DartClaw spawns 4 total harnesses: 1 primary + 3 task runners. Each task runner is an independent claude binary subprocess.

### Container Profile Routing

Each task type maps to a security profile that determines which container the task runs in:

| Task Type | Profile | Mounts | Rationale |
|-----------|---------|--------|-----------|
| `research` | `restricted` | No workspace | Research tasks should not access or modify project files |
| `coding` | `workspace` | `/workspace:rw`, `/project:ro` | Needs file access for code changes |
| `writing` | `workspace` | `/workspace:rw`, `/project:ro` | May read/write workspace files |
| `analysis` | `workspace` | `/workspace:rw`, `/project:ro` | May read project files for analysis |
| `automation` | `workspace` | `/workspace:rw`, `/project:ro` | General-purpose automation |
| `custom` | `workspace` | `/workspace:rw`, `/project:ro` | Default for untyped work |

In pool mode, `TaskExecutor` matches a task's profile to a runner started with that profile via `HarnessPool.tryAcquireForProfile()`. A `research` task will only execute on a `restricted`-profile runner.

### Per-Task Overrides

When creating a task (via API or web UI), you can set per-task overrides in `configJson`:

| Key | Type | Purpose |
|-----|------|---------|
| `model` | `string` | Model override for this task (e.g. `"opus"`, `"haiku"`) |
| `tokenBudget` / `budget` | `int` | Maximum token spend; task auto-fails if exceeded |

```http
POST /api/tasks
Content-Type: application/json

{
  "title": "Deep analysis of auth patterns",
  "description": "Analyze all authentication code paths for security gaps.",
  "type": "analysis",
  "autoStart": true,
  "configJson": {
    "model": "opus",
    "tokenBudget": 500000
  }
}
```

Tasks inherit the global `agent.model` by default. The `model` override in `configJson` takes precedence for that specific task only.

For the full task lifecycle, review workflow, and worktree behavior, see [Tasks](tasks.md).

## Providers

DartClaw supports multiple agent providers. Each provider is a separate CLI binary that DartClaw spawns as a subprocess. The Dart host manages all state, security, and orchestration — the provider binary handles agent reasoning and tool execution.

### Built-in Providers

| Provider ID | Binary | Protocol | Models | Notes |
|-------------|--------|----------|--------|-------|
| `claude` | `claude` CLI | Bidirectional JSONL | Claude (Haiku, Sonnet, Opus) | Default. Full feature support including cost reporting, streaming, tool approval via hooks |
| `codex` | `codex` CLI (app-server mode) | JSON-RPC JSONL | OpenAI (GPT-4o, GPT-5, o-series), Ollama | Persistent process, approval chain via JSON-RPC, no USD cost reporting |

### Setting Up Codex

1. **Install the Codex CLI**: See the [OpenAI Codex CLI docs](https://developers.openai.com/codex/cli). Verify with `codex --version`.

2. **Set up auth**:

   ```bash
   export CODEX_API_KEY="sk-..."
   ```

3. **Configure DartClaw** to use Codex as the default provider, or alongside Claude:

   **Codex only:**
   ```yaml
   agent:
     provider: codex
     model: gpt-4o                  # or: o3, gpt-5, etc.

   credentials:
     openai:
       api_key: ${CODEX_API_KEY}
   ```

   **Mixed (Claude default + Codex for tasks):**
   ```yaml
   agent:
     provider: claude
     model: opus

   providers:
     claude:
       executable: claude
       pool_size: 1
     codex:
       executable: codex
       pool_size: 2

   credentials:
     anthropic:
       api_key: ${ANTHROPIC_API_KEY}
     openai:
       api_key: ${CODEX_API_KEY}
   ```

4. **Start DartClaw** — it will probe each configured provider binary at startup and log the detected version and availability.

### Per-Task Provider Override

In a mixed deployment, you can route individual tasks to a specific provider:

```http
POST /api/tasks
Content-Type: application/json

{
  "title": "Research competitor pricing",
  "type": "research",
  "provider": "codex",
  "configJson": { "model": "gpt-5" }
}
```

This acquires a harness from the Codex pool regardless of the global `agent.provider` setting.

### Provider Routing

| Scope | Config | Behavior |
|-------|--------|----------|
| **Global default** | `agent.provider: claude` | All sessions and tasks use Claude unless overridden |
| **Per-task** | `provider` field on task creation | Task acquires a harness from the specified provider's pool |
| **Pool allocation** | `providers.<id>.pool_size` | Controls how many concurrent workers each provider gets |

The primary harness (Runner 0, for interactive chat) always uses the global default provider. Task pool workers can be a mix of providers.

### Codex Approval Policy & Sandbox Mode

The Codex app-server provider supports two per-turn settings that control how Codex handles tool execution internally:

| Config key | Values | Default | Purpose |
|---|---|---|---|
| `approval` | `on-request`, `unless-allow-listed`, `never` | `on-request` | Whether Codex sends tool approval requests to DartClaw |
| `sandbox` | `workspace-write`, `danger-full-access` | *(none — Codex default)* | Codex-side filesystem sandbox restrictions |

**`approval` values:**
- `on-request` — Codex sends approval requests for every tool call; DartClaw's guard chain evaluates them
- `unless-allow-listed` — Codex only requests approval for commands not in its built-in safe-command list
- `never` — No approval requests; all tool calls execute immediately

**`sandbox` values:**
- `workspace-write` — Codex sandbox allows writes only to the working directory
- `danger-full-access` — No Codex-side sandbox restrictions

> **Known issue — approval deadlock**: Codex's app-server has an upstream bug ([openai/codex#11816](https://github.com/openai/codex/issues/11816), open as of March 2026) where tool approval requests block indefinitely with no timeout. This causes turns that involve file creation, shell commands, or other tool use to hang silently — while simple conversational turns succeed. The `SessionLockManager` holds the per-session lock for the entire stuck turn (up to `worker_timeout`), blocking all other messages to that session.
>
> **Recommended settings for non-interactive use** (crowd-coding, batch tasks, automation):
> ```yaml
> providers:
>   codex:
>     executable: codex
>     pool_size: 2
>     approval: never
>     sandbox: danger-full-access
> ```
>
> Setting `approval: never` disables Codex's *internal* approval gate. DartClaw's own defense-in-depth remains fully active: guard chain (command, file, network, content guards), container isolation, `TaskFileGuard`, and input sanitizer all continue to evaluate every tool call independently.
>
> Also consider reducing `worker_timeout` (default 600s) to 120s for shared-session scenarios to limit blast radius if other hang causes occur (context compaction, orphaned child processes).

### Codex Skill Loading

Codex CLI exposes installed skills through a `<skills_instructions>` available-skills index in the initial model context. Codex 0.121+ loads only skill metadata (name, description, and path), not full skill bodies. Full `SKILL.md` instructions are read from disk only when a skill is invoked or opened. If you are running an older Codex release without this optimization, every workflow turn pays the full skill-body cost; upgrade to 0.121+ to restore the metadata-only behavior.

DartClaw therefore uses Codex's native skill loading directly. Runtime-provisioned workflow skills are installed under `<dataDir>/.agents/skills/` with the `dartclaw-` prefix, AndThen-provided Codex agents are installed under `<dataDir>/.codex/agents/`, and each configured project/worktree receives per-skill links into those data-dir payloads. Spawned Codex workflow one-shot turns run with the normal Codex profile and OAuth state. DartClaw does not create an isolated `CODEX_HOME` for workflow one-shot execution, does not symlink Codex auth files, and does not inline skill bodies into prompts. (The long-lived `dartclaw_core` Codex harness used for interactive sessions can establish its own `CODEX_HOME` isolation when `providers.codex.use_system_codex_home: false` is set; the default inherits the system home.)

This keeps authentication and provider behavior aligned with ordinary `codex` CLI usage while keeping DartClaw-managed skill payloads scoped to the configured data directory.

### Provider Capability Differences

Not all providers support every feature. DartClaw degrades gracefully:

| Capability | Claude | Codex |
|-----------|--------|-------|
| Streaming text | Yes | Yes |
| Tool approval (guard chain) | Yes (via hooks) | Yes (via JSON-RPC approvals) |
| USD cost reporting | Yes | No (token counts only) |
| Crash recovery | Yes | Yes |
| System prompt injection | `--append-system-prompt` | `config.toml` `developer_instructions` |
| MCP server support | Yes | Yes (via `config.toml`) |

When a provider doesn't report cost, the UI shows token counts with a "cost unavailable" indicator. For Codex sessions, the sidebar now labels input as fresh input and shows cached input separately so Claude and Codex totals are comparable.

### Provider Status

Check provider health at `GET /api/providers` or on the Settings page. DartClaw reports:
- Whether the binary was found on `$PATH` (or at the configured executable path)
- Detected version (from `--version` probe at startup)
- Credential status (API key present/missing)
- Current pool allocation and worker states

## Choosing the Right Model

| Use case | Agent model | Why |
|----------|------------|-----|
| Quick web lookup during chat | Subagent (`search`) | Sandboxed, cheap (haiku), result scanned by content-guard |
| Summarize a document for the main agent | Custom subagent (`summarizer`) | Restricted tools, inline result, no review needed |
| Write and test a new feature | Task (`coding`) | Needs full tool access, worktree isolation, code review |
| Background research report | Task (`research`) | Independent work, restricted container, reviewable output |
| Recurring maintenance check | Cron job (not an agent) | Lightweight, no review, runs on primary harness |

Note: cron jobs and heartbeat are **not** separate agents — they run as regular turns on the primary harness using the global `agent.model`. See [Scheduling](scheduling.md).
