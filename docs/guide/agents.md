# Agents

DartClaw has two broad execution models: lightweight logical-agent conversations and structured background tasks.

## Logical Agent Conversations

Logical agents are named execution profiles that the main agent starts through MCP tools. Their conversations use DartClaw's normal durable session storage and a content-guard boundary – results are scanned before returning to the caller. A non-empty `tools` list adds a host tool-policy sandbox on guard-evaluated turns.

### How Logical-Agent Sessions Work

```
Main agent turn (primary lane)
    │
    ├── sessions_spawn("search", "Find recent Dart changes")
    │       │
    │       ▼
    │   LogicalAgentSessionService
    │       ├── Validates agent ID exists in agent.agents
    │       ├── Resolves the agent's configured provider
    │       ├── Creates a hidden logical-agent session
    │       ├── Content-guard scans result at boundary
    │       └── Returns {session_id, result}
    │
    ├── sessions_send(session_id, "Narrow that to language changes")
    │       └── Replays and continues the same conversation
    │
    └── Main agent continues with the results
```

Logical-agent conversations use two MCP tools:

| Tool | Behavior |
|------|----------|
| `sessions_spawn` | Creates a configured logical-agent conversation, waits for its first turn, and returns `{session_id, result}` |
| `sessions_send` | Sends a follow-up to a `session_id` returned by `sessions_spawn`, waits, and returns the next result |

Use `sessions_spawn` and `sessions_send` for every logical agent under `agent.agents`. A spawn can be treated as one-shot by ignoring its returned handle; use the handle when follow-up context is useful. Provider choice and security policy belong to the logical agent and provider configuration rather than a second execution API.

### Built-in: Search Agent

The only pre-built logical agent is `search` – a web search agent with the canonical `web_search` and `web_fetch` grants. When its model is omitted, it uses the selected provider's default.

If you don't configure any agents under `agent.agents`, DartClaw automatically registers the default search agent. If you define *any* agents in config, the default is not added — include `search` explicitly if you still want it.

See [Search & Memory](search.md) for search-specific details (content-guard, tool policy cascade, memory search).

### Defining Custom Logical Agents

You can define any number of logical agents under `agent.agents`. Each gets a unique ID, tool sandbox, and optional model override:

```yaml
agent:
  agents:
    search:
      tools: [web_search, web_fetch]
      security_profile: restricted

    summarizer:
      description: "Summarizes long documents into concise briefs"
      prompt: >
        You are a summarization specialist. Read the provided content
        and produce a concise, structured summary. Include key facts,
        decisions, and action items. Never fabricate information.
      tools: [file_read]
      model: haiku
      max_response_bytes: 1048576   # 1MB cap

    code-reviewer:
      description: "Reviews code changes for quality and security issues"
      provider: codex
      security_profile: workspace
      prompt: >
        You are a code review assistant. Analyze the provided code
        for bugs, security issues, and style problems. Be specific
        about line numbers and suggest fixes.
      tools: [file_read, Glob, Grep]
      denied_tools: [shell, file_write, file_edit]
      model: sonnet
```

The main agent starts each conversation by agent name, then uses the returned handle for follow-ups:

```
summary = sessions_spawn("summarizer", "Summarize this document: ...")
sessions_send(summary.session_id, "Expand the risks section")

review = sessions_spawn("code-reviewer", "Review the changes in src/auth/...")
sessions_send(review.session_id, "Re-check the authorization boundary")
```

### Logical-Agent Configuration Reference

Each entry under `agent.agents.<id>` supports:

| Key | Default | Purpose |
|-----|---------|---------|
| `description` | `"Agent: <id>"` | Human-readable description exposed in the `sessions_spawn` tool schema |
| `prompt` | Search prompt for `search`; blank otherwise | Authoritative persona for the logical agent's turn. Blank means the worker's configured default — except with an `output_schema`, where a blank prompt makes the rendered output contract the whole persona |
| `provider` | `agent.provider` | Harness provider for this agent's conversations; IDs are trimmed and lowercased |
| `security_profile` | `restricted` for `search`; otherwise provider default or `workspace` | Worker isolation profile: `workspace` or `restricted` |
| `tools` | `[]` | Optional closed allowlist; empty or absent means no sandbox allowlist |
| `denied_tools` | `[]` | Explicitly blocked tools (overrides allowlist) |
| `model` | *(provider default)* | Model override for this logical agent |
| `effort` | *(provider default)* | Reasoning-effort override for Claude and Codex |
| `max_response_bytes` | `5242880` (5MB) | Response size cap. Without an `output_schema` the response is truncated to it; with one the turn fails instead, since a truncated value is not the declared contract |
| `output_schema` | *(none)* | Inline JSON Schema the agent's answer must conform to; a non-conforming answer fails the turn. Read once at startup when agent definitions are built — restart to change it. Never set it on `search`, which `context_research` spawns internally and whose own result packet it would break. See [Configuration](configuration.md#full-config-reference) for the supported keyword set |

