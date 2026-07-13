# Control Protocol & Harness Architecture

Canonical reference for DartClaw's provider control protocols and the Dart-side harness infrastructure that drives them. DartClaw supports three subprocess protocol families today: Claude Code's ad-hoc JSONL control protocol, Codex's JSON-RPC 2.0-like JSONL app-server protocol, and ACP stdio JSON-RPC for verified ACP agents.

**Current through**: 0.21

---

## 1. Protocol Overview

DartClaw communicates with provider binaries over bidirectional subprocess protocols on stdin and stdout. Claude Code uses JSONL, Codex app-server uses JSON-RPC-like JSONL, and ACP agents use ACP stdio JSON-RPC.

| Dimension | Claude Code protocol | Codex JSON-RPC JSONL protocol | ACP stdio JSON-RPC protocol |
|---|---|---|---|
| Wire format | Ad-hoc JSONL messages over stdin/stdout | JSON-RPC 2.0-like messages over stdin/stdout, serialized as JSONL | JSON-RPC 2.0 over subprocess stdio |
| Direction | DartClaw sends turn and control requests; the binary streams events, control requests, and results back | DartClaw sends `initialize`, `initialized`, `thread/start`, and `turn/start`; Codex streams notifications and approval requests back | `AcpHarness` drives ACP session methods; direct agents may make host reverse-calls for filesystem operations |
| Lifecycle | Spawn `claude`, initialize once, then send user turns against the long-lived process | Spawn `codex app-server`, complete `initialize`/`initialized`, create a thread, then send turns against that thread | Spawn configured ACP binary such as `goose acp` or `vibe-acp`, initialize once, then route turns through `AcpClient` |
| Streaming | `content_block_delta`, assistant/tool blocks, and `compact_boundary` compaction markers | `item/agentMessage/delta`, `item/started`, `item/completed`, `turn/completed`, `turn/failed` | ACP session updates adapted into DartClaw bridge events by `AcpProtocolAdapter` |
| Tool approval | `control_request` plus hook callbacks (`can_use_tool`, `PreToolUse`, `PostToolUse`, `PermissionDenied`, `PreCompact`) | JSON-RPC approval requests from server to client; DartClaw evaluates guards and replies allow/deny | Handler-level reverse-calls route through `GuardChain.evaluateBeforeToolCall(...)` before host file or terminal actions |
| Session continuity | DartClaw owns persistence and replay; provider session state is not trusted as the source of truth | DartClaw also owns continuity; cached thread IDs are cleared on crash and history is replayed into a new thread | DartClaw owns persistence and classifies each ACP agent at registration/startup; relay and unverified topologies are container-isolation-only |

### Workflow One-Shot Exception

Workflow-owned bounded agent steps now always use the one-shot execution path. In that mode, DartClaw still owns the task row, workflow state, session transcript, budget checks, and structured-output persistence, but the provider binary is invoked directly per workflow prompt (`claude -p` / `codex exec`) instead of reusing the interactive app-server/stream-json subprocess.

This is intentionally a workflow-only exception:

- Interactive chat, channels, cron, and ordinary task turns remain on the long-lived streaming harnesses.
- Workflow YAML step types are preserved on the hydrated `WorkflowStepExecution` side-table row (`stepType`); the workflow runtime dispatches every workflow step through the coding-task path and expresses write intent through `readOnly` (set on the task config when `step_config_policy.stepIsReadOnly()` holds).
- `format: json` with `schema` defaults to native structured output. The heuristic JSON parser is retained only as a post-failure fallback.
- **One-shot stdout is streamed, not buffered** – and this is load-bearing for operability, not cosmetic. Both providers emit incremental NDJSON on stdout for the duration of the turn: `claude -p --output-format stream-json --verbose --include-partial-messages` (the terminal `type: "result"` event carries the result text, `session_id`, cost, and the `usage.{input_tokens,output_tokens,cache_read_input_tokens,cache_creation_input_tokens}` counts) and `codex exec --json`. The CLI stall monitor (FR00/TD-062) resets its silence timer on each stdout line, so the older buffered single-object mode (`claude -p --output-format json`, which emits one object only at completion) starved it of any liveness signal and false-tripped on every turn longer than `governance.turn_progress.stall_timeout` – even while the provider was actively working. Streaming restores the per-line liveness that keeps stall detection meaningful for long claude turns (e.g. the opus review council).

```
┌─────────────────────────────────────┐
│         Dart Host (AOT binary)      │
│  ───────────────────────────────    │
│  ClaudeCodeHarness                  │
│    ↕ stdin (JSONL)                  │
│    ↕ stdout (JSONL)                 │
│  claude CLI binary (Bun standalone) │
└─────────────────────────────────────┘
```

### Why stdio subprocess protocols?

| Alternative | Why rejected |
|---|---|
| HTTP/WebSocket | Requires a listening port; complicates Docker `network:none` isolation |
| gRPC | Heavy dependency; schema versioning overhead for a single-consumer protocol |
| Shared memory | Breaks process isolation – DartClaw's core security property |
| Named pipes/Unix sockets | No advantage over stdin/stdout for a parent-child relationship; adds platform-specific wiring |

stdin/stdout is the natural IPC channel for a parent-child process pair. Dart's `dart:io` `Process` API provides direct access to both streams, while each provider keeps its own framing: JSONL for Claude and Codex, JSON-RPC for ACP. The transport works identically whether the binary runs directly on the host or inside a Docker container (via `docker exec -i`).

ACP also uses subprocess stdio, but with JSON-RPC 2.0 framing rather than JSONL event names. DartClaw implements the ACP client surface directly on `json_rpc_2`; `acp_dart` and `dart_acp` remain reference material only. HTTP+SSE and WebSocket ACP daemon modes are not 0.18 targets.

### Design lineage

