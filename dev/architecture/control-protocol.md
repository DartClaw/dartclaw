# Control Protocol & Harness Architecture

Canonical reference for DartClaw's provider control protocols and the Dart-side harness infrastructure that drives them. DartClaw supports three subprocess protocol families today: Claude Code's ad-hoc JSONL control protocol, Codex's JSON-RPC 2.0-like JSONL app-server protocol, and ACP stdio JSON-RPC for verified ACP agents.

**Current through**: 0.25.1 Bash-env credential strip covering `CLAUDE_CODE_OAUTH_TOKEN`; 0.25 security posture corrections; guarded MCP dispatch seam; typed turn contract; structured-output,
provider-session threading, and capacity-only lane retirement

---

## 1. Protocol Overview

DartClaw communicates with provider binaries over bidirectional subprocess protocols on stdin and stdout. Claude Code uses JSONL, Codex app-server uses JSON-RPC-like JSONL, and ACP agents use ACP stdio JSON-RPC.

| Dimension | Claude Code protocol | Codex JSON-RPC JSONL protocol | ACP stdio JSON-RPC protocol |
|---|---|---|---|
| Wire format | Ad-hoc JSONL messages over stdin/stdout | JSON-RPC 2.0-like messages over stdin/stdout, serialized as JSONL | JSON-RPC 2.0 over subprocess stdio |
| Direction | DartClaw sends turn and control requests; the binary streams events, control requests, and results back | DartClaw sends `initialize`, `initialized`, `thread/start` or `thread/resume`, and `turn/start`; Codex streams notifications and approval requests back | `AcpHarness` drives ACP session methods; direct agents may make host reverse-calls for filesystem operations |
| Lifecycle | Spawn `claude`, initialize once, then send user turns against the long-lived process | Spawn `codex app-server`, complete `initialize`/`initialized`, create a thread, then send turns against that thread | Spawn configured ACP binary such as `goose acp` or `vibe-acp`, initialize once, then route turns through `AcpClient` |
| Streaming | `content_block_delta`, assistant/tool blocks, and `compact_boundary` compaction markers | `item/agentMessage/delta`, `item/started`, `item/completed`, `turn/completed`, `turn/failed` | ACP session updates adapted into DartClaw bridge events by `AcpProtocolAdapter` |
| Tool approval | `control_request` plus hook callbacks (`can_use_tool`, `PreToolUse`, `PostToolUse`, `PermissionDenied`, `PreCompact`) | JSON-RPC approval requests from server to client; DartClaw evaluates guards and replies allow/deny | Handler-level reverse-calls route through `GuardChain.evaluateBeforeToolCall(...)` before host file or terminal actions |
| Session continuity | DartClaw-owned replay is the default; an explicit provider-session request enables persistent Claude storage and cross-process `--resume` | DartClaw-owned replay is the default; durable system or dedicated homes can explicitly use `thread/resume` across app-server processes | Each turn opens a fresh ACP session and injects bounded persisted history; provider-session resume is refused |

### Workflow bounded-turn path

Workflow-owned agent steps lease a coordinator worker and run their complete bounded prompt chain through that worker's guarded `TurnRunner`. DartClaw retains ownership of the task row, workflow state, session transcript, budget checks, structured-output persistence, cancellation, and progress monitoring. There is no separate provider-CLI execution stack.

- Main-agent user and channel turns use the fixed serialized primary-interactive lane. Cron/system jobs, ordinary tasks, logical-agent turns, and workflow steps use provider worker capacity.
- Workflow YAML step types are preserved on the hydrated `WorkflowStepExecution` side-table row (`stepType`); the workflow runtime dispatches every workflow step through the task execution path and expresses write intent through `readOnly` (set on the task config when `step_config_policy.stepIsReadOnly()` holds).
- `format: json` with `schema` has **two enforcement modes, and the step declares neither** — the provider decides. Where the protocol returns typed structured output, the schema is forwarded and the provider enforces it; Claude is that case. Where it does not — Codex app-server has no typed validated readback — the schema is **withheld** from the harness, so nothing claims enforcement it lacks, and the finalizer envelope carries the structure instead: the prompt declares one JSON object, the runner reads the reply body as that object, and `SchemaValidator` validates it host-side, with one retry and then `missing_envelope` / `malformed_envelope`. Reading the declared object is not prose parsing — there is one shape, one decode, no fallback strategy and no repair.
- The main prompt, follow-ups, envelope finalizer, and retry reserve turns on the same worker. Provider protocol streaming supplies the liveness events used by turn-progress governance.

### Execution allocation boundary

Global turn governance runs before execution allocation. After it admits a request, `ExecutionCoordinator` is the sole authority for lane selection, queue/fail-fast admission, per-provider capacity permits, reusable worker lookup, worker creation, replacement, quarantine, and release. Callers never inspect provider identity to choose an execution mechanism; provider-specific behavior is confined to adapters and composition/wiring.

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
       [--no-session-persistence | --resume <provider-session-id>] \
       --dangerously-skip-permissions \      # default; replaced by the permission flags below per the matrix
       [--permission-mode <mode>] \
       [--permission-prompt-tool stdio] \
       [--setting-sources project] \
       [--settings <json>] \
       --model opus[1m] \
       [--effort <level>] \
       [--append-system-prompt <prompt>] \
       [--mcp-config <path>] \
       [--json-schema <json>]