**Schema-bound output**: With `output_schema` set, the agent's persona carries a rendered contract — every property name and type, the required set, the closed-object rule, and the instruction to answer with only the JSON value — and the host parses and validates the result at the agent boundary, after the content guard. A result that is not exactly one JSON value (prose, or JSON inside a code fence), that carries an undeclared property, that is missing a required one, or that is over `max_response_bytes` is returned to the caller as an error naming the first violation and its diagnostic location. Schema-declared paths use JSON Pointer; an undeclared property name is replaced by a non-semantic fingerprint so rejected content is not echoed. Nothing is repaired, defaulted, or partially salvaged, and there is no automatic retry — re-asking is the caller's decision.

**Tools default behavior**: The built-in `search` agent defaults to the canonical allowlist `[web_search, web_fetch]`. Other agents default to an empty list. Empty or absent `tools` means no sandbox allowlist is enforced, so all tools remain available except explicit denies. A startup warning calls out this fail-open posture.

Prefer canonical names because they are portable across mapped providers: `shell`, `file_read`, `file_write`, `file_edit`, `web_fetch`, `web_search`, `memory_apply`, `memory_observe`, `memory_search`, `memory_read`, `task_create`, `task_review`, `task_list`, `review_list`, `task_bind`, and `task_unbind`. Existing provider-native spellings such as `Bash`, `Read`, `WebFetch`, and `WebSearch` continue to work and are normalized at startup. Unmapped tools keep their exact provider-native spelling; for example Claude `Glob` evaluates under the `claude:Glob` canonical fallback. DartClaw's own MCP fetch, configured search, memory, and task tools map by exact server/tool identity to their semantic canonical. A deny for `mcp_call` also blocks these remapped own-MCP calls, while allowing `mcp_call` alone does not grant them.

Each logical-agent conversation uses a worker matching its configured provider and security profile, never the caller's busy primary lane. An omitted provider inherits `agent.provider`; an omitted profile uses an ACP provider's declared `container_profile` when present, otherwise `workspace`. An ACP provider runs on the host only, so on a container-enabled deployment give the agent `execution: host` — a resolved container policy is refused before the turn starts rather than weakened. The built-in `search` agent explicitly requests `restricted`. If that profile is unavailable, the turn fails closed; select `workspace` explicitly only when host access is acceptable. Configure capacity with `providers.<id>.pool_size`. If no matching worker can be acquired or spawned, the tool returns an inline error naming the unavailable provider/profile and capacity setting. User and assistant messages are persisted and replayed when a different worker continues the session. Successful logical-agent sessions are retained for diagnostics and ordinary maintenance, but hidden from normal session and sidebar lists. A failed or content-blocked first turn is archived because no handle was returned to the caller.

Caller cancellation does not currently propagate into an in-flight `sessions_spawn` or `sessions_send` turn. The MCP gateway's 120-second tool timeout also returns without cancelling the underlying child turn, so its worker remains occupied until that turn completes or its harness timeout fires. Causal parent-to-child cancellation is planned with the caller-aware MCP dispatch work (Knowledge Interop & Steward milestone).

### Tool Policy Cascade

On logical-agent turns, tool access is evaluated by `ToolPolicyGuard` through a 3-layer policy (most restrictive wins):

1. **Global deny** — `agent.disallowed_tools` blocks tools for the main agent and every logical agent
2. **Agent deny** — `denied_tools` blocks tools for that specific logical agent
3. **Sandbox allow** – a non-empty `tools` list is a closed allowlist