The JSONL control protocol is not DartClaw-specific. It is the published interface of the `claude` binary, documented in the [Claude Code headless docs](https://code.claude.com/docs/en/headless) and independently implemented in official and community SDKs:

| Runtime | Implementation |
|---|---|
| TypeScript | `@anthropic-ai/claude-agent-sdk` (official) |
| Python | `claude-agent-sdk-python` (official) |
| Go | `claude-agent-sdk-go` (community) |
| Elixir | `claude_agent_sdk` on hex.pm (community) |
| **Dart** | `ClaudeCodeHarness` in `dartclaw_core` (DartClaw) |

DartClaw eliminated the TypeScript SDK layer entirely (see [ADR-001 Addendum](../adrs/001-sdk-integration-and-security-architecture.md)). The SDK is a convenience wrapper, not a capability gate – all features are accessible over the raw protocol.

---

### Claude Code Protocol

The next sections describe the Claude Code path in full. It remains the baseline provider protocol.

## 2. Spawn Configuration

The `claude` binary is spawned with specific flags that enable the control protocol.

### CLI arguments

Built by `_buildClaudeArgs()` in `claude_code_harness.dart`:

```
claude --print \
       --input-format stream-json \
       --output-format stream-json \
       --verbose \
       --include-partial-messages \
       --no-session-persistence \
       --dangerously-skip-permissions \      # default; replaced by the permission flags below per the matrix
       [--permission-mode <mode>] \
       [--permission-prompt-tool stdio] \
       [--setting-sources project] \
       [--settings <json>] \
       --model opus[1m] \
       [--effort <level>] \
       [--append-system-prompt <prompt>] \
       [--mcp-config <path>]
```

| Flag | Purpose |
|---|---|
| `--print` | Output mode (non-interactive) |
| `--input-format stream-json` | Accept JSONL on stdin |
| `--output-format stream-json` | Emit JSONL on stdout |
| `--verbose` | Include all stream events (not just final result) |
| `--include-partial-messages` | Emit `assistant` messages with partial tool blocks |
| `--no-session-persistence` | Disable the binary's own session storage; DartClaw manages persistence |
| `--dangerously-skip-permissions` | Disable Claude's native permission gate (which assumes an interactive TTY); DartClaw's own guard chain, `disallowedTools`, and container isolation are the real enforcement boundary. **Default** – emitted when no `permissionMode` is configured and the profile is not `restricted`. See the permission-flag matrix below |
| `--permission-mode <mode>` | Emitted only when `providers.claude.options.permissionMode` is set, to one of Claude's canonical modes (`acceptEdits`, `auto`, `bypassPermissions`, `default`, `dontAsk`, `plan`) |
| `--permission-prompt-tool stdio` | Route tool approval requests through the JSONL `can_use_tool` channel (not an interactive TTY). Emitted only when native permissions are *not* skipped – the `restricted` container profile, or a non-`bypassPermissions`/`dontAsk` `permissionMode`. **Not** emitted in the default config |
| `--setting-sources project` | Project-only settings isolation. Omitted by default so Claude loads user, project, and local settings; emitted only when `providers.claude.inherit_user_settings: false` |
| `--settings <json>` | Inline settings JSON (sandbox / permissions allow-deny). Emitted only when the provider's `sandbox`/`permissions`/`settings` options are present |
| `--model` | Model selection – bare names (`haiku`, `sonnet`, `opus`) or with context suffix (`opus[1m]`). Default: `opus[1m]`. Configurable via `HarnessConfig` |
| `--effort` | Reasoning effort level: `low`, `medium`, `high`, `max` (optional; configurable via `HarnessConfig`) |
| `--append-system-prompt` | Behavior content injected at spawn (append-mode strategy) |
| `--mcp-config` | Path to ephemeral MCP config file pointing at DartClaw's internal MCP server |

#### Permission-flag selection

Claude's native permission UX assumes an interactive TTY, so DartClaw normally disables it and relies on its own defense-in-depth (PreToolUse hook → `GuardChain`, the `disallowedTools` blocklist, and container isolation) as the real enforcement boundary. The exact permission flags are chosen by `_buildClaudeArgs()` / the spawn site in `claude_code_harness.dart` from the configured `providers.claude.options.permissionMode` and the security profile:

| Condition | Permission flags emitted |
|---|---|
| No `permissionMode`, non-`restricted` profile (**default**) | `--dangerously-skip-permissions` (no prompt tool; `can_use_tool` is suppressed) |
| No `permissionMode`, `restricted` container profile | `--permission-prompt-tool stdio` (native prompts kept; tool requests flow through the JSONL `can_use_tool` channel) |
| `permissionMode: bypassPermissions` or `dontAsk` | `--permission-mode <mode>` only |
| `permissionMode: acceptEdits` / `auto` / `default` / `plan` | `--permission-mode <mode>` + `--permission-prompt-tool stdio` |

Regardless of which row applies, the registered `PreToolUse` hook still fires and runs the guard chain – disabling the native gate does not disable DartClaw's enforcement.

### Environment stripping

The subprocess environment is sanitized to prevent nesting detection errors:

```dart
const claudeNestingEnvVars = [
  'CLAUDECODE',
  'CLAUDE_CODE_ENTRYPOINT',
  'CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS',
];
```

These are stripped before spawning. The parent environment is otherwise inherited (`includeParentEnvironment: false` with a filtered copy of `Platform.environment`).

### Claude settings sources

Direct host-side Claude spawns omit `--setting-sources` by default. Claude's default is to load user, project, and local settings, which makes user-scope plugins, skills, agents, commands, and MCP configuration visible to spawned sessions and workflow one-shots. Set `providers.claude.inherit_user_settings: false` to restore the previous project-only posture; DartClaw then passes `--setting-sources project` before `--model` on long-lived harness spawns and before prompt execution on the workflow one-shot path. Containerized Claude spawns do not use this flag because the container provides the isolation boundary.

### Containerized spawning

When a `ContainerManager` is configured, the binary runs inside a Docker container via `docker exec -i`. The container is pre-created with security hardening (`--network none`, `--cap-drop ALL`, `--read-only`, `--security-opt no-new-privileges`) and kept alive via `sleep infinity`. Each turn invokes `docker exec` against the running container – no per-turn container startup cost.

---

## 3. Message Format

All messages are single-line JSON objects. The top-level `type` field determines the message category.

### Dart → claude (stdin)

| Type | When sent | Purpose |
|---|---|---|
| `control_request` | Once at startup | Initialize handshake: register hooks, MCP servers, config |
| `user` | Each turn | User message with optional system prompt |

### claude → Dart (stdout)

| Type | When emitted | Purpose |
|---|---|---|
| `system` | Start of each turn | Session metadata (session ID, tools, context window) |
| `stream_event` | During generation | Incremental content (text deltas) |
| `assistant` | After generation | Complete message with tool_use/tool_result blocks |
| `control_request` | On tool use | Tool approval and hook callback requests |
| `control_response` | After init handshake | Response to Dart's initialize request |
| `result` | End of turn | Turn completion with cost/token/duration metadata |

---

## 4. Protocol Messages (with examples)

### 4.1 Initialize Handshake

The first exchange after spawning. Dart sends an `initialize` control request; the binary responds with session capabilities.

**Dart → claude:**

```json
{
  "type": "control_request",
  "request_id": "req_init_1710234567890",
  "request": {
    "subtype": "initialize",
    "hooks": {
      "PreToolUse": [
        {
          "matcher": null,
          "hookCallbackIds": ["hook_pre_tool"],
          "timeout": 30
        }
      ],
      "PostToolUse": [
        {
          "matcher": null,
          "hookCallbackIds": ["hook_post_tool"],
          "timeout": 10
        }
      ]
    },
    "disallowedTools": ["WebSearch"],
    "maxTurns": 25,
    "model": "sonnet",
    "agents": { "reviewer": { "description": "...", "prompt": "..." } }
  }
}
```

Key fields in the `request` object:

| Field | Source | Description |
|---|---|---|
| `hooks` | Hardcoded | `PreToolUse` (30s, filtered with Claude `if:` to tool types DartClaw guards), `PostToolUse` (10s, audit), `PermissionDenied` (10s, audit), and `PreCompact` (10s, compaction signal) |
| `disallowedTools` | `HarnessConfig.disallowedTools` | Tool blocklist enforced by the binary |
| `maxTurns` | `HarnessConfig.maxTurns` | Safety cap on agentic loops |
| `model` | `HarnessConfig.model` | Model override (supports `[1m]` suffix for extended context, e.g. `opus[1m]`) |
| `agents` | `HarnessConfig.agents` | Sub-agent definitions |
| `sdkMcpServers` | Fallback only | In-protocol MCP tools (used when no HTTP MCP server is configured) |

**claude → Dart:**

```json
{
  "type": "control_response",
  "response": {
    "subtype": "success",
    "request_id": "req_init_1710234567890",
    "response": { ... }
  }
}
```

The harness waits up to 10 seconds for this response. Timeout kills the process.

### 4.2 System Init Event

Emitted by the binary at the start of each turn response. The session ID remains stable across turns within the same process; the tool list and context window may change (e.g. after context compaction).

**claude → Dart:**

```json
{
  "type": "system",
  "subtype": "init",
  "session_id": "abc-123-def",
  "tools": ["Bash", "Read", "Write", "Edit", "Glob", "Grep", "..."],
  "context_window": 200000
}
```

Parsed into `SystemInit(sessionId, toolCount, contextWindow)`. The session ID persists across turns within the same process. The context window size is forwarded to the `ContextMonitor` for pre-compaction flush decisions.

### 4.3 User Message (Turn Start)

**Dart → claude:**

```json
{
  "type": "user",
  "message": { "role": "user", "content": "What is 2+2?" }
}
```

For harnesses using `PromptStrategy.replace`, a `system_prompt` field is included:

```json
{
  "type": "user",
  "message": { "role": "user", "content": "What is 2+2?" },
  "system_prompt": "You are DartClaw, a security-hardened agent..."
}
```

`ClaudeCodeHarness` uses `PromptStrategy.append` (system prompt injected via `--append-system-prompt` at spawn), so the `system_prompt` field is omitted during normal operation.

For resumed sessions, a `"resume": true` field is added.

### 4.4 Stream Events (Text Deltas)

Incremental text output during generation.

**claude → Dart:**

```json
{
  "type": "stream_event",
  "event": {
    "type": "content_block_delta",
    "delta": { "type": "text_delta", "text": "The answer is " }
  }
}
```

Only `content_block_delta` events with `text_delta` deltas are extracted. Other stream events (`content_block_start`, `content_block_stop`, `message_start`, `message_stop`, `input_json_delta`) are intentionally ignored – they carry lifecycle metadata, not content.

Parsed into `StreamTextDelta(text)`, then emitted as `DeltaEvent(text)` on the harness event stream.

### 4.5 Assistant Messages (Tool Use / Tool Result)

Complete messages containing tool invocations and results. Text blocks in `assistant` messages are intentionally skipped (text comes from stream events to avoid double-counting).

**Tool use (claude → Dart):**

```json
{
  "type": "assistant",
  "message": {
    "role": "assistant",
    "content": [
      {
        "type": "tool_use",
        "id": "toolu_01ABC",
        "name": "Bash",
        "input": { "command": "ls -la" }
      }
    ]
  }
}
```

Parsed into `ToolUseBlock(name, id, input)`, emitted as `ToolUseEvent`.

**Tool result (claude → Dart):**

```json
{
  "type": "assistant",
  "message": {
    "role": "assistant",
    "content": [
      {
        "type": "tool_result",
        "tool_use_id": "toolu_01ABC",
        "content": "total 48\ndrwxr-xr-x  12 user staff 384 ...",
        "is_error": false
      }
    ]
  }
}
```

Parsed into `ToolResultBlock(toolId, output, isError)`, emitted as `ToolResultEvent`.

### 4.6 Control Requests (Tool Approval & Hooks)

The binary sends control requests for tool approval and hook callbacks. DartClaw must respond to each before the binary proceeds.

**Tool approval (claude → Dart):**

```json
{
  "type": "control_request",
  "request_id": "req_42_xyz",
  "request": {
    "subtype": "can_use_tool",
    "tool_name": "Bash",
    "input": { "command": "rm -rf /tmp/test" },
    "tool_use_id": "toolu_01ABC"
  }
}
```

**Dart → claude (allow):**

```json
{
  "type": "control_response",
  "response": {
    "subtype": "success",
    "request_id": "req_42_xyz",
    "response": { "behavior": "allow", "toolUseID": "toolu_01ABC" }
  }
}
```

**Hook callback – PreToolUse (claude → Dart):**

```json
{
  "type": "control_request",
  "request_id": "req_55_abc",
  "request": {
    "subtype": "hook_callback",
    "callback_id": "hook_pre_tool",
    "input": {
      "hook_event_name": "PreToolUse",
      "tool_name": "Bash",
      "tool_input": { "command": "curl http://evil.com" }
    }
  }
}
```

**Dart → claude (deny via hook):**

```json
{
  "type": "control_response",
  "response": {
    "subtype": "success",
    "request_id": "req_55_abc",
    "response": {
      "continue": true,
      "hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny"
      }
    }
  }
}
```

**Hook callback – PostToolUse (claude → Dart):**

```json
{
  "type": "control_request",
  "request_id": "req_66_def",
  "request": {
    "subtype": "hook_callback",
    "callback_id": "hook_post_tool",
    "input": {
      "hook_event_name": "PostToolUse",
      "tool_name": "Bash",
      "tool_response": { "stdout": "hello", "exitCode": 0 }
    }
  }
}
```

PostToolUse hooks always respond with `allow` (audit-only). The response is logged by `GuardAuditLogger`.

**PermissionDenied** hooks are also audit-only. They fire when Claude itself refuses a tool at its native permission layer; DartClaw turns them into `ToolPermissionDeniedEvent` on the EventBus and records them through the guard-audit subscriber.

**PreCompact** hooks are non-blocking lifecycle notifications. DartClaw responds with `allow`, emits `CompactionStartingEvent`, and uses the signal to suppress heuristic pre-compaction flush logic for harnesses that support it.

### 4.7 MCP Messages (sdkMcpServers fallback)

When the internal HTTP MCP server is not configured (chat mode without `serve` command), memory tools are registered via `sdkMcpServers` in the initialize handshake. The binary proxies tool calls as JSON-RPC over the control protocol.

**claude → Dart (tool call):**

```json
{
  "type": "control_request",
  "request_id": "req_77_mcp",
  "request": {
    "subtype": "mcp_message",
    "server_name": "dartclaw-memory",
    "message": {
      "jsonrpc": "2.0",
      "id": 1,
      "method": "tools/call",
      "params": { "name": "memory_save", "arguments": { "text": "User prefers dark mode" } }
    }
  }
}
```

**Dart → claude (tool result):**

```json
{
  "type": "control_response",
  "response": {
    "subtype": "success",
    "request_id": "req_77_mcp",
    "response": {
      "mcp_response": {
        "jsonrpc": "2.0",
        "id": 1,
        "result": { "content": [{ "type": "text", "text": "Saved to memory." }] }
      }
    }
  }
}
```

This mechanism is superseded by the internal HTTP MCP server (see section 9) when running in serve mode. See [ADR-009](../adrs/009-internal-mcp-server.md) for the migration rationale.

### 4.8 Turn Result

Signals the end of a turn with cost and token metadata.

**claude → Dart:**

```json
{
  "type": "result",
  "stop_reason": "end_turn",
  "total_cost_usd": 0.0042,
  "duration_ms": 3500,
  "usage": {
    "input_tokens": 1200,
    "output_tokens": 350
  }
}
```

Parsed into `TurnResult(stopReason, costUsd, durationMs, inputTokens, outputTokens, cacheReadInputTokens, cacheCreationInputTokens)`. Completes the pending `_turnCompleter` future, ending the `turn()` call.

---

## 5. Dart-Side Type Hierarchy

### ClaudeMessage (sealed class)

All JSONL messages from the binary are parsed into a sealed `ClaudeMessage` hierarchy in `claude_protocol.dart`:

```
ClaudeMessage (sealed)
├── SystemInit          – session_id, toolCount, contextWindow
├── StreamTextDelta     – text
├── ToolUseBlock        – name, id, input
├── ToolResultBlock     – toolId, output, isError
├── ControlRequest      – requestId, subtype, data
└── TurnResult          – stopReason, costUsd, durationMs, inputTokens, outputTokens,
                          cacheReadInputTokens, cacheCreationInputTokens
```

Parsing is done by `parseJsonlLine(String line)` which returns `ClaudeMessage?` – `null` for malformed JSON, unknown types, or irrelevant lifecycle events.

### BridgeEvent (sealed class)

The harness transforms `ClaudeMessage` instances into higher-level `BridgeEvent`s for consumer code:

```
BridgeEvent (sealed)
├── DeltaEvent          – text
├── ToolUseEvent        – toolName, toolId, input
├── ToolResultEvent     – toolId, output, isError
├── SystemInitEvent     – contextWindow
├── CompactionStartingBridgeEvent   – Codex `contextCompaction` started
└── CompactionCompletedBridgeEvent  – Codex `contextCompaction` completed
```

`ControlRequest` and `TurnResult` are handled internally by the harness and never forwarded to consumers. `ToolUseEvent` and `ToolResultEvent` are also used internally for `ToolCallRecord` correlation (see [Enriched Turn Data Extraction](#7-enriched-turn-data-extraction)).

---

## 6. Turn Lifecycle

A complete turn flows through multiple layers. The following diagram shows the full path from user message to stored response.

```
User (Web/Channel/Cron/Task)
  │
  ▼
TurnManager.startTurn(sessionId, messages)
  │ delegates to primary TurnRunner (or acquired pool runner for tasks)
  ▼
TurnRunner.reserveTurn(sessionId)
  │ ① Acquire session lock (SessionLockManager)
  │ ② Generate turnId (UUID v4)
  │ ③ Persist turn state to TurnStateStore (`state.db`) for crash recovery
  ▼
TurnRunner.executeTurn(sessionId, turnId, messages)
  │ launches _runTurn() as unawaited async
  ▼
_runTurn()
  │
  │ ④ Pre-turn guard: GuardChain.evaluateMessageReceived()
  │   └─ block → insert "[Blocked by guard: ...]" → return failed outcome
  │
  │ ⑤ Build system prompt (BehaviorFileService.composeSystemPrompt())
  │   └─ Appends compact instructions for long-running sessions (web, DM, group, cron)
  │
  │ ⑥ Subscribe to harness.events stream
  │   ├─ DeltaEvent      → buffer + progress reset + session activity touch
  │   ├─ ToolUseEvent    → tool log + progress reset + session activity touch
  │   ├─ ToolResultEvent → tool correlation + progress reset + session activity touch
  │   └─ SystemInitEvent → context-window update only (not counted as progress)
  │
  ▼
AgentHarness.turn(sessionId, messages, systemPrompt, directory?, model?)
  │
  │ ⑦ Restart harness if working directory or model changed
  │ ⑧ If crashed: exponential backoff (baseBackoff × 2^(crashCount-1))
  │ ⑨ Set state → busy
  │ ⑩ Start timeout timer (default 600s)
  │
  │ ⑪ Build user message payload:
  │     { "type": "user", "message": { "role": "user", "content": "..." } }
  │
  │ ⑫ Write payload as JSONL to process stdin
  ▼
claude binary (internal processing)
  │
  │ ── stream_event (text_delta) ──────► DeltaEvent → buffer.write()
  │ ── assistant (tool_use) ───────────► ToolUseEvent → toolEvents.add()
  │ ── control_request (can_use_tool) ─► toolPolicy → allow/deny response
  │ ── control_request (hook_callback)
  │    ├─ PreToolUse ──────────────────► GuardChain.evaluateBeforeToolCall()
  │    │                                  + credential stripping
  │    └─ PostToolUse ─────────────────► GuardAuditLogger.logPostToolUse()
  │ ── assistant (tool_result) ────────► ToolResultEvent
  │ ── result ─────────────────────────► TurnResult → complete turnCompleter
  │
  ▼
Back in _runTurn()
  │
  │ ⑬ Track cost (KvService session_cost:*)
  │ ⑭ Update ContextMonitor (input tokens)
  │ ⑮ Record usage (UsageTracker)
  │ ⑮ᵃ Check context warning threshold (ContextMonitor.checkThreshold)
  │   └─ if usage ≥ threshold: emit SSE context_warning event (one-shot per session)
  │
  │ ⑯ Post-turn guard: GuardChain.evaluateBeforeAgentSend()
  │   └─ block → insert "[Response blocked by guard: ...]" → return failed
  │
  │ ⑰ Apply MessageRedactor (proportional content redaction)
  │ ⑱ Apply ExplorationSummarizer (type-aware summary or ResultTrimmer fallback)
  │ ⑲ Persist assistant message to MessageService
  │ ⑳ Append to daily log (YYYY-MM-DD.md)
  │
  │ ㉑ If ContextMonitor.shouldFlushForCompactionSignal(...): run pre-compaction flush turn
  │
  ▼
Finally block
  │ ㉒ Remove active turn from _activeTurns
  │ ㉓ Release session lock
  │ ㉔ Delete turn-state row from TurnStateStore
  │ ㉕ Cache TurnOutcome (TTL: 30s)
  │ ㉖ Complete _outcomePending completer
  ▼
TurnOutcome { turnId, sessionId, status, responseText?, inputTokens, outputTokens,
              turnDuration, cacheReadTokens, cacheWriteTokens, toolCalls }
```

When a stall timer is configured, the monitor starts immediately before `AgentHarness.turn()` and stops in the `finally` block with the rest of turn cleanup. Stall actions are intentionally narrow:
- `warn` logs and emits SSE `turn_progress_stall`
- `cancel` emits the same event and aborts the active turn
- `ignore` logs only

### State transitions

The harness tracks its lifecycle via `WorkerState`:

```
stopped ──start()──► idle ──turn()──► busy ──result──► idle
   ▲                   │                │
   │                   │                └──crash──► crashed ──backoff+restart──► idle
   │                   │                              │
   └───stop()──────────┘                              └──max retries──► (throws StateError)
```

---

## 7. Enriched Turn Data Extraction

`TurnRunner._runTurnInner()` collects richer data from the turn stream beyond the final `TurnResult` message. This enrichment is transparent to consumers – they receive the final `TurnOutcome` with all fields populated.

### ToolCallRecord Capture

`ToolUseEvent` and `ToolResultEvent` are correlated by `toolId` to build a `ToolCallRecord` for each tool invocation:

1. **On `ToolUseEvent`**: record `(toolId → name, startTimestamp)` in a correlation map
2. **On `ToolResultEvent`**: look up by `toolId`, compute `durationMs = now - startTimestamp`, create `ToolCallRecord(name, success, durationMs, errorType?)`
3. **At turn end**: any incomplete tool call (no matching result) gets `success: false`, `errorType: 'incomplete'`

`ToolCallRecord` fields:
```
ToolCallRecord
├── name: String          (tool name, e.g. "bash", "read_file")
├── success: bool
├── durationMs: int
└── errorType: String?    (null on success; 'incomplete' for unmatched events)
```

### Cache Token Normalization

`ProtocolAdapter` normalizes provider-specific cache token field names to a canonical two-field model before they reach `TurnOutcome`. Consumers never need to know the underlying wire format:

| Provider | Wire field(s) | Canonical mapping |
|----------|--------------|-------------------|
| Anthropic (Claude) | `cache_read_input_tokens`, `cache_creation_input_tokens` | `cacheReadTokens`, `cacheWriteTokens` |
| OpenAI (Codex) | `cached_input_tokens` | `cacheReadTokens` (write = 0) |
| Others | (not reported) | Both = 0 |

### Enriched TurnOutcome

`TurnOutcome` includes:

```
TurnOutcome
├── ... (core fields)
├── turnDuration: Duration        – wall-clock elapsed via Stopwatch
├── cacheReadTokens: int          – normalized by ProtocolAdapter
├── cacheWriteTokens: int         – normalized by ProtocolAdapter
└── toolCalls: List<ToolCallRecord> – correlated from stream events
```

Downstream consumers (`AgentObserver.recordTurn()`, `TurnTraceService`, `TaskEventRecorder`) consume these enriched fields directly. Cache token normalization happening at the adapter layer means these consumers are fully provider-agnostic.

---

## 8. Tool Approval Chain

Every tool invocation flows through a two-stage approval pipeline.

### Stage 1: can_use_tool (binary-level)

This stage runs only when `--permission-prompt-tool stdio` is in effect – the `restricted` container profile or a non-`bypassPermissions`/`dontAsk` `permissionMode` (see the permission-flag matrix in §2). In the **default** configuration DartClaw passes `--dangerously-skip-permissions`, which suppresses `can_use_tool` entirely, so the binary skips this stage and goes straight to the hook callbacks. The harness treats any `can_use_tool` request received while permissions are skipped as defensive dead code: it logs a warning and denies.

When the prompt tool *is* active, the binary sends a `can_use_tool` control request before each tool execution. DartClaw's current `ToolApprovalPolicy` is `allowAll` – all tools are approved at this stage. The approval mechanism exists as a seam for future fine-grained policies.

```dart
enum ToolApprovalPolicy { allowAll }
```

### Stage 2: PreToolUse hook callback (guard evaluation)

Immediately after binary-level approval, the binary invokes the registered `hook_pre_tool` callback. This is where DartClaw's security logic runs.

**Flow:**

```
claude binary
  │
  ├─► can_use_tool ────► allowAll ────► allow response   (only when prompt tool active; skipped by default)
  │
  └─► hook_callback (PreToolUse)        ◄── always fires, even with --dangerously-skip-permissions
        │
        ├─► GuardChain.evaluateBeforeToolCall(toolName, toolInput)
        │     Each guard evaluates in order. First block wins.
        │     Fail-closed: guard exceptions → block verdict.
        │     5-second timeout per guard.
        │
        │   Guard types: CommandGuard, FileGuard, InputSanitizer, etc.
        │   Verdicts: pass / warn / block
        │
        ├─► If block → deny response (hookSpecificOutput.permissionDecision: "deny")
        │
        ├─► Credential stripping: if toolInput.env contains ANTHROPIC_API_KEY,
        │   strip it and return updatedInput in hookSpecificOutput
        │
        └─► Otherwise → allow response
```

### PostToolUse hook callback (audit)

After tool execution completes, the binary invokes `hook_post_tool`. DartClaw logs the tool name, success/failure status, and response summary via `GuardAuditLogger`. PostToolUse always allows continuation – it is purely observational.

**Important timing note**: PostToolUse fires after the tool result is already in the binary's context window. This is why `web_fetch` was moved to the internal MCP server (see [ADR-009](../adrs/009-internal-mcp-server.md)) – ContentGuard scanning must happen before the agent sees fetched content, which requires Dart to own the execution.

### Guard audit trail

All guard verdicts (pass, warn, block) are:
1. Logged to stdout at appropriate severity (INFO/WARNING/SEVERE)
2. Appended to a date-partitioned `audit-YYYY-MM-DD.ndjson` file in the data directory (NDJSON, fire-and-forget)
3. Fired on the EventBus as `GuardBlockEvent` (for warn and block verdicts)

---

## 9. Harness Abstraction

### AgentHarness (interface)

`AgentHarness` is the abstract interface that decouples consumers from the specific agent runtime. It is the swap point for provider-specific harnesses.

```dart
abstract class AgentHarness {
  PromptStrategy get promptStrategy;   // replace or append
  WorkerState get state;               // idle, busy, crashed, stopped
  Stream<BridgeEvent> get events;      // persistent broadcast stream

  Future<void> start();
  Future<Map<String, dynamic>> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    Map<String, dynamic>? mcpServers,
    bool resume = false,
    String? directory,
    String? model,
  });
  Future<void> cancel();
  Future<void> stop();
  Future<void> dispose();
}
```

### Concrete implementations

Three concrete implementations exist today:

- `ClaudeCodeHarness` – Claude Code JSONL protocol (primary, default)
- `CodexHarness` – Codex JSON-RPC app-server protocol (see [Codex JSON-RPC Protocol](#codex-json-rpc-protocol))
- `AcpHarness` – ACP stdio JSON-RPC protocol for configured ACP agents such as Goose and Vibe

`HarnessFactory` creates provider-specific instances from `HarnessConfig` and ACP registration entries, and `HarnessPool` manages provider-scoped runners. Each provider identity has its own pool with default capacity `1`; `providers.<id>.pool_size` is the only capacity override. ACP agent registration controls spawn and security classification, not custom capacity.

#### ClaudeCodeHarness

Key behavioral properties:

| Property | Value |
|---|---|
| Prompt strategy | `append` (system prompt via `--append-system-prompt` at spawn time) |
| Turn timeout | 600 seconds (configurable) |
| Max retries on crash | 5 (with exponential backoff from 5-second base) |
| Init handshake timeout | 10 seconds |
| Lifecycle serialization | `_withLock()` – chains mutating operations via future chaining |
| Event stream | Broadcast `StreamController` – survives process restarts |

### HarnessConfig

Configuration forwarded in the initialize handshake:

```dart
class HarnessConfig {
  final List<String> disallowedTools;  // Tool blocklist
  final int? maxTurns;                 // Safety cap
  final String? model;                 // Model selection (supports [1m] suffix)
  final Map<String, dynamic>? agents;  // Sub-agent definitions
  final String? appendSystemPrompt;    // Behavior content (spawn-time flag)
  final String? mcpServerUrl;          // Internal MCP server URL
  final String? mcpGatewayToken;       // MCP bearer auth token
}
```

#### AcpHarness

`AcpHarness` wraps an ACP agent subprocess using stdio JSON-RPC. The configured `harness.acp.agents.<id>` entry supplies the binary, args, topology, model provider, verification evidence, required built-ins, and container profile. Missing `topology` defaults to `unverified`.

Only direct-provider ACP agents that advertise and honor host `fs` capabilities can be classified as guard-mediated. Goose direct-provider targets require the `developer` extension, a direct model provider selector, and verification evidence when guard mediation is required; known proxy selectors such as `claude-acp` and `codex-acp` are rejected as direct-provider claims. Vibe must prove the declared provider is non-proxy or pass startup verification before DartClaw marks it guard-mediated.

Relay-provider and unverified ACP agents remain container-isolation-only. They may run in isolated profiles, but DartClaw does not claim guard mediation until per-agent verification proves reverse-call mediation.

ACP reverse-calls are bound at the host handler boundary:

| ACP method | Canonical tool | Guard/audit behavior |
|---|---|---|
| `fs/read_text_file` | `file_read` | Calls `GuardChain.evaluateBeforeToolCall(...)` with `rawProviderToolName: "fs/read_text_file"` |
| `fs/write_text_file` | `file_write` | Calls `GuardChain.evaluateBeforeToolCall(...)` with `rawProviderToolName: "fs/write_text_file"` |
| `terminal/create` | unavailable | Rejected on every host until DartClaw can prove containment of the complete spawned process tree |

Every filesystem reverse-call is bound to the active host session and effective workspace directory. Calls outside an active turn are rejected, and guard evaluation carries the host session ID so task-local tool and read-only policies apply.

DartClaw does not advertise `terminal.create` and rejects all ACP terminal lifecycle calls on every host because complete descendant containment is not yet proven. Filesystem reverse-calls remain available. Container-isolated ACP agents advertise no host reverse-calls.

### Working directory and model changes

The harness supports per-turn working directory and model overrides (used by task execution for worktree paths and per-task model selection). If the requested directory or model differs from the current process configuration, the harness performs a full stop-and-restart cycle:

```
turn(directory: "/worktrees/task-42")
  └─► _restartForExecution()
        ├─► stop current process
        ├─► update _processWorkingDirectory
        └─► start new process (with updated cwd)
```

---

## 10. MCP Integration

DartClaw exposes custom tools to the agent via two mechanisms.

### Mechanism A: Internal HTTP MCP Server (serve mode)

When running via `dartclaw serve`, an MCP endpoint is hosted at `/mcp` on the existing shelf HTTP server. The `claude` binary discovers it via `--mcp-config`:

```
DartclawServer (shelf)
  │
  ├── /api/*          REST API
  ├── /webhook/*      Channel webhooks
  └── /mcp            MCP server (Streamable HTTP, JSON-RPC 2.0)
                        ▲
                        │ POST /mcp (JSON-RPC)
                        │ Authorization: Bearer <token>
                        │
                      claude binary
```

**MCP config file** (ephemeral, `chmod 600`, auto-deleted on harness stop):

```json
{
  "mcpServers": {
    "dartclaw": {
      "type": "http",
      "url": "http://127.0.0.1:3333/mcp",
      "headers": { "Authorization": "Bearer <gateway-token>" }
    }
  }
}
```

**Registered tools** (via `McpProtocolHandler`):

| Tool | Implementation | Registration | Description |
|---|---|---|---|
| `memory_save` | `MemorySaveTool` | always | Persist facts to MEMORY.md + search index |
| `memory_search` | `MemorySearchTool` | always | FTS5 full-text search over memory chunks |
| `memory_read` | `MemoryReadTool` | always | Read full MEMORY.md contents |
| `kg_add` | `KgAddTool` | always | Add a source-linked temporal fact to the knowledge graph |
| `kg_query` | `KgQueryTool` | always | Query temporal knowledge-graph facts by entity/predicate (+ optional `as_of`) |
| `kg_timeline` | `KgTimelineTool` | always | Return the full temporal fact timeline for an entity |
| `kg_invalidate` | `KgInvalidateTool` | always | Invalidate a temporal fact without deleting its history |
| `kg_contradictions` | `KgContradictionsTool` | always | Find open facts that would contradict an incoming fact |
| `delegate_to_agent` | `DelegateToAgentTool` | always | Delegate bounded work to an allowlisted ACP or Codex provider agent |
| `sessions_send` | `SessionsSendTool` | always | Inter-agent delegation |
| `onboarding_complete` | `OnboardingCompleteTool` | **gated** – only while onboarding is active (`ONBOARDING.md` present at startup) | Mark conversational onboarding complete and remove the `ONBOARDING.md` sentinel |
| `web_fetch` | `WebFetchTool` | always | SSRF-hardened URL fetching with ContentGuard |
| `brave_search` | `BraveSearchTool` | **gated** – when the `brave` search provider is enabled with an API key | Web search via Brave API |
| `tavily_search` | `TavilySearchTool` | **gated** – when the `tavily` search provider is enabled with an API key | Web search via Tavily API |

Tools implement the `McpTool` interface:

```dart
abstract interface class McpTool {
  String get name;
  String get description;
  Map<String, dynamic> get inputSchema;
  Future<ToolResult> call(Map<String, dynamic> args);
}
```

The MCP router (`mcp_router.dart`) handles auth (Bearer token), content-type validation, payload size limits (1 MB), and origin checking (localhost only for browser clients).

### Mechanism B: sdkMcpServers (chat mode fallback)

When no MCP server URL is configured (running without `serve`), memory tools are registered inline in the `initialize` handshake via `sdkMcpServers`. The binary proxies tool calls through `mcp_message` control requests (see section 4.7). This is a Claude-SDK-private extension, not the published MCP spec.

**Migration**: Mechanism B is retained for backward compatibility. Mechanism A is preferred and will eventually replace B entirely. See [ADR-009](../adrs/009-internal-mcp-server.md).

---

## Codex JSON-RPC Protocol

See the Codex CLI Harness Research (private repo: `docs/research/codex-cli-harness/research.md`) for the protocol analysis that informed this section.

Codex integrates through `codex app-server`, a long-lived subprocess that speaks JSON-RPC 2.0-like messages over stdin/stdout and serializes them as JSONL. DartClaw keeps approval requests active during startup and normal turns, so the harness does not use `--yolo`.

### Spawn and handshake

The Codex harness spawns the app-server binary directly:

```bash
codex app-server
```

Startup uses a two-step handshake:

1. DartClaw sends `initialize`.
2. Codex responds, then DartClaw sends `initialized`.

Only after that does DartClaw create or resume a thread with `thread/start`. The first turn for a session creates a thread; later turns reuse the cached thread ID for that DartClaw session.

### Turn lifecycle

Each turn is issued with `turn/start` on the active thread. DartClaw passes the current user message plus its own replayed history, so Codex sees a deterministic, DartClaw-owned conversation history rather than depending on Codex session persistence.

When the app-server exits unexpectedly, DartClaw clears the cached thread IDs, restarts the process with backoff, re-runs the handshake, creates a fresh thread, and replays the saved history into the next `turn/start` request.

### Streaming notifications

Codex emits turn and item notifications over stdout. DartClaw parses and maps the notifications that matter to its bridge layer:

| Codex notification | DartClaw handling |
|---|---|
| `turn/started` | Lifecycle marker; ignored by the protocol adapter |
| `item/agentMessage/delta` | `DeltaEvent` for incremental text streaming |
| `item/started` (`contextCompaction`) | `CompactionStartingBridgeEvent` |
| `item/started` (tool item) | `ToolUseEvent` for typed tool items such as `command_execution`, `file_change`, `mcp_tool_call`, and `web_search` |
| `item/completed` (`contextCompaction`) | `CompactionCompletedBridgeEvent` |
| `item/completed` (tool item / agent message) | `ToolResultEvent` for completed tool items and final agent messages |
| `turn/completed` | Completes the pending turn with usage metadata |
| `turn/failed` | Completes the pending turn with an error stop reason |

This is the Codex path implemented by `CodexProtocolAdapter`. The adapter also accepts the v0.118.0 `ClientResponse` envelope variants while preserving the same `SystemInit` and thread-id extraction behavior.

### Approval flow

Codex sends tool approval requests back to DartClaw as JSON-RPC requests, including `control/approval` and `approval/request`. DartClaw evaluates the request through the same guard chain used elsewhere in the runtime, then replies with a JSON-RPC result that either approves or denies the tool call.

The approval payload is normalized before guard evaluation so DartClaw can strip sensitive environment values and translate provider tool names into canonical tool names. Unlike Claude Code, there is no separate hook system here; the approval round-trip is the interception point.

#### Per-turn dynamic settings

DartClaw passes `approval_policy` and `sandbox` as per-turn settings in every `turn/start` request. These are configured via the provider's `approval` and `sandbox` options in `dartclaw.yaml` and translated by `CodexSettings.buildDynamicSettings()`:

| DartClaw config | Codex setting | Behavior |
|---|---|---|
| `approval: on-request` | `approval_policy: "on-request"` | Default – Codex sends approval requests to DartClaw's guard chain |
| `approval: unless-allow-listed` | `approval_policy: "granular"` | Only requests approval for commands not in Codex's safe-command list |
| `approval: never` | `approval_policy: "never"` | No approval requests – all tool calls execute immediately |
| `sandbox: workspace-write` | `sandbox: "workspaceWrite"` | Codex sandbox allows writes to working directory only |
| `sandbox: danger-full-access` | `sandbox: "dangerFullAccess"` | No Codex sandbox restrictions |

#### Known issue: approval elicitation deadlock

> **Upstream bug** ([openai/codex#11816](https://github.com/openai/codex/issues/11816), OPEN as of 2026-03): Codex's `exec_approval.rs` awaits the client's approval response with **no timeout and no cancellation**. If the client cannot respond (e.g., it doesn't implement the `elicitation/create` capability), the turn hangs indefinitely – no error, no timeout event. Simple conversational turns succeed because they don't trigger tool approval; file writes and shell commands do.
>
> **Impact on DartClaw**: A stuck approval holds DartClaw's `SessionLockManager` per-session lock for up to `worker_timeout` (default 600s), blocking all other messages to that session. In crowd-coding with a shared session, this blocks the entire workshop.
>
> **Recommended configuration**: Set `approval: never` + `sandbox: danger-full-access` in the Codex provider config.
> This bypasses Codex's internal approval gate. On POSIX deployments with containers enabled, the guard chain,
> container isolation, and `TaskFileGuard` remain active. Native Windows has no container-isolation parity and
> restrictive Codex sandbox modes were not qualified for 0.21. Also reduce `worker_timeout` to 120s for shared-session
> scenarios.

### Crash recovery and history replay

Codex app-server is treated as ephemeral. If the process exits unexpectedly, DartClaw:

1. Clears cached thread IDs for the affected session.
2. Marks the worker crashed and applies the normal exponential backoff restart policy.
3. Spawns a fresh `codex app-server`.
4. Repeats `initialize` / `initialized`.
5. Creates a new thread.
6. Replays DartClaw-owned history from the NDJSON message store into the next `turn/start` request via `previous_response_items`.

This keeps continuity under DartClaw's control and avoids depending on provider-managed session storage after a crash.

## 11. Harness Pool

The `HarnessPool` manages multiple `TurnRunner` instances for concurrent task execution.

### Pool structure

```
HarnessPool
  ├── runners[0]  – PRIMARY (main chat, cron, channel turns)
  ├── runners[1]  – Task runner (profile: workspace)
  ├── runners[2]  – Task runner (profile: restricted)
  └── runners[N]  – ...
```

**Primary runner** (index 0): Reserved exclusively for interactive use via `TurnManager`. Never acquired by `TaskExecutor`. Always available for chat, cron, and channel-initiated turns.

**Task runners** (indices 1..N): Acquired by `TaskExecutor` via `tryAcquire()` or `tryAcquireForProfile(profileId)`. Released back to the pool after task completion.

### Acquisition and release

```dart
class HarnessPool {
  TurnRunner get primary;                           // Always index 0
  TurnRunner? tryAcquire();                         // Any available task runner
  TurnRunner? tryAcquireForProfile(String profile); // Matching security profile
  void release(TurnRunner runner);                  // Return to pool
}
```

When all task runners are busy, `tryAcquire()` returns `null` and the task remains queued until a runner is released.

### Capacity configuration

Pool size is controlled by `tasks.max_concurrent` in `dartclaw.yaml` (range: 1-10). When set to 1, only the primary runner exists and `TaskExecutor` falls back to using the primary runner when it is idle – preserving single-harness sequential behavior.

### Single-harness fallback

For `maxConcurrentTasks == 0`:

```
TaskExecutor.pollOnce()
  └─► if _turns.activeSessionIds.isNotEmpty → skip (primary is busy)
  └─► otherwise → execute task on primary runner directly
```

---

## 12. TurnManager and TurnRunner

### TurnManager

Thin orchestration wrapper that delegates all turn operations to the appropriate `TurnRunner`.

```dart
class TurnManager {
  TurnManager({required AgentHarness worker, ...});  // Single-runner convenience
  TurnManager.fromPool({required HarnessPool pool}); // Multi-runner mode

  HarnessPool get pool;               // For TaskExecutor
  TurnRunner get primary;             // Via pool.primary

  Future<String> reserveTurn(...);     // Delegates to primary
  void executeTurn(...);               // Delegates to primary
  Future<void> cancelTurn(...);        // Searches all runners
}
```

`cancelTurn` and `waitForCompletion` search across all pool runners – a session could be active on any runner (task sessions run on pool runners, not just primary).

### TurnRunner

Per-harness turn execution engine. Each `TurnRunner` wraps a single `AgentHarness` and encapsulates the full turn lifecycle: guard evaluation, message persistence, event streaming, cost tracking, and crash recovery.

The same bridge-event stream also drives progress-aware stall detection. `TurnRunner._runTurnInner()` starts a `TurnProgressMonitor` when `governance.turn_progress.stall_timeout > 0` and resets it only on forward-progress events (`DeltaEvent`, `ToolUseEvent`, `ToolResultEvent`). Those same events also call `SessionResetService.touchActivity(sessionId)`, so long-running turns keep the session alive based on actual harness activity rather than wall-clock turn age.

**Key state:**

| Field | Type | Purpose |
|---|---|---|
| `_activeTurns` | `Map<String, TurnContext>` | Currently executing turns (sessionId → context) |
| `_cancelledTurns` | `Set<String>` | Turn IDs that have been cancelled |
| `_recentOutcomes` | `Map<String, (TurnOutcome, DateTime)>` | TTL-cached outcomes (default 30s) |
| `_outcomePending` | `Map<String, Completer<TurnOutcome>>` | Pending outcome waiters |
| `_stallTimeout` | `Duration` | Silent-turn threshold from `governance.turn_progress.stall_timeout` (`Duration.zero` disables monitoring) |
| `_stallAction` | `TurnProgressAction` | Stall policy: `warn`, `cancel`, or `ignore` |
| `profileId` | `String` | Security profile (e.g., `workspace`, `restricted`) |

**Reserve → Execute → Complete lifecycle:**

```
reserveTurn(sessionId) → turnId
  │ acquire lock, create TurnContext, persist to kv
  ▼
executeTurn(sessionId, turnId, messages)
  │ launches async _runTurn (fire-and-forget)
  ▼
waitForOutcome(sessionId, turnId) → TurnOutcome
  │ awaits _outcomePending[turnId] completer
```

This two-phase design (reserve + execute) allows the caller to insert pre-execution work (e.g., persisting the user message) between reservation and execution.

---

## 13. Container Dispatch

Task types are routed to different security profiles via `resolveProfile()`:

```dart
String resolveProfile(TaskType taskType) {
  return switch (taskType) {
    TaskType.research => 'restricted',
    _ => 'workspace',
  };
}
```

| Task type | Profile | Container characteristics |
|---|---|---|
| `coding`, `writing`, `general` | `workspace` | Full workspace mount at `/project`, read-write access |
| `research` | `restricted` | No workspace mount, no project filesystem access |

The `TaskExecutor` acquires runners matching the target profile:

```dart
TurnRunner? _acquirePoolRunner(String profile) {
  if (_pool.hasTaskRunnerForProfile(profile))
    return _pool.tryAcquireForProfile(profile);
  if (_pool.taskProfiles.length <= 1)
    return _pool.tryAcquire();     // Single-profile fallback
  return null;
}
```

### Container naming

Per-profile containers are uniquely named using a hash of the data directory:

```
dartclaw-<fnv1a8(dataDir)>-<profileId>
```

Example: `dartclaw-a1b2c3d4-workspace`, `dartclaw-a1b2c3d4-restricted`.

### Container health monitoring

`ContainerHealthMonitor` polls container health at 10-second intervals. State transitions fire events on the EventBus:

| Transition | Event |
|---|---|
| healthy → unhealthy | `ContainerCrashedEvent(profileId, containerName, error)` |
| unhealthy → healthy | `ContainerStartedEvent(profileId, containerName)` |

Tasks in a crashed container fail naturally when their `docker exec` subprocess terminates. The monitor provides structured notification for the dashboard and observability layer.

---

## 14. Crash Recovery

DartClaw implements crash recovery at multiple levels.

### Process-level restart (automatic)

When the `claude` process exits unexpectedly:

1. Exit code handler fires (registered via `process.exitCode.then(...)`)
2. State transitions to `WorkerState.crashed`, crash counter increments
3. Pending turn completer is completed with error
4. Next `turn()` call triggers automatic restart with exponential backoff:

```
Attempt 1: 5s delay
Attempt 2: 10s delay
Attempt 3: 20s delay
Attempt 4: 40s delay
Attempt 5: 80s delay
Attempt 6: throws StateError('Harness unavailable: max retries exceeded')
```

### Turn-level recovery (`state.db`)

Turn state is persisted to `TurnStateStore` in `state.db` at reservation time. The schema is intentionally tiny:

```sql
CREATE TABLE turn_state (
  session_id TEXT PRIMARY KEY,
  turn_id TEXT NOT NULL,
  started_at TEXT NOT NULL
);
```

On server restart, `detectAndCleanOrphanedTurns()` reads all rows from `turn_state`, logs each orphaned turn, deletes the rows, and records the affected session IDs. `consumeRecoveryNotice(sessionId)` returns `true` once for each recovered session – the web UI uses this to show a "Session recovered from crash" banner.

### Message-level recovery (NDJSON cursors)

Messages are stored in NDJSON files (`sessions/<uuid>/messages.ndjson`) with auto-incrementing `cursor` values. After a crash, clients request "all messages after cursor X" to resume exactly where they left off. The cursor is the line number in the NDJSON file – no timestamp-based ordering ambiguity.

### Harness generation tracking

Each spawn increments a `_spawnGeneration` counter. Exit code handlers check `if (generation != _spawnGeneration) return` – this prevents stale exit handlers from affecting a newly spawned process after a restart.

### Task worktree preservation

When a task execution fails, the git worktree is intentionally **not** cleaned up. The worktree at `<dataDir>/worktrees/<taskId>/` is preserved for post-mortem inspection. Cleanup only occurs on explicit task accept, reject, or cancel.

---

## 15. Error Handling

### Protocol-level errors

| Error | Detection | Response |
|---|---|---|
| Malformed JSONL | `jsonDecode` throws `FormatException` | Line is logged and skipped |
| Unknown message type | `parseJsonlLine` returns `null` | Silently ignored |
| Unknown control_request subtype | `_handleControlRequest` default case | Generic success response |
| Initialize timeout | 10-second `Future.timeout` | Process killed, `StateError` thrown |

### Turn-level errors

| Error | Detection | Recovery |
|---|---|---|
| Turn timeout (600s) | `Timer` fires | `cancel()` closes stdin, then uses the platform-capability termination policy |
| Harness not idle | State check at turn start | `StateError` thrown to caller |
| Guard block (pre-turn) | `GuardChain.evaluateMessageReceived` returns block | Message stored as `[Blocked by guard: ...]`, failed outcome |
| Guard block (post-turn) | `GuardChain.evaluateBeforeAgentSend` returns block | Message stored as `[Response blocked by guard: ...]`, failed outcome |
| Turn execution exception | `catch` in `_runTurn` | Partial buffer saved, failed/cancelled outcome |

### Cancellation

The JSONL protocol has no explicit cancel command. `cancel()` closes stdin and issues the initial platform termination
request; the serialized stop path then passes that request's acceptance result to `killWithEscalation` as
`initialTerminationAccepted` to observe the exit and, when supported, escalate. The helper reads
`PlatformCapabilities.posixSignalsAvailable`. POSIX hosts use SIGTERM followed by SIGKILL after the grace period.
Windows hard-terminates the directly managed root handle and never attempts POSIX signal escalation or a later
bare-PID tree request. Harness, CLI-provider, and sidecar owners release that direct ownership only after root exit is
observed. They do not claim ownership of provider-created helpers; arbitrary descendant containment remains a separate
capability and is why ACP terminal reverse-calls stay disabled. Workflow Bash steps track observed command descendants
and inherited output handles, retaining failed cleanup when their exit cannot be proved. Detached or daemonized
processes that escape that observable boundary are unsupported in Bash steps.

```dart
Future<void> cancel() async {
  final process = currentProcess;
  beginIntentionalProcessTeardown(process, platformCapabilities);
  await closeCurrentProcessStdin(process: process);
  if (process == null) return;
  final result = await killWithEscalation(
    process,
    label: 'provider',
    platformCapabilities: platformCapabilities,
  );
  completeIntentionalProcessTeardown(process, result, platformCapabilities);
}
```

The turn is marked as cancelled in `_cancelledTurns` so the error handler can distinguish cancellation from failure.

### Lifecycle lock

All mutating lifecycle operations (`start`, `stop`, `restartForExecution`) are serialized through a `_withLock()` mechanism that chains futures. This prevents race conditions like concurrent start/stop calls or start-during-busy states.

---

## 16. Channel Inbound Routing

Inbound messages from all channels (WhatsApp, Signal, Google Chat) flow through a single routing pipeline before reaching the session queue. The entry point is `ChannelManager.handleInboundMessage()`, which dispatches to `ChannelTaskBridge.tryHandle()` when a bridge is wired.

### Routing Precedence

`ChannelTaskBridge.tryHandle()` evaluates inbound messages in strict priority order:

| Step | Check | Condition | Outcome |
|---|---|---|---|
| 0 | Reserved commands | Handler returns non-null | Consumed – no further processing |
| 1 | Thread binding | `features.thread_binding.enabled` + matching binding | Enqueued to bound task session, returns `true` |
| 2 | Per-sender rate limit | Rate limit exceeded (non-admin, non-reserved, non-review) | Rejected with rate-limit message, returns `true` |
| 3 | Review commands | `/accept`, `/reject`, `/push back` | Dispatched to task review handler, returns `true` |
| 4 | Task trigger | Trigger keyword in message text | Task created and acknowledgement sent, returns `true` |
| – | Fall-through | None of the above | Returns `false` – normal session routing via queue |

When `tryHandle()` returns `false`, the message is enqueued with the derived session key as normal.

### Thread Binding

Thread binding enables per-task conversation threads in Google Chat Spaces. When `features.thread_binding.enabled` is `true`:

**Outbound – binding creation**: `TaskNotificationSubscriber` posts the initial task notification (queued→running) to a new Google Chat thread using `threadKey = "task-{taskId}"`. The REST client returns the server-assigned `thread.name`. `TaskNotificationSubscriber` calls `ThreadBindingStore.create()` to map the thread to the task's session.

**Inbound – thread routing**: `CloudEventAdapter` extracts `message.thread.name` and stores it in `ChannelMessage.metadata['threadName']`. `extractThreadId()` reads this field. When a binding matches, `ChannelTaskBridge` calls the injected `enqueue` callback with the binding's session key – routing the message to the task agent rather than the shared group session.

**Persistence**: `ThreadBindingStore` maintains an in-memory `Map<String, ThreadBinding>` backed by `<dataDir>/thread-bindings.json`. Every mutation (create, delete, updateLastActivity, reconcile) writes atomically via `atomicWriteJson()` (temp file + rename).

**Startup reconciliation**: On startup, after both the binding store and task service are loaded, `ThreadBindingStore.reconcile(activeTaskIds)` removes bindings whose task has reached a terminal state. This handles bindings that were not cleaned up during a crash or restart.

**Key**: `ThreadBinding.key(channelType, threadId)` → `'$channelType::$threadId'` compound string.

```
Google Chat Space (inbound message in thread)
  ↓
CloudEventAdapter.parseMessageResource()
  → metadata['threadName'] = 'spaces/AAAA/threads/CCCC'
  ↓
ChannelManager.handleInboundMessage()
  → tryHandle(message, channel, sessionKey: derived, enqueue: queue.enqueue)
    → extractThreadId(message) → 'spaces/AAAA/threads/CCCC'
    → ThreadBindingStore.lookupByThread('googlechat', 'spaces/AAAA/threads/CCCC')
      → found: binding for task-xyz, sessionKey: 'agent:main:task:task-xyz'
    → enqueue(message, channel, 'agent:main:task:task-xyz')   // routed to task session
    → return true
```

### Session Key Derivation (Fall-Through Path)

When no binding matches, `ChannelManager.deriveSessionKey()` applies the configured `SessionScopeConfig` (DM-per-contact, group-shared, etc.) to produce a deterministic session key. The message is then enqueued normally.

### Queued Outbound Delivery and Feedback

`MessageQueue` is the outbound counterpart to the inbound routing pipeline. After a queued turn finishes, it formats the agent response into `ChannelResponse` chunks and preserves channel-specific reply metadata needed by downstream adapters.

- `ChannelResponse.replyToMessageId` is the explicit runtime field for "reply to this inbound message"
- `ChannelResponse.metadata` carries adapter-specific data that must survive formatting and queueing, including Google Chat `messageName`, `messageCreateTime`, and the originating `sourceMessageId`
- For Google Chat, `replyToMessageId` plus `messageCreateTime` become `quotedMessageMetadata`, which keeps native quote-reply working for both webhook-originated messages and Space Events messages with dot-format IDs

Before normal delivery, `MessageQueue` may also invoke an optional `TurnObserver`. The CLI wiring uses this seam for Google Chat feedback: `GoogleChatFeedbackStrategy` watches the running response future plus live bridge events, patches a placeholder message or emoji reaction during long-running turns, and can suppress the final normal send when the placeholder edit already delivered the completed response. Feedback failures are logged and never propagate back into turn execution.

---

## 17. NDJSON Channel (Wire Layer)

The lowest-level transport is implemented in `ndjson_channel.dart`:

```dart
StreamChannel<String> ndjsonChannel(
  Stream<List<int>> input,
  StreamSink<List<int>> output,
)
```

**Input pipeline**: `bytes → utf8.decode → LineSplitter → filter empty → String events`

**Output pipeline**: `String → append '\n' → utf8.encode → bytes`

`ClaudeCodeHarness` does not use `ndjsonChannel` directly – it manages the stdin/stdout streams inline for tighter control over the process lifecycle. The `ndjsonChannel` utility exists for the bridge abstraction layer and testing.

---

## 18. Cross-References

### Architecture Decision Records

| ADR | Relevance |
|---|---|
| [ADR-001](../adrs/001-sdk-integration-and-security-architecture.md) | Original architecture decision + Addendum validating the direct JSONL approach |
| [ADR-003](../adrs/003-coding-task-support-and-agent-extensibility.md) | Extensibility via JSONL; layered SDK options; `.claude/` ecosystem |
| [ADR-009](../adrs/009-internal-mcp-server.md) | Internal MCP server as tool extension point; `sdkMcpServers` → HTTP migration |

### Diagrams

| Diagram | Contents |
|---|---|
| `docs/diagrams/harness-architecture.excalidraw` | Harness pool, runner, container dispatch |
| `docs/diagrams/turn-lifecycle.excalidraw` | Full turn flow from user message to stored response |
| `docs/diagrams/dartclaw-architecture.excalidraw` | High-level 2-layer architecture |
| `docs/diagrams/security-architecture.excalidraw` | Defense-in-depth layers, credential isolation |

### Source files (public repo)

| File | Contents |
|---|---|
| `packages/dartclaw_core/lib/src/harness/claude_code_harness.dart` | `ClaudeCodeHarness` – all JSONL handling, spawn, lifecycle |
| `packages/dartclaw_core/lib/src/harness/claude_protocol.dart` | `ClaudeMessage` sealed hierarchy + `parseJsonlLine()` |
| `packages/dartclaw_core/lib/src/harness/agent_harness.dart` | `AgentHarness` abstract interface |
| `packages/dartclaw_core/lib/src/harness/harness_config.dart` | `HarnessConfig` – initialize handshake fields |
| `packages/dartclaw_core/lib/src/harness/tool_policy.dart` | `ToolApprovalPolicy`, response builders |
| `packages/dartclaw_core/lib/src/harness/mcp_tool.dart` | `McpTool` interface |
| `packages/dartclaw_core/lib/src/harness/tool_result.dart` | `ToolResult` sealed class |
| `packages/dartclaw_core/lib/src/bridge/bridge_events.dart` | `BridgeEvent` sealed hierarchy |
| `packages/dartclaw_core/lib/src/bridge/ndjson_channel.dart` | NDJSON transport utility |
| `packages/dartclaw_core/lib/src/security/guard.dart` | `Guard`, `GuardChain` |
| `packages/dartclaw_core/lib/src/security/guard_audit.dart` | `GuardAuditLogger`, `GuardAuditSubscriber` |
| `packages/dartclaw_server/lib/src/container/container_manager.dart` | `ContainerManager` – Docker lifecycle |
| `packages/dartclaw_server/lib/src/container/container_dispatcher.dart` | `resolveProfile()` – task type → security profile |
| `packages/dartclaw_server/lib/src/turn_manager.dart` | `TurnManager` – orchestration wrapper |
| `packages/dartclaw_server/lib/src/turn_runner.dart` | `TurnRunner` – per-harness turn execution |
| `packages/dartclaw_server/lib/src/harness_pool.dart` | `HarnessPool` – concurrent runner management |
| `packages/dartclaw_server/lib/src/mcp/mcp_server.dart` | `McpProtocolHandler` – JSON-RPC 2.0 handler |
| `packages/dartclaw_server/lib/src/mcp/mcp_router.dart` | `/mcp` shelf route with auth/validation |
| `packages/dartclaw_server/lib/src/task/task_executor.dart` | `TaskExecutor` – pool-aware task dispatch |
| `packages/dartclaw_server/lib/src/container/container_health_monitor.dart` | Container health polling |
| `packages/dartclaw_core/lib/src/channel/channel_manager.dart` | `ChannelManager` – inbound routing entry point |
| `packages/dartclaw_core/lib/src/channel/channel_task_bridge.dart` | `ChannelTaskBridge` – routing precedence logic |
| `packages/dartclaw_core/lib/src/channel/thread_binding.dart` | `ThreadBinding`, `ThreadBindingStore`, `extractThreadId` |
| `packages/dartclaw_server/lib/src/task/task_notification_subscriber.dart` | Thread binding auto-creation on task notifications |

### External references

- [Claude Code headless docs](https://code.claude.com/docs/en/headless) – stream-json protocol reference
- [Claude Code CLI reference](https://code.claude.com/docs/en/cli-reference) – all flags
- [Claude Code hooks reference](https://code.claude.com/docs/en/hooks) – PreToolUse/PostToolUse
- [MCP specification (Streamable HTTP)](https://modelcontextprotocol.io/docs/spec) – 2025-03-26 transport