```

| Flag | Purpose |
|---|---|
| `--print` | Output mode (non-interactive) |
| `--input-format stream-json` | Accept JSONL on stdin |
| `--output-format stream-json` | Emit JSONL on stdout |
| `--verbose` | Include all stream events (not just final result) |
| `--include-partial-messages` | Emit `assistant` messages with partial tool blocks |
| `--no-session-persistence` | Disable the binary's own session storage; emitted on ordinary turns where DartClaw manages persistence, but omitted when a turn requests provider-session resume |
| `--resume <provider-session-id>` | Resume a persistent Claude session; emitted only for an explicit provider-session id and paired with persistence enabled |
| `--dangerously-skip-permissions` | Disable Claude's native permission gate (which assumes an interactive TTY); DartClaw's own guard chain, `disallowedTools`, and container isolation are the real enforcement boundary. **Default** – emitted when no `permissionMode` is configured and the profile is not `restricted`. See the permission-flag matrix below |
| `--permission-mode <mode>` | Emitted only when `providers.claude.options.permissionMode` is set, to one of Claude's canonical modes (`acceptEdits`, `auto`, `bypassPermissions`, `default`, `dontAsk`, `plan`) |
| `--permission-prompt-tool stdio` | Route tool approval requests through the JSONL `can_use_tool` channel (not an interactive TTY). Emitted only when native permissions are *not* skipped – the `restricted` container profile, or a non-`bypassPermissions`/`dontAsk` `permissionMode`. **Not** emitted in the default config |
| `--setting-sources project` | Project-only settings isolation. Omitted by default so Claude loads user, project, and local settings; emitted only when `providers.claude.inherit_user_settings: false` |
| `--settings <json>` | Inline settings JSON (sandbox / permissions allow-deny). Emitted only when the provider's `sandbox`/`permissions`/`settings` options are present |
| `--model` | Model selection – bare names (`haiku`, `sonnet`, `opus`) or with context suffix (`opus[1m]`). Default: `opus[1m]`. Configurable via `HarnessLaunchOptions` |
| `--effort` | Reasoning effort level: `low`, `medium`, `high`, `max` (optional; configurable via `HarnessLaunchOptions`) |
| `--append-system-prompt` | Behavior content injected at spawn (append-mode strategy) |
| `--mcp-config` | Path to ephemeral MCP config file pointing at DartClaw's internal MCP server |
| `--json-schema` | Inline JSON Schema the CLI enforces on the turn's final output, emitted only when `turn(outputSchema: ...)` supplies one. Process-level, so a changed schema joins the desired-state comparison and restarts the process – **dropping** the schema restarts too, and every restart re-injects the bounded `<conversation_history>` replay, so alternating schema-bearing and schema-free turns pays two restarts and two replays per pair |

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

Direct host-side Claude harness spawns omit `--setting-sources` by default. Claude's default is to load user, project, and local settings, which makes user-scope plugins, skills, agents, commands, and MCP configuration visible to interactive and workflow workers. Set `providers.claude.inherit_user_settings: false` to restore the previous project-only posture; DartClaw then passes `--setting-sources project` before `--model` on every direct harness spawn. Containerized Claude spawns do not use this flag because the container provides the isolation boundary.

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
    "model": "sonnet"
  }
}
```

Key fields in the `request` object:

| Field | Source | Description |
|---|---|---|
| `hooks` | Hardcoded | Unfiltered `PreToolUse` (30s, all built-ins and dynamic MCP tools), `PostToolUse` (10s, audit), `PermissionDenied` (10s, audit), and `PreCompact` (10s, compaction signal) |
| `disallowedTools` | `HarnessLaunchOptions.disallowedTools` | Tool blocklist enforced by the binary |
| `maxTurns` | `HarnessLaunchOptions.maxTurns` | Safety cap on agentic loops |
| `model` | `HarnessLaunchOptions.model` | Model override (supports `[1m]` suffix for extended context, e.g. `opus[1m]`) |
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
  "system_prompt": "You are DartClaw, a security-conscious agent..."
}
```

`AgentHarness.turn.systemPrompt` is a scoped per-turn contract independent of prompt strategy: a non-empty value is authoritative; an empty value selects the harness's configured default. `ClaudeCodeHarness` uses `PromptStrategy.append`, so ordinary turns omit `system_prompt`. A non-empty logical-agent persona or conversational onboarding prompt participates in the process desired-state comparison and is applied by a single restart with `--append-system-prompt` together with any model or effort change. Switching the pooled process to a different logical session also restarts it, preventing conversation leakage; persisted history is replayed after that restart. The next empty turn restores the configured append prompt.

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

**PreCompact** hooks are bounded capture boundaries. While a host turn is active, DartClaw reads a small persisted message tail, redacts and UTF-8 caps it, attempts to store it as a canonical observation with host-bound provenance, then responds with `allow` exactly once and emits `CompactionStartingEvent`. Capture failure is logged and fails open only after the attempt settles, so compaction cannot deadlock. Harnesses with this deterministic boundary suppress heuristic pre-compaction flush logic.

### 4.7 MCP Messages (sdkMcpServers fallback)

When the internal HTTP MCP server is not configured (chat mode without `serve` command), memory tools are registered via `sdkMcpServers` in the initialize handshake. The binary proxies tool calls as JSON-RPC over the control protocol.

**claude → Dart (tool call):**

```json
{
  "type": "control_request",
  "request_id": "req_77_mcp",
  "request": {
    "subtype": "mcp_message",
    "server_name": "dartclaw",
    "message": {
      "jsonrpc": "2.0",
      "id": 1,
      "method": "tools/call",
      "params": { "name": "memory_observe", "arguments": { "text": "User prefers dark mode", "role": "observation" } }
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
        "result": {
          "content": [{
            "type": "text",
            "text": "{\"locator\":\"1166a7c8-2e4d-4c0c-bbf1-3aa5258b6019\",\"role\":\"observation\",\"entryRevision\":1,\"collectionRevision\":42,\"indexState\":\"current\"}"
          }]
        }
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

A turn spawned with `--json-schema` additionally carries `structured_output` (the payload the CLI validated against the
schema) and, when validation never succeeded, `subtype: "error_max_structured_output_retries"`.

Parsed into the wire message `TerminalResult(stopReason, subtype, structuredOutput, costUsd, durationMs, inputTokens, outputTokens, cacheReadInputTokens, cacheCreationInputTokens)`, which the harness converts into the provider-independent `TurnResult` it completes the pending `_turnCompleter` with, ending the `turn()` call. The retry-exhaustion subtype ends the turn as an error — a terminal result is an outcome, not a success, and a successful turn with a null payload would be indistinguishable from a model that chose to return nothing.

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
└── TerminalResult      – stopReason, subtype, structuredOutput, costUsd, durationMs,
                          inputTokens, outputTokens, cacheReadInputTokens,
                          cacheCreationInputTokens
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

`ControlRequest` and `TerminalResult` are handled internally by the harness and never forwarded to consumers. `ToolUseEvent` and `ToolResultEvent` are also used internally for `ToolCallRecord` correlation (see [Enriched Turn Data Extraction](#7-enriched-turn-data-extraction)).

---

## 6. Turn Lifecycle

A complete turn flows through multiple layers. The following diagram shows the full path from user message to stored response.

```
User (Web/Channel/Cron/Task)
  │
  ▼
TurnManager.startTurn(sessionId, messages) → reserveTurn(sessionId)
  │ same-session reservations run one at a time, in arrival order
  │ (per-session SessionMutationCoordinator chain; see session-state-architecture § 6)
  │ (TaskExecutor skips this box and calls the coordinator directly)
  ▼
ExecutionCoordinator.acquire(request)
  │ admission: TurnGovernanceEnforcer checks (budget, loop, rate limit),
  │            then ① acquire session lock (SessionLockManager)
  │ fixed primary lease for main user/channel turns
  │ provider worker lease for cron/system/task/logical-agent turns
  ├─ provider worker lease ──► WorkflowOneShotRunner (bounded workflow prompt chain)
  │
  │ runner-backed lease
  ▼
TurnRunner.reserveAdmittedTurn(sessionId) on the leased runner
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
  │ ⑤ Resolve system prompt
  │   ├─ Non-empty per-turn override is authoritative (logical-agent persona or onboarding)
  │   └─ Otherwise compose BehaviorFileService prompt for the request scope
  │
  │ ⑥ Subscribe to harness.events stream
  │   ├─ DeltaEvent      → buffer + progress reset + session activity touch
  │   ├─ ToolUseEvent    → tool log + progress reset + session activity touch
  │   ├─ ToolResultEvent → tool correlation + progress reset + session activity touch
  │   └─ SystemInitEvent → context-window update only (not counted as progress)
  │
  ▼
AgentHarness.turn(sessionId, messages, systemPrompt, agentId?, providerSessionId?, requestProviderSessionResume?, ...)
  │
  │ ⑦ Reconcile provider-specific persona, working directory, model, and effort state
  │   └─ Claude restarts once when its spawn-time desired state changes
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
  │ ── result ─────────────────────────► TerminalResult → complete turnCompleter
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
  │ ⑰ Apply MessageRedactor to the assistant reply (proportional content redaction)
  │ ⑱ Persist assistant message to MessageService
  │ ⑲ Append redacted main/user/channel tool-using turns to daily log (YYYY-MM-DD.md)
  │
  │ ⑳ If ContextMonitor.shouldFlushForCompactionSignal(...): run pre-compaction flush turn
  │
  ▼
Finally block
  │ ㉑ Remove active turn from _activeTurns
  │ ㉒ Release session lock
  │ ㉓ Delete turn-state row from TurnStateStore
  │ ㉔ Cache TurnOutcome (TTL: 30s)
  │ ㉕ Complete _outcomePending completer
  │ ㉖ Release the execution lease; cache, dispose, or quarantine the worker
  ▼
TurnOutcome { turnId, sessionId, status, responseText?, structuredOutput?, providerSessionId?,
              inputTokens, outputTokens, turnDuration, cacheReadTokens, cacheWriteTokens, toolCalls }
```

When a stall budget is enabled, `TurnLivenessTracker` starts immediately before `AgentHarness.turn()` and stops in the `finally` block with the rest of turn cleanup. Stall actions are intentionally narrow:
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

`TurnRunner._runTurnInner()` collects richer data from the turn stream beyond the final `TurnResult`. This enrichment is transparent to consumers – they receive the final `TurnOutcome` with all fields populated.

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
├── toolCalls: List<ToolCallRecord> – correlated from stream events
├── structuredOutput: Map<String, dynamic>? – completed provider payload after output guards pass
└── providerSessionId: String?    – provider-reported identity; absent when unreported or guard-blocked
```

At runner settlement, `ExecutionCoordinator` forwards the enriched outcome to `RunnerObserver`; `TurnTraceService` and
`TaskEventRecorder` consume the same normalized fields for task-specific persistence. Cache token normalization at the
adapter layer keeps every consumer provider-agnostic.

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

Claude may first invoke exact provider-native `ToolSearch` to load a deferred tool's schema. Under a non-empty closed allowlist, DartClaw permits that metadata-only discovery after deny checks, then independently evaluates the selected tool call against the same policy. An explicit discovery deny or a toolless policy still blocks discovery.

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
        │   Guard types: CommandGuard, FileGuard, NetworkGuard, etc.
        │   Verdicts: pass / warn / block
        │
        ├─► If block → deny response (hookSpecificOutput.permissionDecision: "deny")
        │
        ├─► Credential stripping: if toolInput.env contains ANTHROPIC_API_KEY or
        │   CLAUDE_CODE_OAUTH_TOKEN, strip them and return updatedInput in hookSpecificOutput
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
  Future<TurnResult> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    String? agentId,
    Map<String, dynamic>? mcpServers,
    String? providerSessionId,
    bool requestProviderSessionResume = false,
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
    Map<String, dynamic>? outputSchema,
  });
  bool get supportsProviderSessionResume; // defaults to false on the contract
  bool get supportsStructuredOutput;    // defaults to false on the contract
  Future<void> cancel();
  Future<void> stop();
  Future<void> dispose();
}
```

`turn()` returns a typed `TurnResult` (`stopReason`, `error`, `costUsd`, `sessionTitle`, `providerSessionId`, `structuredOutput`, and
non-nullable `inputTokens`/`outputTokens`/`cacheReadTokens`/`cacheWriteTokens`, plus `isError`/`isCancelled`
predicates). The field set is the union every consumer reads, so a provider that cannot supply a value must still name
it — a key one harness never emits is a compile error rather than a silent zero.

#### Provider-session resume is explicit and durability-gated

`providerSessionId` resumes a provider-owned conversation, while `requestProviderSessionResume` bootstraps or continues
a session whose id can be used by a later process. Supplying an id implies the request. A harness whose
`supportsProviderSessionResume` is false refuses either input before provider work, and `TurnResult.providerSessionId`
is non-null only when the provider state outlives the current process. Claude supports the contract by enabling session
persistence and using `--resume`. Codex supports it only with a resolved system or dedicated `CODEX_HOME`; isolated and
container auth-clean homes are non-durable. ACP refuses it. DartClaw-owned history replay remains the default when neither
input is supplied.

#### Structured output is per-provider, and refused by name where it is unavailable

`outputSchema` is an opaque JSON Schema the provider must enforce; the payload comes back on
`TurnResult.structuredOutput` and the harness never judges, repairs, or scrapes it. `supportsStructuredOutput` defaults
to `false` on the contract, and `AgentHarness.requireStructuredOutputSupport(...)` — called at the entry of every
`turn()` — throws `UnsupportedHarnessCapabilityException` naming the provider and the capability before any provider
work happens. An unenforceable schema therefore fails loudly instead of being dropped into a result the caller cannot
distinguish from an enforced one.

The refusal is a **call each implementation makes**, not a shape the type system imposes: `turn()` is not sealed, so a
harness adopting the contract with `implements` inherits no body and could omit it. What makes it a guarantee rather
than a convention is `dev/fitness/test/structured_output_refusal_test.dart`, which fails the build on any concrete
harness in any workspace member's `lib/` that declares fewer refusal calls than harnesses. Sealing `turn()` behind a
`performTurn()` hook is the structural alternative; it reverses this section's stated decision and breaks every
`implements` adopter, so it needs an ADR rather than a refactor.

| Harness | `supportsStructuredOutput` | Channel |
|---|---|---|
| `ClaudeCodeHarness` | `true` | `--json-schema` spawn flag; payload on the terminal `result` event's `structured_output`. Process-level, so a changed schema restarts the process |
| `CodexHarness` | `false` | `turn/start` accepts an `outputSchema` param, but the app server returns the final assistant message as plain `text` with no field distinguishing a schema-validated payload from ordinary prose. Recovering it would mean parsing that text, which is a heuristic rather than enforcement evidence, so support is not claimed |
| `AcpHarness` | `false` | ACP's `session/prompt` has no output-schema field at all |

### Concrete implementations

Three concrete implementations exist today. `dartclaw_core` owns Claude and Codex; `dartclaw_acp` owns ACP and registers it through the generic factory seam:

- `ClaudeCodeHarness` – Claude Code JSONL protocol (primary, default)
- `CodexHarness` – Codex JSON-RPC app-server protocol (see [Codex JSON-RPC Protocol](#codex-json-rpc-protocol))
- `AcpHarness` – ACP stdio JSON-RPC protocol for configured ACP agents such as Goose and Vibe

`HarnessFactory` creates built-in instances and accepts generic registrations. `AcpHarnessRegistrar` in `dartclaw_acp` contributes ACP entries without a server-side ACP branch. `ExecutionCoordinator` owns post-governance allocation; reusable runners are only its opportunistic process cache. Each provider identity has worker capacity from `providers.<id>.pool_size`. Logical-agent sessions acquire an exact provider lease and never use the primary-interactive lane. ACP agent registration controls spawn and security classification, not custom capacity. Provider selection changes the factory/adapter used by wiring, never orchestration semantics.

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
| Session isolation | Restarts when a pooled worker changes DartClaw session; cold turns replay bounded persisted history |

### HarnessLaunchOptions

Configuration forwarded in the initialize handshake:

```dart
class HarnessLaunchOptions {
  final List<String> disallowedTools;  // Tool blocklist
  final int? maxTurns;                 // Safety cap
  final String? model;                 // Model selection (supports [1m] suffix)
  final String? effort;                // Reasoning-effort override
  final String? appendSystemPrompt;    // Behavior content (spawn-time flag)
  final String? mcpServerUrl;          // Internal MCP server URL
  final String? mcpGatewayToken;       // MCP bearer auth token
}
```

#### AcpHarness

`AcpHarness`, its config DTOs/parser, validation and registration live in `dartclaw_acp`. It wraps an ACP agent subprocess using stdio JSON-RPC. The configured `harness.acp.agents.<id>` entry supplies the binary, args, topology, model provider, verification evidence, and required built-ins. Its container fields (`container_isolation_required`, `container_profile`) are inputs to the startup compatibility computation, not a runnable placement — see below. Missing `topology` defaults to `unverified`. Every turn creates and closes a provider session, so DartClaw injects bounded replay-safe history before the current message rather than relying on provider-side continuity.

Only direct-provider ACP agents that advertise and honor host `fs` capabilities can be classified as guard-mediated. Goose direct-provider targets require the `developer` extension, a direct model provider selector, and verification evidence when guard mediation is required; known proxy selectors such as `claude-acp` and `codex-acp` are rejected as direct-provider claims. Vibe must prove the declared provider is non-proxy or pass startup verification before DartClaw marks it guard-mediated.

Relay-provider and unverified ACP agents claim no guard mediation, so container isolation is their only boundary. DartClaw mediates no provider credential or host capability for an ACP client inside a container — the host gateway's provider adapters are verified for the Claude and Codex clients only — so that boundary cannot be provided and those registrations are unavailable. A `harness.acp.agents.<id>` entry with `container_isolation_required: true` is rejected at startup with its exact configuration path, and every other ACP registration runs only where the resolved execution policy selects host execution. Compatibility is computed from the existing registration fields intersected with the resolved policy (`ProviderExecutionInventory`); no registration field grants container support, and no launch path substitutes host execution for a rejected container policy.

ACP reverse-calls are bound at the host handler boundary:

| ACP method | Canonical tool | Guard/audit behavior |
|---|---|---|
| `fs/read_text_file` | `file_read` | Calls `GuardChain.evaluateBeforeToolCall(...)` with `rawProviderToolName: "fs/read_text_file"` |
| `fs/write_text_file` | `file_write` | Calls `GuardChain.evaluateBeforeToolCall(...)` with `rawProviderToolName: "fs/write_text_file"` |
| `terminal/create` | unavailable | Rejected on every host until DartClaw can prove containment of the complete spawned process tree |

Every filesystem reverse-call is bound to the active host session and effective workspace directory. Calls outside an active turn are rejected, and guard evaluation carries the host session ID so task-local tool and read-only policies apply.

DartClaw does not advertise `terminal.create` and rejects all ACP terminal lifecycle calls on every host because complete descendant containment is not yet proven. Filesystem reverse-calls remain available. Container-isolated ACP agents advertise no host reverse-calls.

### Per-turn execution changes

The harness contract supports per-turn persona, working directory, model, effort, output-schema, and provider-session inputs. Claude applies these as spawn-time desired state and performs one stop-and-restart cycle when that state changes — the output schema and provider-session id included, since both are spawn flags. That cost is symmetric: adding or dropping either input is a change, and each restart re-injects the bounded history replay. Codex applies persona/model/effort to its session thread, uses `thread/resume` for an explicit durable provider session, and refuses an output schema. ACP prepends the persona to the prompt, ignores model/effort overrides, and refuses output-schema and provider-session inputs.

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

When running via `dartclaw serve`, `/mcp` is mounted for gateway-authenticated deployments and authentication-disabled loopback deployments. Authentication-disabled non-loopback deployments do not mount it. The `claude` and `codex` binaries discover the mounted endpoint through their provider adapters:

```
DartclawServer (shelf)
  │
  ├── /api/*          REST API
  ├── /webhook/*      Channel webhooks
  └── /mcp            MCP server (Streamable HTTP, JSON-RPC 2.0)
                        ▲
                        │ POST /mcp (JSON-RPC)
                        │ Authorization: Bearer <token> (auth-enabled mode)
                        │
                      claude binary
```

**MCP config file** (ephemeral, `chmod 600`, auto-deleted on harness stop):

```json
{
  "mcpServers": {
    "dartclaw": {
      "type": "http",
      "url": "http://localhost:3333/mcp",
      "headers": { "Authorization": "Bearer <gateway-token>" }
    }
  }
}
```

The bearer header is omitted only for an authentication-disabled loopback deployment. That route still requires an exact loopback request `Host` and exact loopback browser `Origin`.

**Registered tools** (via `McpProtocolHandler`):

| Tool | Implementation | Registration | Description |
|---|---|---|---|
| `memory_apply` | `MemoryApplyTool` | always | Atomically curate personal memory with collection CAS |
| `memory_observe` | `MemoryObserveTool` | always | Capture observations or bounded learnings |
| `memory_search` | `MemorySearchTool` | always | Natural-language search over canonical entries and native wiki sources |
| `memory_read` | `MemoryReadTool` | always | Read bounded canonical records by locator or role/topic, or reopen native wiki/KG/inbox/QMD locators through their source owners |
| `kg_add` | `KgAddTool` | always | Add a source-linked temporal fact to the knowledge graph |
| `kg_query` | `KgQueryTool` | always | Query temporal knowledge-graph facts by entity/predicate (+ optional `as_of`) |
| `kg_timeline` | `KgTimelineTool` | always | Return the full temporal fact timeline for an entity |
| `kg_invalidate` | `KgInvalidateTool` | always | Invalidate a temporal fact without deleting its history |
| `kg_contradictions` | `KgContradictionsTool` | always | Find open facts that would contradict an incoming fact |
| `sessions_spawn` | `SessionsSpawnTool` | always | Create a hidden configured logical-agent conversation and run its first turn |
| `sessions_send` | `SessionsSendTool` | always | Continue a logical-agent conversation by its returned session handle |
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
  McpToolAccess get access; // read | write — required, no default
  Future<ToolResult> call(Map<String, dynamic> args);
}
```

`access` is undefaulted so a new tool cannot omit the read/write answer a consumer partitioning the tool surface
depends on. Dispatch itself is guarded and audited once for every registered tool — see
[Security Architecture](security-architecture.md#guard-chain) — so a tool carries no guard plumbing of its own.

The MCP router (`mcp_router.dart`) handles bearer or exact-loopback request validation, content-type validation, payload size limits (1 MB), and exact loopback origin checking for browser clients.

### Mechanism B: sdkMcpServers (chat mode fallback)

When no MCP server URL is configured (running without `serve`), memory tools are registered inline in the `initialize` handshake via `sdkMcpServers`. The binary proxies tool calls through `mcp_message` control requests (see section 4.7). This is a Claude-SDK-private extension, not the published MCP spec.

**Migration**: Mechanism B is retained for backward compatibility. Mechanism A is preferred and will eventually replace B entirely. See [ADR-009](../adrs/009-internal-mcp-server.md).

---

## Codex JSON-RPC Protocol

See the Codex CLI Harness Research (private repo: `docs/research/codex-cli-harness/research.md`) for the protocol analysis that informed this section.

Codex integrates through `codex app-server`, a long-lived subprocess that speaks JSON-RPC 2.0-like messages over stdin/stdout and serializes them as JSONL. DartClaw does not use `--yolo`; the configured approval policy determines which operations reach the host approval handler.

### Spawn and handshake

The Codex harness spawns the app-server binary directly:

```bash
codex app-server
```

Startup uses a two-step handshake:

1. DartClaw sends `initialize`.
2. Codex responds, then DartClaw sends `initialized`.

Only after that does DartClaw create a thread with `thread/start`, or load an explicitly requested durable thread with
`thread/resume {"threadId": "…"}`. The first ordinary turn for a session creates a thread; later turns reuse its cached ID.

### Turn lifecycle

Each turn is issued with `turn/start` on the active thread. By default DartClaw passes the current user message plus its
own replayed history. An explicit provider-session id instead loads the rollout from a durable system or dedicated
`CODEX_HOME`; a missing rollout fails the turn and never falls back to `thread/start`.

When the app-server exits unexpectedly, DartClaw clears the cached thread IDs, restarts the process with backoff, re-runs the handshake, creates a fresh thread, and replays the saved history into the next `turn/start` request.

### Streaming notifications

Codex emits turn and item notifications over stdout. DartClaw parses and maps the notifications that matter to its bridge layer:

| Codex notification | DartClaw handling |
|---|---|
| `turn/started` | Lifecycle marker; ignored by the protocol adapter |
| `item/agentMessage/delta` | `DeltaEvent` for incremental text streaming. Carries an `itemId`: a turn that completes several agent messages interleaves their deltas on one stream, so the accumulation is a display artefact, never the answer |
| `item/started` (`contextCompaction`) | `CompactionStartingBridgeEvent` |
| `item/started` (tool item) | `ToolUseEvent` for typed tool items such as `commandExecution`, `fileChange`, `mcpToolCall`, and `webSearch` (legacy snake-case aliases remain accepted) |
| `item/completed` (`contextCompaction`) | `CompactionCompletedBridgeEvent` |
| `item/completed` (tool item / agent message) | `ToolResultEvent` for completed tool items and final agent messages |
| `turn/completed` | Completes the pending turn. Carries **no usage** at codex-cli 0.146.0 — its params are `threadId` and `turn` — and its `turn.items` carry each completed item's authoritative text, which is what the turn's response is read from for `phase: final_answer` agent messages rather than the accumulated deltas |
| `thread/tokenUsage/updated` | The turn's usage. `tokenUsage.last` is this turn's, `tokenUsage.total` the thread's running sum; `inputTokens` includes `cachedInputTokens`, normalised to the fresh-input convention on arrival. Held until the `turn/completed` it precedes |
| `turn/failed` | Completes the pending turn with an error stop reason |

This is the Codex path implemented by `CodexProtocolAdapter`. The adapter also accepts the v0.118.0 `ClientResponse` envelope variants while preserving the same `SystemInit` and thread-id extraction behavior.

### Approval flow

Codex sends tool approval requests back to DartClaw as JSON-RPC requests. Command execution uses
`item/commandExecution/requestApproval`, file changes use `item/fileChange/requestApproval`, and MCP tool approvals use
form-mode `mcpServer/elicitation/request` requests whose `_meta.codex_approval_kind` is `mcp_tool_call`. DartClaw also
accepts the legacy `control/approval` and `approval/request` shapes. Broad
`item/permissions/requestApproval` escalation receives an empty permission grant, and ordinary MCP elicitations are
declined because DartClaw has no interactive form surface. Other server requests receive a terminal JSON-RPC
unsupported-method error rather than holding the turn. It evaluates each recognized tool request through the same guard
chain used elsewhere in the runtime, then replies using that request type's native result shape.

The approval payload is normalized before guard evaluation so DartClaw can strip sensitive environment values and
translate provider tool names into canonical tool names. File approvals reuse the preceding `item/started` context and
evaluate every operation in a batch so create and update policies remain distinct. MCP approval identity comes from the
approval request's server, tool, and arguments rather than ambiguous cached items. Unlike Claude Code, there is no
separate hook system here; the approval round-trip is the interception point.

Approval is intentionally narrower than the provider schema where DartClaw cannot evaluate the full authority. Command
requests fail closed when the command is missing, `accept` is unavailable, or additional filesystem, network, or remote
environment authority is present. A rejection uses `decline` when offered, otherwise `cancel`; if neither safe decision
is available, DartClaw returns a terminal invalid-params error. Proposed exec or network policy amendments do not widen
a one-shot `accept` response, so DartClaw ignores those optional persistence choices and never selects their structured
decisions. File delete, move, and session-root grants are declined until their source, destination, deletion, and
persistence semantics can all be represented by the guard contract. Relative shell paths are evaluated from the
provider-supplied working directory.

#### Per-turn dynamic settings

DartClaw passes `approval_policy` and `sandbox` as per-turn settings in every `turn/start` request. These are configured via the provider's `approval` and `sandbox` options in `dartclaw.yaml` and translated by `CodexSettings.buildDynamicSettings()`:

| DartClaw config | Codex setting | Behavior |
|---|---|---|
| `approval: on-request` | `approval_policy: "on-request"` | Recommended explicit posture – broadest available approval interception for DartClaw's guard chain |
| `approval: unless-allow-listed` | `approval_policy: "granular"` | Partial – safe-listed commands emit no approval request |
| `approval: never` | `approval_policy: "never"` | No approval requests – all tool calls execute immediately |
| `sandbox: workspace-write` | `sandbox: "workspaceWrite"` | Codex sandbox allows writes to working directory only |
| `sandbox: danger-full-access` | `sandbox: "dangerFullAccess"` | No Codex sandbox restrictions |

When `approval` is absent or blank, DartClaw omits `approval_policy` and Codex inherits its own configuration. Because
that inherited posture is not verifiable, serve warns whenever tool-restricted agents or jobs use such a provider.

#### Approval coverage

Codex guard enforcement covers only operations for which app-server emits an approval request. `on-request` provides
the broadest available interception, but provider-safe operations may still execute without a host callback. A missing
or unrecognized approval response can hold the provider turn until DartClaw's `governance.turn_limits.turn_timeout`; server requests
therefore always receive a terminal fail-closed response when guard evaluation fails or the requested authority is
unsupported.

### Crash recovery and history replay

Codex app-server is treated as ephemeral. If the process exits unexpectedly, DartClaw:

1. Clears cached thread IDs for the affected session.
2. Marks the worker crashed and applies the normal exponential backoff restart policy.
3. Spawns a fresh `codex app-server`.
4. Repeats `initialize` / `initialized`.
5. Creates a new thread for the default replay mode. A caller that explicitly supplies a durable provider-session id uses `thread/resume` instead.
6. Replays DartClaw-owned history from the NDJSON message store into the next `turn/start` request via `previous_response_items`.

This keeps ordinary continuity under DartClaw's control. Provider-managed resume is an explicit alternative and is
advertised only when the resolved `CODEX_HOME` outlives the worker process.

## 11. Execution Coordination and Harness Reuse

`ExecutionCoordinator` is the single post-governance execution authority. It separates three concerns that must not be inferred from one another:

- **lane** – which product surfaces may execute together;
- **capacity lease** – whether a provider execution may run now;
- **harness cache** – whether a healthy compatible subprocess happens to be reusable.

### Lanes and surfaces

```
ExecutionCoordinator
  ├── primary-interactive gate (fixed capacity 1)
  │     └── main-agent user + channel turns
  └── provider worker gates (`providers.<id>.pool_size` each)
        └── worker: cron/system jobs, tasks, logical agents, workflow steps
```

The primary-interactive lane is fixed, serialized, and tied to the configured primary provider. It is outside `pool_size`. Worker requests consume one lease from the selected provider. Ordinary worker surfaces may queue; nested logical-agent requests fail fast to avoid waiting on a slot held by their caller.

### Capacity is not a process count

`providers.<id>.pool_size` is a hard ceiling on concurrent worker executions for that provider. Workflow steps use single-use workers, while idle cached harnesses consume no lease. Container count and container lifetime do not affect the limit.

The coordinator returns an idempotent `ExecutionLease`. The lease is released exactly once on every success, failure, cancellation, or setup-error path. Its active set is the source of truth for runtime busy/free/current-work observability.

### Compatible-worker lookup

Harness-construction inputs are fixed for a coordinator's lifetime. Within that boundary, normalized provider ID and the complete effective execution policy identify compatible workers; callers submit those two facts directly rather than constructing a second configuration identity. The cache lookup order is:

1. healthy exact-session worker for the requested provider and policy; a container worker additionally requires the exact logical-agent principal;
2. any healthy host worker with the same provider and identical effective execution policy;
3. create a fresh worker through provider wiring.

Compatibility is the explicit provider plus execution-policy match within the immutable composition — a host worker and a container worker are never interchangeable, and neither are container workers built from different profiles. A mismatch or unknown health means fresh creation. The cache is opportunistic and has no size, TTL, prewarm, or reuse-policy configuration.

### Release, replacement, and quarantine

An idle healthy released host worker may return to the compatible-worker cache. A logical-agent container worker may be retained only for its exact session/agent principal; task containers are stopped and disposed at release. Replacement is permitted only after the harness confirms teardown of its managed root process. If termination cannot be confirmed, the capacity permit is quarantined: effective provider capacity decreases and DartClaw does not spawn an overlapping replacement. Cached excess is scavenged with the same rule.

Each live container authority owns a dedicated container. A standing logical-agent owner's authority spans its turns and ends on discard, eviction, or shutdown; a task authority ends with the turn; a workflow authority spans its step. Destruction follows confirmed root-process termination and authority revocation. A container never crosses principals, and active execution admission remains lease-owned.

### SDK single-harness compatibility

An SDK composition that provides only one harness may serialize ordinary background tasks on that harness when no multi-worker coordinator is present, but only when the request already matches that harness's provider and effective policy. A mismatch fails closed rather than rewriting resolved placement. This is a compatibility exception, not a server routing mode. Logical-agent sessions and production server worker surfaces do not fall back to the primary-interactive lane.

---

## 12. TurnManager and TurnRunner

### TurnManager

Turn-lifecycle wrapper that runs a turn on the `TurnRunner` supplied by an execution lease. It does not select providers, inspect cache state, or own capacity.

```dart
class TurnManager {
  TurnManager({required AgentHarness worker, ...});  // Single-runner convenience

  Future<String> reserveTurn(...);     // Uses the coordinator-leased runner
  void executeTurn(...);
  Future<void> cancelTurn(...);
}
```

The server's coordinator registry supplies cross-runner cancellation and outcome lookup because a session can be active on any leased runner. Task sessions and provider-pinned logical-agent sessions use provider worker leases, never the primary-interactive lane.

Caller cancellation does not yet cascade to a `sessions_spawn` or `sessions_send` child. The inbound MCP call carries no caller-turn identity, and its 120-second `Future.timeout` does not cancel the underlying child future. A caller-aware MCP context and exact parent-to-child registry are scheduled with the 0.27 dispatch-level guard/audit seam; global “active child” cancellation would be unsafe with concurrent callers.

### TurnRunner

Per-harness turn execution engine. Each `TurnRunner` wraps a single `AgentHarness` and encapsulates the full turn lifecycle: guard evaluation, message persistence, event streaming, cost tracking, and crash recovery.

The same bridge-event stream drives one `TurnLivenessTracker` per turn. It resets stall accounting only on forward-progress events (`DeltaEvent`, `ToolUseEvent`, `ToolResultEvent`), while the wall-clock turn budget never resets. A known tool-approval wait suspends stall accounting until the decision resolves. Those progress events also call `SessionResetService.touchActivity(sessionId)`, so long-running turns keep the session alive based on actual harness activity rather than wall-clock turn age.

**Key state:**

| Field | Type | Purpose |
|---|---|---|
| `_activeTurns` | `Map<String, TurnContext>` | Currently executing turns (sessionId → context) |
| `_cancelledTurns` | `Set<String>` | Turn IDs that have been cancelled |
| `_recentOutcomes` | `Map<String, (TurnOutcome, DateTime)>` | TTL-cached outcomes (default 30s) |
| `_outcomePending` | `Map<String, Completer<TurnOutcome>>` | Pending outcome waiters |
| `_turnLimits` | `TurnLimitsConfig` | Stall and wall-clock budgets from `governance.turn_limits`; zero disables the corresponding limit |
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

`TurnRunner` is the single enforcement site for interactive, logical-agent, task, and workflow turns. An agent workflow step may override the wall-clock budget with `turn_timeout`; otherwise it inherits `governance.turn_limits.turn_timeout`. Harness deadlines are crash backstops derived from the effective turn budget, not a second operator-facing limit.

---

## 13. Task Container Placement

The task lane defaults to `workspace`; an authenticated operator
may declare `securityProfile: workspace|restricted` on `POST /api/tasks`. The profile is persisted in task
configuration and passed to the one execution-policy resolver. Channel and model-facing creation seams cannot carry
the declaration, and the retired `research` category is refused rather than widened.

| Declaration | Profile | Container characteristics |
|---|---|---|
| omitted or `workspace` | `workspace` | Full workspace mount at `/project`, read-write access |
| `restricted` | `restricted` | No workspace mount, no project filesystem access |

The caller resolves the provider-neutral security profile, then submits it as part of an `ExecutionRequest`. Provider identity is data; only provider composition/wiring selects the concrete adapter or factory.

```dart
ExecutionRequest(
  surface: ExecutionSurface.task,
  providerId: normalizedProviderId,
  policy: effectivePolicy,
  sessionId: durableSessionId,
)
```

There is no policy or provider fallback. Each live container authority owns a container created when it is admitted and destroyed when it is released; a container neither reserves provider capacity nor holds conversation state.

### Container naming

Containers are uniquely named from a hash of the data directory plus the owning profile and authority:

```
dartclaw-<fnv1a8(dataDir)>-<profileId>[-<authority>]
```

Example: the shared provider-CLI containers are `dartclaw-a1b2c3d4-workspace` and `dartclaw-a1b2c3d4-restricted`; a dedicated authority container adds a per-process-unique suffix, e.g. `dartclaw-a1b2c3d4-workspace-m9x2k1`.

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

An in-place restart and a coordinator replacement both require confirmed exit of the managed root process. If exit cannot be confirmed, the harness is not reusable and the coordinator quarantines its provider capacity slot instead of starting a second root process against the same logical capacity.

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

The coordinator treats teardown confirmation as a replacement gate, not merely a log signal. A worker whose root exit is unconfirmed is disposed as far as safely possible, omitted from the cache, and leaves its capacity permit quarantined.

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
| 1 | Thread-binding lookup | Matching binding | Captures bound task/session context |
| 2 | Per-sender rate limit | Rate limit exceeded (non-admin, non-reserved) | Rejected with rate-limit message, returns `true` |
| 3 | Bound-thread routing | Matching binding and enqueue callback | Enqueued to bound task session, returns `true` |
| – | Fall-through | None of the above | Returns `false` – normal session routing via queue |

When `tryHandle()` returns `false`, the message is enqueued with the derived session key as normal.

### Thread Binding

Thread binding enables per-task conversation threads in Google Chat Spaces. It is opt-in through
`features.thread_binding.enabled`; when disabled, the runtime does not create the binding store or wire binding behavior:

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
  StreamSink<List<int>> output, {
  void Function(Object error)? onStreamError,
})
```

**Input pipeline**: `bytes → utf8.decode → LineSplitter → filter empty → String events`

**Output pipeline**: `String → append '\n' → utf8.encode → bytes`

`onStreamError`, when supplied, takes ownership of every input error – notably the `FormatException` `utf8.decoder` raises on a byte it cannot decode, including the partial multi-byte sequence a dying writer leaves behind – so nothing downstream sees it. The error does not end the stream: `handleError` consumes it and the stream runs on until the input ends. `AcpClient` passes it through so `AcpHarness` can treat an undecodable agent stdout as a provider fault; without it the error reaches the `json_rpc_2.Peer`, which parks it on the `listen()` future nothing awaits until close.

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
| `docs/diagrams/harness-architecture.excalidraw` | Worker capacity, runner, container dispatch |
| `docs/diagrams/turn-lifecycle.excalidraw` | Full turn flow from user message to stored response |
| `docs/diagrams/dartclaw-architecture.excalidraw` | High-level 2-layer architecture |
| `docs/diagrams/security-architecture.excalidraw` | Defense-in-depth layers, credential isolation |

### Source files (public repo)

| File | Contents |
|---|---|
| `packages/dartclaw_core/lib/src/harness/claude_code_harness.dart` | `ClaudeCodeHarness` – all JSONL handling, spawn, lifecycle |
| `packages/dartclaw_core/lib/src/harness/claude_protocol.dart` | `ClaudeMessage` sealed hierarchy + `parseJsonlLine()` |
| `packages/dartclaw_core/lib/src/harness/agent_harness.dart` | `AgentHarness` abstract interface |
| `packages/dartclaw_core/lib/src/harness/harness_launch_options.dart` | `HarnessLaunchOptions` – initialize handshake fields |
| `packages/dartclaw_core/lib/src/harness/tool_policy.dart` | `ToolApprovalPolicy`, response builders |
| `packages/dartclaw_core/lib/src/harness/mcp_tool.dart` | `McpTool` interface |
| `packages/dartclaw_core/lib/src/harness/tool_result.dart` | `ToolResult` sealed class |
| `packages/dartclaw_core/lib/src/bridge/bridge_events.dart` | `BridgeEvent` sealed hierarchy |
| `packages/dartclaw_acp/lib/src/ndjson_channel.dart` | ACP NDJSON transport utility |
| `packages/dartclaw_acp/lib/src/acp_harness.dart` | `AcpHarness` – ACP lifecycle and turns |
| `packages/dartclaw_acp/lib/src/acp_protocol_adapter.dart` | ACP session updates to core bridge events |
| `packages/dartclaw_acp/lib/src/acp_harness_registrar.dart` | ACP config composition and generic runtime registration |
| `packages/dartclaw_core/lib/src/security/guard.dart` | `Guard`, `GuardChain` |
| `packages/dartclaw_core/lib/src/security/guard_audit.dart` | `GuardAuditLogger`, `GuardAuditSubscriber` |
| `packages/dartclaw_runtime/lib/src/container/container_manager.dart` | `ContainerManager` – Docker lifecycle |
| `packages/dartclaw_runtime/lib/src/turn_manager.dart` | `TurnManager` – orchestration wrapper |
| `packages/dartclaw_runtime/lib/src/turn_runner.dart` | `TurnRunner` – per-harness turn execution |
| `packages/dartclaw_runtime/lib/src/execution_coordinator.dart` | `ExecutionCoordinator`, execution requests/leases, provider/profile reuse, quarantine, lease snapshots |
| `packages/dartclaw_runtime/lib/src/worker_capacity_gate.dart` | Hard per-provider execution-capacity permits |
| `packages/dartclaw_runtime/lib/src/mcp/mcp_server.dart` | `McpProtocolHandler` – JSON-RPC 2.0 handler |
| `packages/dartclaw_runtime/lib/src/mcp/mcp_router.dart` | `/mcp` shelf route with auth/validation |
| `packages/dartclaw_runtime/lib/src/task/task_executor.dart` | `TaskExecutor` – coordinator-aware task dispatch |
| `packages/dartclaw_runtime/lib/src/container/container_health_monitor.dart` | Container health polling |
| `packages/dartclaw_core/lib/src/channel/channel_manager.dart` | `ChannelManager` – inbound routing entry point |
| `packages/dartclaw_core/lib/src/channel/channel_task_bridge.dart` | `ChannelTaskBridge` – routing precedence logic |
| `packages/dartclaw_core/lib/src/channel/thread_binding.dart` | `ThreadBinding`, `ThreadBindingStore`, `extractThreadId` |
| `packages/dartclaw_runtime/lib/src/task/task_notification_subscriber.dart` | Thread binding auto-creation on task notifications |

### External references

- [Claude Code headless docs](https://code.claude.com/docs/en/headless) – stream-json protocol reference
- [Claude Code CLI reference](https://code.claude.com/docs/en/cli-reference) – all flags
- [Claude Code hooks reference](https://code.claude.com/docs/en/hooks) – PreToolUse/PostToolUse
- [MCP specification (Streamable HTTP)](https://modelcontextprotocol.io/docs/spec) – 2025-03-26 transport