See [Hardening the primary agent for untrusted channels](security.md#hardening-the-primary-agent-for-untrusted-channels)
for using `agent.disallowed_tools` to withhold tools from a primary lane exposed to untrusted channel content.

The active turn's agent identity is threaded through each provider interception path before this evaluation. Claude registers an unfiltered `PreToolUse` hook so built-ins and dynamically named MCP tools reach the host guard. When Claude defers an allowlisted tool behind `ToolSearch`, DartClaw permits that schema-discovery step but evaluates the selected tool separately against the closed policy; discovery does not grant the capability. Codex enforcement exists only for operations that emit approval requests: `on-request` is the broadest available interception, `unless-allow-listed` is partial, and `never` bypasses the host guard. Disabling the optional security-guard bundle leaves configured tool policy and per-turn filters active. ACP enforcement covers host reverse file calls and permission requests only; operations that request no permission do not reach the guard. DartClaw warns at startup when configured agent policy cannot be fully mediated by the selected provider posture.

### Capacity Boundary

The execution coordinator is the single post-governance capacity authority. It owns one fixed, serialized primary lane for main user and channel turns. Separately, `providers.<id>.pool_size` is a hard concurrent worker-lease limit for that provider across background tasks, scheduled/system work, and logical-agent conversations. A logical agent may start another logical-agent session when policy permits and capacity remains; exhausted nested capacity fails immediately instead of waiting on a worker held by its caller.

Workers are created lazily. Harness-construction inputs are fixed for a coordinator's lifetime, so after a lease is released a healthy idle host worker may be retained and reused only when its provider and security profile match. A logical-agent container is retained only for that exact session/agent owner across its turns and destroyed on discard, eviction, or shutdown; it never crosses principals. The number of profiles or retained containers does not consume or enlarge active worker lease capacity.

If the primary agent runs in a container (an opt-in posture; the default keeps the primary on the host) and that container is lost — `docker rm`, an OOM kill, or a daemon restart — the primary lane cannot recover on its own: restart the service to recover. A distinct critical signal names this case separately from a per-task container crash.

Migration note: `web_search` is now distinct from `web_fetch`. Policies that intended to permit both must list both; naming only `web_fetch` no longer permits search.

The experimental `delegate_to_agent` tool and `delegation:` configuration were removed. Move agent definitions to `agent.agents` and use `sessions_spawn`; use the returned handle with `sessions_send` for follow-ups. `tasks.max_concurrent` was also removed – configure the shared capacity with `providers.<id>.pool_size`.

Useful controls from that preview path now use existing shared mechanisms: agent/provider selection and `security_profile` live on the logical-agent definition; `governance.rate_limits.global` and `governance.budget` apply to turns; `governance.turn_limits.turn_timeout` bounds turn execution; and content/tool guards remain on the normal turn path. The per-call `work_dir`, security-mode label, separate delegation rate limit, and separate token-accounting model were intentionally not retained because they duplicated or bypassed those host policies.

### Content-Guard Boundary

Every result returned via `sessions_spawn` or `sessions_send` passes through the content-guard before reaching the main agent. This prevents poisoned web content or prompt injection from propagating. If the guard blocks the result, the main agent receives an error message instead.

## Background Tasks

Background tasks are a separate execution model for structured, reviewable work. Unlike logical-agent conversations, tasks are independent work units with their own lifecycle, artifacts, and review flow.

### How Tasks Differ from Logical-Agent Sessions

| | Logical-agent sessions | Background tasks |
|---|-----------|-------------|
| **Triggered by** | Main agent via `sessions_spawn` / `sessions_send` | Task queue (API, web UI, automation schedule) |
| **Execution** | Within the caller's turn | Independent background execution |
| **Harness** | Provider-matched leased worker | Provider-matched leased worker |
| **Tool access** | Optional closed allowlist; empty means unrestricted | Full agent tools (same as main chat) |
| **Review** | None — result returned inline | Review workflow (accept/reject/push-back) |
| **Artifacts** | None | Structured diffs, files, logs |
| **Config** | `agent.agents.<id>` in YAML | `tasks.*` in YAML + per-task `configJson` at creation |
| **Lifecycle** | Synchronous wait | State machine (draft → queued → running → review → accepted) |

### Execution Capacity

The execution coordinator manages admission and optional reuse:

- **Primary lane** – exactly one serialized runner for main user and channel conversations. It always uses `agent.provider` and is never loaned to background work.
- **Worker leases** – hard per-provider capacity shared by tasks, cron/system execution, and logical-agent sessions. Workers spawn lazily and never fall back to the busy primary lane.
- **Workflow worker leases** – workflow steps consume provider capacity on the guarded harness path.

Configure capacity per provider with `providers.<id>.pool_size`. Without an explicit provider entry, the selected default provider gets worker-lease capacity `1`.

```yaml
providers:
  claude:
    executable: claude
    pool_size: 3
```

With `pool_size: 3`, the deployment keeps its one primary lane and permits at most three concurrent worker leases for that provider. The value is a hard ceiling, not a target process count.

### Container Profile Routing

Tasks default to the neutral `workspace` profile. An operator can declare `restricted` through the authenticated
task API when a task must have no workspace mount:

| Declaration | Profile | Mounts |
|-------------|---------|--------|
| Omitted or `workspace` | `workspace` | `/workspace:rw`, `/project:ro` |
| `restricted` | `restricted` | No workspace |

`TaskExecutor` requests a lease for the task's exact provider and declared profile. A `restricted` task cannot reuse
a `workspace` worker. Retired `research` input is refused rather than silently widened; declare
`securityProfile: "restricted"` through the authenticated API instead.

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
| Configured ACP ID | ACP-compatible binary | ACP stdio JSON-RPC | Agent-specific | Admitted only against a verified target profile from `harness.acp.agents`; host execution on the long-lived surface only; `requires_guard_mediation: true` is refused at startup; terminal reverse-calls, model overrides and effort overrides are not forwarded |

Core Claude and Codex turns are supported on native Windows. Their sandbox capabilities are not equivalent to the
POSIX container boundary: Claude's native sandbox is unavailable, and restrictive Codex sandbox modes were not part
of the Windows qualification. See [Windows](windows.md#capability-matrix).

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
  "title": "Analyze competitor pricing",
  "description": "Compare current public pricing tiers and summarize the differences.",
  "provider": "codex",
  "configJson": { "model": "gpt-5" }
}
```

This acquires Codex worker capacity regardless of the global `agent.provider` setting.

### Provider Routing

| Scope | Config | Behavior |
|-------|--------|----------|
| **Global default** | `agent.provider: claude` | Fixed provider for primary interactive sessions; default for background routing |
| **Per-agent** | `agent.agents.<id>.provider` | Logical-agent conversations use the configured provider |
| **Per-task** | `provider` field on task creation | Task acquires a harness from the specified provider's pool |
| **Worker capacity** | `providers.<id>.pool_size` | Hard concurrent worker-lease limit for each provider |

The primary lane always uses the global default provider. Interactive session creation has no provider override. Background tasks and logical-agent conversations can mix providers; every logical-agent session remains pinned to the provider resolved when it was created.

### Codex Approval Policy & Sandbox Mode

The Codex app-server provider supports two per-turn settings that control how Codex handles tool execution internally:

| Config key | Values | Default | Purpose |
|---|---|---|---|
| `approval` | `on-request`, `unless-allow-listed`, `never` | *(inherited from Codex)* | Whether Codex sends tool approval requests to DartClaw |
| `sandbox` | `workspace-write`, `danger-full-access` | *(none — Codex default)* | Codex-side filesystem sandbox restrictions |

**`approval` values:**
- `on-request` — broadest available interception; DartClaw evaluates every operation Codex routes through an approval request
- `unless-allow-listed` — partial interception; commands in Codex's built-in safe list emit no approval request
- `never` — no approval requests; the host guard cannot mediate Codex tool calls

Set `approval: on-request` explicitly for a tool-restricted Codex agent. When omitted, DartClaw leaves the option out of
the provider request and Codex may inherit user or provider configuration; serve therefore warns instead of assuming
that host interception is active.

**`sandbox` values:**
- `workspace-write` — Codex sandbox allows writes only to the working directory
- `danger-full-access` — No Codex-side sandbox restrictions

> **Known issue — approval deadlock**: Codex's app-server has an upstream bug ([openai/codex#11816](https://github.com/openai/codex/issues/11816), open as of March 2026) where tool approval requests block indefinitely with no provider-side timeout. This causes turns that involve file creation, shell commands, or other tool use to hang silently — while simple conversational turns succeed. The `SessionLockManager` holds the per-session lock until the approval resolves or `governance.turn_limits.turn_timeout` cancels the turn. Stall detection is suspended during a known approval wait.
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
> Setting `approval: never` disables Codex's *internal* approval gate. No Codex `beforeToolCall` approval reaches DartClaw's
> guard chain in this mode. On POSIX deployments with containers enabled, container isolation still applies. On native Windows,
> container isolation is unavailable and restrictive Codex sandbox behavior is unverified. Message/content checks remain
> independent of tool-call approvals, but this configuration has no DartClaw tool-call guard and is not POSIX sandbox parity.
>
> Also consider reducing `governance.turn_limits.turn_timeout` (default 1800s) to 120s for shared-session scenarios to limit blast radius if other hang causes occur (context compaction, orphaned child processes).

### Codex Skill Loading

Codex CLI exposes installed skills through a `<skills_instructions>` available-skills index in the initial model context. Codex 0.121+ loads only skill metadata (name, description, and path), not full skill bodies. Full `SKILL.md` instructions are read from disk only when a skill is invoked or opened. If you are running an older Codex release without this optimization, every workflow turn pays the full skill-body cost; upgrade to 0.121+ to restore the metadata-only behavior.

DartClaw therefore uses Codex's native skill loading directly. Runtime-provisioned workflow skills are installed under `<dataDir>/.agents/skills/` with the `dartclaw-` prefix, AndThen-provided Codex agents are installed under `<dataDir>/.codex/agents/`, and each configured project/worktree receives per-skill links into those data-dir payloads. DartClaw does not symlink Codex auth files and does not inline skill bodies into prompts.

Which Codex home a host turn runs against depends on the credential the host presents:

- **API key** (`providers.codex.auth: api_key`, or `auto` with no subscription credential stored): unchanged. Host harness workers use the normal Codex profile and OAuth state unless `providers.codex.use_system_codex_home: false` establishes an isolated home seeded from `~/.codex/auth.json`.
- **ChatGPT subscription** (`providers.codex.auth: subscription`, with a credential stored in DartClaw's own store): every host harness worker runs with `CODEX_HOME` pointed at the DartClaw-dedicated store under `<dataDir>/credentials/codex`. That store is the one you log into with `codex login`; DartClaw never reads, copies, or writes your own `~/.codex` login, and `use_system_codex_home` does not apply.

This keeps authentication and provider behavior aligned with ordinary `codex` CLI usage while keeping DartClaw-managed skill payloads scoped to the configured data directory.

### Provider Capability Differences

Not all providers support every feature. DartClaw degrades gracefully:

| Capability | Claude | Codex | ACP |
|-----------|--------|-------|-----|
| Streaming text | Yes | Yes | Yes |
| Tool approval (guard chain) | Yes (via hooks) | Yes (via JSON-RPC approvals) | No guard-mediated classification; filesystem reverse-calls and permission requests are evaluated, but other operations remain host-only |
| USD cost reporting | Yes | No (token counts only) | Agent-specific |
| Crash recovery | Yes | Yes | Yes |
| Per-turn persona | Process restart with `--append-system-prompt` | Session thread `developerInstructions` | Prepended to the prompt text |
| Per-turn model and effort | Yes | Yes | Ignored |
| MCP server support | Yes | Yes (via `config.toml`) | Agent-specific |

When a provider doesn't report cost, the UI shows token counts with a "cost unavailable" indicator. For Codex sessions, the sidebar labels input as fresh input and shows cached input separately so Claude and Codex totals are comparable.

### Provider Status

Check provider health at `GET /api/providers` or on the Settings page. DartClaw reports:
- Whether the binary was found on `$PATH` (or at the configured executable path)
- Detected version (from `--version` probe at startup)
- Credential status (API key present/missing)
- Credential health once it has been checked: credential mode, expiry (flagged when derived), last-checked time,
  health state, and the remediation command when action is needed
- Lease-derived configured/effective/active/queued/cached/quarantined worker counts

## Choosing the Right Model

| Use case | Agent model | Why |
|----------|------------|-----|
| Quick web lookup during chat | Logical agent (`search`) | Sandboxed, durable session, result scanned by content-guard |
| Summarize a document for the main agent | Custom logical agent (`summarizer`) | Restricted tools, inline result, no review needed |
| Write and test a new feature | Task with `needsWorktree: true` | Isolated checkout and worktree-scoped review |
| Background research report | Task with declared `restricted` profile | Independent work, restricted container, reviewable output |
| Recurring maintenance check | Cron job (not an agent) | Lightweight, no review, uses bounded background capacity |

Note: cron jobs and heartbeat are **not** separate agents. They use the global `agent.model` by default but acquire worker capacity rather than occupying the primary lane. See [Scheduling](scheduling.md).
