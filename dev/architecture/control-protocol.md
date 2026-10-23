# Control Protocol & Harness Architecture

How DartClaw drives provider binaries and runs a turn: the `AgentHarness` abstraction, the three subprocess protocols behind it (Claude Code JSONL, Codex app-server JSON-RPC, ACP stdio JSON-RPC), the execution coordinator and turn runner that wrap a harness, MCP tool exposure, and harness crash recovery. Package topology and service wiring live in [System Architecture](system-architecture.md). Guard semantics, credential mediation and container isolation live in [Security Architecture](security-architecture.md). Sessions, locks and the event bus live in [Session & State Architecture](session-state-architecture.md). Task and workflow orchestration on top of turns live in [Task Execution](task-execution-architecture.md) and [Workflow Architecture](workflow-architecture.md).

**Current through**: 0.28.0

---

## 1. Overview

### 1.1 Protocol families

The host spawns each provider binary and talks to it over stdin/stdout. All three protocols are line-delimited JSON; they differ in who initiates what.

| Dimension | Claude Code | Codex | ACP |
|---|---|---|---|
| Wire format | Ad-hoc JSONL (`type` field per line) | JSON-RPC 2.0-like, one message per line | JSON-RPC 2.0 over stdio (`json_rpc_2`) |
| Process | `claude --print --input-format stream-json …`, one long-lived process | `codex app-server`, one long-lived process, one thread per session | Configured binary (for example `goose acp`), one long-lived process, one ACP session per turn |
| Turn start | `user` line on stdin | `turn/start` on a thread | `session/prompt` on a fresh `session/new` |
| Streaming | `stream_event` text deltas, `assistant`/`user` tool blocks, terminal `result` | `item/agentMessage/delta`, `item/started`/`item/completed`, `turn/completed` | `session/update` notifications adapted by `AcpProtocolAdapter` |
| Tool interception | `PreToolUse` hook callback (always), `can_use_tool` (only when native prompts are on) | `requestApproval` server requests, answered after the guard chain | `fs/*` reverse-calls routed through the guard chain; `terminal/*` refused |
| Continuity | Host replays bounded history on a cold process; optional provider-session `--resume` | Host replays history in `previousResponseItems`; optional `thread/resume` | Host injects bounded history into each prompt; resume refused |
| Code | `ClaudeCodeHarness` (`dartclaw_core/lib/src/harness/claude_code_harness*.dart`) | `CodexHarness` (`codex_harness.dart`) | `AcpHarness` (`dartclaw_acp/lib/src/acp_harness.dart`) |

Stdio was chosen over HTTP/WebSocket (needs a listening port, which fights `--network none` containers), gRPC (schema and dependency weight for a single parent/child pair) and shared memory (breaks process isolation). The same transport works for a host process and for `docker exec -i` into a container. The Claude protocol is the published `claude` CLI interface ([headless docs](https://code.claude.com/docs/en/headless)); DartClaw speaks it directly with no SDK layer ([ADR-001](../adrs/001-sdk-integration-and-security-architecture.md) addendum). The multi-provider shape is in [ADR-016](../adrs/016-multi-provider-harness-architecture.md), ACP in [ADR-037](../adrs/037-universal-acp-harness.md).

### 1.2 Components

| Component | Responsibility | Code |
|---|---|---|
| `AgentHarness` | Provider-neutral contract: start, `turn()`, cancel, stop, capability getters, event stream | `dartclaw_core/lib/src/harness/agent_harness.dart` |
| `BaseHarness` | Shared subprocess lifecycle: lifecycle lock, crash backoff, spawn generation, bounded stdout/stderr | `…/harness/base_harness.dart`, `process_lifecycle.dart` |
| `ProtocolAdapter` | Wire translation for one provider: parse lines into `ProtocolMessage`, build requests and approval responses, map tool names to `CanonicalTool` | `…/harness/claude_protocol_adapter.dart`, `codex_protocol_adapter.dart`, `dartclaw_acp/…/acp_protocol_adapter.dart` |
| `HarnessFactory`, `HarnessRegistrar` | Create harnesses by provider id; extension point for providers the runtime does not name (ACP) | `…/harness/harness_factory.dart`, `harness_registrar.dart` |
| `ExecutionCoordinator` | Sole post-governance allocator: lane choice, capacity permits, worker reuse, replacement, quarantine | `dartclaw_runtime/lib/src/execution_coordinator*.dart` |
| `TurnManager` | Facade over the coordinator: reserve, execute, cancel, outcome lookup across runners | `dartclaw_runtime/lib/src/turn_manager.dart` (interface in `dartclaw_core/lib/src/turn/turn_manager.dart`) |
| `TurnRunner` | One harness's turn engine: guards, prompt, event stream, usage, persistence, limits, cancel | `dartclaw_runtime/lib/src/turn_runner*.dart` (interface in `dartclaw_core/lib/src/turn/turn_runner.dart`) |
| `TurnStateStore` | File-backed record of in-flight turns for crash detection | `dartclaw_core/lib/src/storage/turn_state_store.dart` |
| `McpProtocolHandler` | `/mcp` JSON-RPC server exposing DartClaw tools to harnesses | `dartclaw_runtime/lib/src/mcp/` |

[![Harness architecture: host, harness contract, provider processes](diagrams/protocol-harness-architecture.svg)](diagrams/protocol-harness-architecture.svg)

---

## 2. Harness Abstraction

### 2.1 The `AgentHarness` contract

`turn()` takes `sessionId`, `messages`, `systemPrompt`, and optional `agentId`, `mcpServers`, `providerSessionId`, `requestProviderSessionResume`, `directory`, `model`, `effort`, `maxTurns`, `outputSchema`. It returns a `TurnResult` (`stopReason`, `error`, `finalText`, additive `costUsd`, token counters, `tokenUsageComplete`, `providerSessionId`, `structuredOutput`, plus Claude's cumulative usage snapshot). The field set is the union every consumer reads, so a provider that cannot supply a value must still name it. `isError`/`isCancelled` are the only `stopReason` values the runtime interprets (`'error'`, `'cancelled'`).

Events (`Stream<BridgeEvent>`, a broadcast stream that survives process restarts): `DeltaEvent`, `ToolUseEvent`, `ToolResultEvent`, `ToolApprovalWaitEvent`/`ToolApprovalResolvedEvent`, `ProviderProgressBridgeEvent`, `SystemInitEvent`, `CompactionStartingBridgeEvent`, `CompactionCompletedBridgeEvent` (`dartclaw_core/lib/src/bridge/bridge_events.dart`).

Capabilities are getters that default to the safe answer. Callers read them; they never branch on provider identity.

| Getter | Claude | Codex | ACP | Meaning |
|---|---|---|---|---|
| `promptStrategy` | `append` | `append` | `replace` | Where behavior content goes: spawn-time flag or developer instructions (`append`) versus prefixed to the prompt (`replace`) |
| `supportsSessionContinuity` | yes | yes | no | Multi-prompt workflow steps may send follow-up turns on one live session |
| `supportsProviderSessionResume` | yes | only with a durable `CODEX_HOME` | no | See 2.2 |
| `supportsStructuredOutput` | yes | no | no | Typed readback of an enforced schema |
| `supportsOutputSchemaConstraint` | no | yes | no | Reply text constrained to the schema, no typed readback |
| `supportsNoWorkTools` | yes | no | no | Can enforce an explicitly empty work-tool policy |
| `supportsPreCompactHook` | yes | no | no | Compaction signal arrives as a hook, so the host's heuristic flush is suppressed |
| `supportsCachedTokens` | yes | yes | yes | Reports cache token counts |
| `supportsCostReporting` | yes | no | no | Reports cost |

`WorkerState` is `stopped → idle ⇄ busy`, with `crashed` reachable from any running state. Mutating lifecycle operations (`start`, `stop`, restart-for-execution) serialize through `SequentialLock.withLock`, which prevents start/stop races.

### 2.2 Provider-session resume

By default DartClaw owns conversation continuity and replays bounded persisted history (`buildReplaySafeHistory`, `conversation_history.dart`: user/assistant pairs only, synthetic markers and guard-blocked exchanges filtered, oldest pairs dropped to a budget). `providerSessionId` or `requestProviderSessionResume` opts a turn into provider-owned continuity instead. A harness whose `supportsProviderSessionResume` is false refuses either input before provider work (`AgentHarness.requireProviderSessionResumeSupport`). `TurnResult.providerSessionId` is non-null only when the provider state outlives the process. Claude enables session persistence and passes `--resume`. Codex needs a system or DartClaw-dedicated `CODEX_HOME`; container and temporary auth-clean homes are non-durable (`CodexEnvironment.supportsProviderSessionResume`). A missing rollout fails the turn and never falls back to `thread/start`.

### 2.3 Structured output

`outputSchema` is an opaque JSON Schema the harness never judges or repairs. `AgentHarness.requireStructuredOutputSupport` is called at the entry of every `turn()` and throws `UnsupportedHarnessCapabilityException` naming provider and capability for a harness with neither capability, so a schema is never silently dropped. That each concrete harness makes the call is enforced by `dev/fitness/test/structured_output_refusal_test.dart`, not by the type system (`turn()` is not sealed; sealing it behind a `performTurn()` hook would reverse this decision and break every `implements` adopter, so it needs an ADR).

`TurnRunner._harnessOutputSchema` decides what a schema-bearing turn gets from the caller's `outputSchemaWhenSupported` flag. A caller that validates host-side gets the schema forwarded to a constraint-only harness and withheld from one with neither capability. A caller that needs the typed payload is refused at reservation by any harness without readback.

| Harness | Channel |
|---|---|
| Claude | `--json-schema` spawn flag; payload on the terminal `result`'s `structured_output`. Process-level: a changed or dropped schema restarts the process |
| Codex | `outputSchema` on `turn/start`; constrains the final assistant message, nothing typed comes back (codex-cli 0.153.4; [ADR-031](../adrs/031-native-first-structured-outputs.md)) |
| ACP | None: `session/prompt` has no schema field |

Workflow `format: json` steps run on this: the provider enforces where it can, and either way the finalizer envelope is parsed and validated host-side (`SchemaValidator`) with one retry that quotes the parser's defect back to the model. Failure reasons are `missing_provider_session`, `missing_envelope`, `unparsable_envelope`, `malformed_envelope` (`dartclaw_runtime/lib/src/task/workflow_one_shot_runner*.dart`). The step engine around it belongs to [Workflow Architecture](workflow-architecture.md).

### 2.4 Construction: factory, registrars, launch options

`HarnessFactory` registers `claude` and `codex` itself and accepts further providers via `register`/`registerFirstClaim`. `AcpHarnessRegistrar` (`dartclaw_acp`) contributes ACP entries through `DartclawRuntime.build(harnessRegistrars:)`, so the server has no ACP branch. The first registrar to claim a provider id owns its factory, executable, container profile and credential overlay. `HarnessFactoryConfig` is the immutable construction bundle (cwd, executable, environment, guard chain, container manager, provider options, declared tools and writable roots).

`HarnessLaunchOptions` are spawn-time and fixed for a harness's life: `disallowedTools`, `maxTurns`, `model`, `effort`, `appendSystemPrompt`, `mcpServerUrl`, `mcpGatewayToken`. Per-turn `model`/`effort`/`maxTurns`/`directory`/persona/schema/provider-session inputs override them (2.5).

### 2.5 Per-turn changes restart Claude

Claude's inputs are spawn flags, so `ClaudeCodeHarness.turn()` compares desired state with the running process and runs one stop-and-start (`_restartForExecution`) when any of these differ: working directory, model, effort, append-system-prompt, max turns, provider-session id or persistence, output schema, or the logical DartClaw session (the last also resets the conversation, so pooled processes cannot leak one session's conversation into another). `TurnRunner` passes the composed behavior prompt as `systemPrompt` on every turn, so a persona, onboarding prompt, or prompt-scope change also restarts. Each restart kills the process's background subagents, which is why the turn boundary is held open (3.4), and each restart on a session with prior messages re-injects the bounded history replay. Alternating schema-bearing and schema-free turns therefore pays two restarts and two replays per pair.

Codex applies persona, model and effort to its thread and reuses a thread only while its developer instructions are unchanged. ACP prepends the persona to the prompt and ignores model/effort overrides.

---

## 3. Claude Code Protocol

### 3.1 Spawn

`_buildClaudeArgs()` in `claude_code_harness.dart`:

```
claude --print --input-format stream-json --output-format stream-json --verbose --include-partial-messages
       [--no-session-persistence | --resume <provider-session-id>]
       [--permission-mode <mode>] [--permission-prompts none]
       [--dangerously-skip-permissions | --permission-prompt-tool stdio]
       [--setting-sources project] [--add-dir <agent-workspace>]
       --model <model, default opus[1m]> [--effort <level>]
       [--append-system-prompt <prompt>] [--mcp-config <path>] [--settings <json>]
       [--json-schema <json>] [--max-turns <n>] [--disallowedTools <name>...]   # variadic, always last
```

| Flag | Why |
|---|---|
| `--no-session-persistence` | The default: DartClaw owns persistence. Omitted when a turn requests provider-session resume |
| `--setting-sources project` | Emitted only for direct (non-container) spawns when `providers.claude.inherit_user_settings: false`. Default is to inherit user, project and local settings ([ADR-027](../adrs/027-claude-harness-setting-sources-default.md)) |
| `--add-dir` | The configured agent's pinned workspace, so Claude finds its `.claude/skills` independent of the turn's cwd. Omitted for restricted and unconfigured agents |
| `--settings` | Inline JSON from the provider's `sandbox`/`permissions`/`settings` options plus allow rules derived from a workflow step's declared tools (`ClaudeSettingsBuilder`). POSIX permission-pattern syntax; Windows drive roots become `//c/path/**`; UNC roots are omitted because Claude does not support most UNC working directories (operators map a drive letter); POSIX roots keep their bytes, a filename's backslash included |
| `--disallowedTools` | `agent.disallowed_tools` plus the native web tools: on host spawns `WebFetch` whenever the MCP server is mounted and `WebSearch` when a search provider is configured (the guarded MCP versions replace them); in containers both always, since they execute at the provider outside `network:none` ([ADR-052](../adrs/052-native-provider-web-tools-denied-all-container-profiles.md)). Names go through `ToolPolicyCascade.normalizeEntry` and `ClaudeProtocolAdapter.nativeToolNames` (`shell` → `Bash`, `file_edit` → `Edit` + `NotebookEdit`) |
| `--json-schema` | Only when the turn carries an output schema (2.3) |
| `--max-turns` | `agent.max_turns` or a per-turn override. Exceeding it ends the turn with `subtype: error_max_turns`, mapped to an error result |
| `--mcp-config` | Path to an ephemeral config pointing at the internal MCP server (section 8) |

**Permission flags.** Claude's native permission UX assumes a TTY, so DartClaw normally disables it and relies on the `PreToolUse` hook → `GuardChain`, `--disallowedTools` and container isolation. The hook fires regardless of which row applies. The default is decided in `_buildClaudeArgs`/`_startInternal` (`skipNativePermissions: nativePermissionMode == null && profile != restricted`); no code defaults to `dontAsk` or a native allow-list. `providers.claude.options.permissionMode` (or `approval: never`, which maps to `bypassPermissions`) selects:

| Condition | Flags |
|---|---|
| No `permissionMode`, non-`restricted` profile (default) | `--dangerously-skip-permissions`; `can_use_tool` is suppressed |
| No `permissionMode`, `restricted` container profile | `--permission-prompt-tool stdio`; tool requests flow through `can_use_tool` |
| Host `dontAsk` | `--permission-mode dontAsk --permission-prompts none`; subprocess env scrub stays `1`, so the effective native mode is `default` with prompts off. Startup probes `claude --help` for `--permission-prompts` / `"none"` and refuses an older binary |
| Container `dontAsk` | `--permission-mode dontAsk` only; scrub `0` |
| `bypassPermissions` | `--permission-mode bypassPermissions` only; host scrub `0`. Refused under the `restricted` container profile |
| `acceptEdits`, `auto`, `default`, `plan` | `--permission-mode <mode>` + `--permission-prompt-tool stdio` |

**Environment.** Host spawns use `buildProviderSpawnEnvironment` (`dartclaw_runtime/lib/src/runtime/provider_resolution.dart`): sanitize the base environment (credential-shaped names stripped), add `claudeHardeningEnvVars` (`CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1`, `DISABLE_AUTOUPDATER=1`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`), then overlay exactly one credential. The harness then removes `claudeNestingEnvVars` (`CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`) and spawns with `includeParentEnvironment: false`. Container spawns start from a minimal set with scrub `0`, a placeholder `ANTHROPIC_API_KEY` and `CLAUDE_CONFIG_DIR`; the real credential never enters the container (see [Security Architecture](security-architecture.md)).

**Containers.** With a `ContainerManager` the binary runs through `docker exec -i -w <dir> -e K=V <container> claude …` in a pre-created hardened container, so there is no per-turn container start. Placement and isolation are in [Security Architecture](security-architecture.md).

**Startup checks** (`_startInternal`): `claude --version` must succeed; auth is verified (API key, injected `CLAUDE_CODE_OAUTH_TOKEN`, or `claude auth status` reporting `loggedIn`); the process is spawned and `initialize` must be answered within 10 seconds or startup fails.

### 3.2 Wire messages

Dart → claude (stdin):

| `type` | When | Purpose |
|---|---|---|
| `control_request` | Startup; and in answer to claude's requests via `control_response` | `initialize`, `get_settings` |
| `user` | Each turn | The user message |
| `control_response` | Reply to a claude `control_request` | Approval, hook result, MCP result |

claude → Dart (stdout), parsed by `parseJsonlLine` (`claude_protocol.dart`) into the sealed `ClaudeMessage`; malformed JSON and unknown types return `null` and are ignored:

| `type` | Parsed as |
|---|---|
| `system` / `init` | `SystemInit` (session id, tool count, context window). Emitted per turn; the id is stable within a process. The context window feeds `ContextMonitor` |
| `system` / `compact_boundary` | `CompactBoundary` (trigger, pre-compaction tokens) |
| `system` / `background_tasks_changed` | `BackgroundTasksChanged` (3.4) |
| `stream_event` | Only `content_block_delta` with a `text_delta` becomes `StreamTextDelta`. Other lifecycle events are ignored |
| `assistant` | `tool_use` blocks → `ToolUseBlock`. Text blocks are skipped; text comes from deltas to avoid double counting |
| `user` | `tool_result` blocks → `ToolResultBlock`. The CLI reports results on a synthetic `user` message, not on the `assistant` message that requested the tool |
| `control_request` | `can_use_tool`, `hook_callback`, `mcp_message`; any other subtype gets an empty success response |
| `result` | `TerminalResult`: `stop_reason`, `subtype`, `structured_output`, `result` text, `total_cost_usd`, `usage`, `modelUsage` |

Representative exchanges:

```json
// Dart → claude: initialize (hooks only; tool policy, model, effort and turn cap are spawn flags)
{"type":"control_request","request_id":"req_init_1710234567890",
 "request":{"subtype":"initialize","hooks":{
   "PreToolUse":[{"hookCallbackIds":["hook_pre_tool"],"timeout":30}],
   "PostToolUse":[{"matcher":null,"hookCallbackIds":["hook_post_tool"],"timeout":10}],
   "PermissionDenied":[{"matcher":null,"hookCallbackIds":["hook_permission_denied"],"timeout":10}],
   "PreCompact":[{"matcher":null,"hookCallbackIds":["hook_pre_compact"],"timeout":10}]}}}

// Dart → claude: a turn. History, when replayed, is prefixed into "content".
{"type":"user","message":{"role":"user","content":"What is 2+2?"}}

// claude → Dart: PreToolUse hook callback, and the deny response
{"type":"control_request","request_id":"req_55_abc","request":{"subtype":"hook_callback",
 "callback_id":"hook_pre_tool","input":{"hook_event_name":"PreToolUse","tool_name":"Bash",
 "tool_input":{"command":"curl http://evil.com"}}}}
{"type":"control_response","response":{"subtype":"success","request_id":"req_55_abc",
 "response":{"continue":true,"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny",
 "permissionDecisionReason":"Network blocked: domain not in allowlist (evil.com)"}}}}

// claude → Dart: end of turn
{"type":"result","stop_reason":"end_turn","total_cost_usd":0.0042,"duration_ms":3500,
 "usage":{"input_tokens":1200,"output_tokens":350}}
```

With images, `content` becomes an array: the text block, then one base64 `{"type":"image","source":{"type":"base64","media_type":…,"data":…}}` block per image of the last message entry (`ClaudeProtocolAdapter.buildTurnRequest(images:)`). That form is the Messages API content-block shape and has not been confirmed against a live CLI. `ClaudeCodeHarness` is an `append` harness, so its `user` lines never carry `system_prompt`.

Hook inputs that are malformed, or name an unknown event, are denied. Hook behavior is in 3.5.

### 3.3 Model catalogue discovery

`ClaudeCodeHarness.discoverModelCatalogue()` starts the process, sends only `initialize` and `get_settings`, and stops it; no turn runs. Rows come from `initialize`'s `response.response.models[]` (`value`, `resolvedModel`, `displayName`, optional `supportedEffortLevels`, `disabled`); the `default` row and disabled rows are dropped. The default is the entry whose `resolvedModel` or `value` equals `get_settings`' `applied.model`. Both surfaces are undocumented CLI output, so a missing field fails discovery as a whole instead of yielding a partial list (`claudeModelCatalogue`). Codex discovery is in 4.5. Both are driven by `ModelCatalogueDiscovery` (`dartclaw_runtime/lib/src/runtime/model_catalogue_discovery.dart`): each executable provider is probed on the host (never in a container) once after the primary lane starts, never blocks a render, and a failure is logged and retried by the first read at least 5 minutes later.

### 3.4 Background tasks at the turn boundary

Claude Code 2.1.x runs the `Agent` tool in the background by default and re-lists its background tasks on every change as `system/background_tasks_changed`. The model's turn ends with an ordinary `result` while those tasks still run; when one reports, the CLI runs a notification turn by itself (a new `system/init`, the model's reaction, a second `result` with `origin.kind: "task-notification"`) with no stdin input.

`ClaudeCodeHarness` keeps the last inventory and tracks non-`local_bash` tasks that left it before their notification turn started. A successful `result` does not complete the caller's turn while any such task is listed or owed: the harness logs `Turn boundary held`, emits `ProviderProgressBridgeEvent(kind: background_tasks)` so the stall monitor sees activity, and sums only root-session `usage` across held results. The final `result` supplies one cumulative `modelUsage`/cost snapshot for the whole turn. An error `result` completes the turn at once. A backgrounded shell command never holds the turn: the CLI's own `--print` policy kills it shortly after the final result, and a step that left a dev server running must still end. The turn timeout bounds the wait. Without the hold, the next turn's restart (a finalizer's `--json-schema`, a session switch) would kill every running subagent. The CLI offers no flag, setting or env var that makes `Agent` foreground by default (checked on 2.1.263; the notification race was observed on 2.1.284), so the boundary is made safe host-side.

### 3.5 Tool approval chain

Every Claude tool call passes up to two stages.

[![Tool interception per provider](diagrams/protocol-tool-interception.svg)](diagrams/protocol-tool-interception.svg)

**Stage 1, `can_use_tool`**, only when `--permission-prompt-tool stdio` is in effect (table in 3.1). When permissions are skipped the harness treats a `can_use_tool` request as impossible, logs a warning and denies. When the prompt tool is active, a turn flagged `allowOperatorApproval` (a human `web` turn on a user or main session) emits `ToolApprovalWaitEvent(operatorActionable: true, expiresAt: +5 min)` and waits for `resolveToolApproval` or expiry (decline); any other turn gets `ToolApprovalPolicy.allowAll`, which is the only policy that exists.

**Stage 2, `PreToolUse` hook** (always fires, even with `--dangerously-skip-permissions`):

```
hook_callback(PreToolUse)
  → map tool name: ClaudeProtocolAdapter.mapToolName → CanonicalTool.stableName, else "claude:<name>"
  → GuardChain.evaluateBeforeToolCall(...)      block → deny with the verdict message as permissionDecisionReason;
                                                an exception → deny (fail closed)
  → tool_input.env carries ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN → strip and answer with updatedInput
  → otherwise allow
```

Claude may first call the provider-native `ToolSearch` to load a deferred tool's schema. Under a non-empty closed allowlist DartClaw permits that metadata-only call after deny checks and evaluates the selected tool call against the same policy. An explicit deny, or a toolless policy, still blocks it. Likewise `Skill` stays available under a non-empty workflow tool policy so trusted skill instructions load; skill activation can run trusted plugin hooks and shell preprocessing, so the allowlist is not a sandbox for that native code. Empty policies and the knowledge-inbox no-tools sentinel deny both. For a turn with an active provider-enforced schema, `TurnRunner` adds a session-local `TaskToolFilterGuard` exception for raw `StructuredOutput` and canonical `claude:StructuredOutput`, cleared after the turn.

**Observer hooks.** `PostToolUse` is audit-only and always allows (`GuardAuditLogger.logPostToolUse`); it fires after the result is already in the model's context, which is why `web_fetch` is an MCP tool whose content scan runs before the model sees the text ([ADR-009](../adrs/009-internal-mcp-server.md)). `PermissionDenied` reports Claude's own refusals as `ToolPermissionDeniedEvent`; DartClaw cannot override them. `PreCompact` is a bounded capture boundary: `HarnessWiring._capturePreCompactObservation` stores a redacted, byte-capped tail of the persisted messages as an `observation` memory entry with host-bound provenance, then the harness answers `allow` exactly once and a `CompactionStartingEvent` fires. A capture failure is logged and compaction proceeds. Because the signal is deterministic, the host's heuristic pre-compaction flush is suppressed (`supportsPreCompactHook`).

Guard verdict semantics, audit records and the guard timeout (5 seconds per guard by default) are in [Security Architecture](security-architecture.md).

### 3.6 SDK MCP fallback

Without a configured MCP server URL (SDK composition with no `serve`) and outside containers, the four memory tools (`memory_apply`, `memory_observe`, `memory_search`, `memory_read`) are registered in `initialize` as `sdkMcpServers`. The CLI proxies calls as `control_request` `subtype: mcp_message` carrying a `tools/call` JSON-RPC message, and the harness answers with a `control_response` whose `response.mcp_response` is the JSON-RPC result or error. This is a Claude-SDK-private extension, not the MCP spec. The HTTP server in section 8 supersedes it ([ADR-009](../adrs/009-internal-mcp-server.md)).

---

## 4. Codex Protocol

`CodexHarness` drives `codex app-server`, a long-lived process speaking JSON-RPC 2.0-like messages as JSONL. `CodexProtocolAdapter` does all wire translation and also accepts the older `ClientResponse` envelope shapes. DartClaw never uses `--yolo`; the configured approval policy decides which operations reach the host. Protocol research: private repo `docs/research/codex-cli-harness/research.md`.

### 4.1 Spawn and handshake

```
codex app-server -c tools.experimental_request_user_input.enabled=false
```

The `request_user_input` override applies to host and container launches and restarts; a CLI that rejects it fails startup and DartClaw does not retry without it. The spawn carries no sandbox: the effective sandbox (`providers.codex.sandbox`, or `danger-full-access` for every containerized spawn because the container is the boundary) travels as `thread/start.sandbox` and `turn/start.sandboxPolicy`, and nothing is sent when it is unset. A `thread/start.sandbox` replaces the Codex permission profile the loaded config selects (`default_permissions`), read denies included (verified codex-cli 0.162.1), so an unset `sandbox` is what keeps an operator's profile in force.

Startup order: environment prepare (`CodexEnvironment`: system, DartClaw-dedicated, or container auth-clean `CODEX_HOME`) → spawn → `initialize`, answer within 10 seconds, then `initialized` → for a configured agent workspace, `skills/extraRoots/set {"extraRoots":["<workspace>/.agents/skills"]}`, awaited, so an unsupported provider version or unmapped container path fails the worker rather than silently dropping the skills → worker is `idle`. Threads open lazily: `thread/start` (with developer instructions, sandbox, approval policy), or `thread/resume {"threadId"}` for an explicit durable session. The thread id is cached per DartClaw session.

### 4.2 Turn

Each turn is a `turn/start` on the thread with:

- `input`: one `text` item, then one `{"type":"image","url":"data:<media_type>;base64,<data>"}` item per image of the last message entry (a data URL, so no file must be visible to the app server; unconfirmed against a live CLI, with `localImage` as the fallback shape);
- `previousResponseItems`: the earlier messages as `message` items, so ordinary continuity stays host-owned;
- per-turn settings from `CodexSettings.buildDynamicSettings`: `model`, `effort`, `cwd`, `sandboxPolicy` (`workspaceWrite` carries `writableRoots`), `approvalPolicy`;
- `outputSchema` when the turn has one.

| Config (`providers.codex.options`) | Sent as |
|---|---|
| `approval: on-request` | `approvalPolicy: "on-request"`. The broadest interception for the guard chain |
| `approval: unless-allow-listed` | `"granular"`. Safe-listed commands emit no approval request |
| `approval: never` | `"never"`. No approval requests |
| `sandbox: read-only` / `workspace-write` / `danger-full-access` | `readOnly` / `workspaceWrite` / `dangerFullAccess` |

An absent or blank `approval` omits the field and Codex inherits its own. Serve logs a warning whenever tool-restricted agents or jobs exist while a Codex provider's `approval` is anything but `on-request` (`HarnessWiring`), because the guard chain only sees operations for which the app server emits an approval request.

Every new thread gets developer instructions stating that DartClaw cannot answer native mid-turn questions and that clarification belongs in the final reply. An explicit `thread/resume` keeps the instructions saved at creation. The harness correlates notifications with the active thread and, after `turn/started`, the active turn; agent messages and terminal notifications from background subagent threads or an earlier turn cannot emit response text or settle the parent turn (`_isUnrelatedTurnNotification`). Child tool items and child approval requests are not filtered: they still reach the event stream and the guard chain. `thread/tokenUsage/updated` is the exception: usage reported while the turn runs is the turn's.

### 4.3 Notifications

| Codex message | Handling |
|---|---|
| `item/agentMessage/delta` | `DeltaEvent`. Carries an `itemId`; a turn with several agent messages interleaves deltas, so accumulated deltas are a display artifact, not the answer. A completed agent message with no preceding delta is emitted as one delta |
| `item/started` (tool item: `commandExecution`, `fileChange`, `mcpToolCall`, `webSearch`) | `ToolUseEvent` |
| `item/started` / `item/completed` (`contextCompaction`) | `CompactionStartingBridgeEvent` / `CompactionCompletedBridgeEvent` |
| `item/completed` (tool item) | `ToolResultEvent` |
| `thread/tokenUsage/updated` | `tokenUsage.last` is the turn's usage; `inputTokens` includes `cachedInputTokens` and is normalized to fresh input on arrival. Held until the `turn/completed` it precedes |
| `turn/completed` | Completes the turn. Carries no usage (codex-cli 0.146.0). The response is read from `turn.items` (`phase: final_answer` agent messages), not from the deltas |
| `turn/failed` | Completes the turn with an error `stopReason`; token counts stay zero |
| `configWarning`, `mcpServer/startupStatus/updated` | Progress/diagnostic events |

Unhandled methods are logged, never silent. An agent message or `turn/completed` item carrying structured `questions` yields one WARNING per question (thread, turn and item ids, titles, options, "no answer supplied") and nothing else: no synthetic answer or completion enters the response.

### 4.4 Approvals

Codex asks the host with server requests. The adapter routes them by method:

| Request | Handling |
|---|---|
| `item/commandExecution/requestApproval` | Guard chain, then `{decision: accept \| decline \| cancel}`. Fails closed when the command is missing, `accept` is unavailable, or extra filesystem, network or environment authority is present. A rejection uses `decline` when offered, else `cancel`; if neither is safe, a terminal invalid-params error. Proposed policy amendments never widen a one-shot `accept` |
| `item/fileChange/requestApproval` | Every operation in the batch is evaluated (`add`/`create` → `file_write`, `modify`/`update` → `file_edit`); deletes, moves and session-root grants are declined |
| `mcpServer/elicitation/request` with `_meta.codex_approval_kind: mcp_tool_call` | Approval keyed on the request's server, tool and arguments |
| `item/permissions/requestApproval` | Empty permission grant |
| Other elicitations, `item/tool/requestUserInput` (also logged), unknown methods | Terminal JSON-RPC `-32601` or a decline, so the turn is never held |

The legacy `control/approval` and `approval/request` shapes are still accepted. Before guard evaluation the input is normalized: `OPENAI_API_KEY` and `CODEX_API_KEY` are stripped from `env`, relative shell paths resolve against the provider-supplied cwd, and tool names map to canonical names (`codex:<name>` when unmapped). There is no hook system: the approval round-trip is the only interception point. Like Claude's stage 1, an operator-actionable web turn on `approval: on-request` waits up to 5 minutes for the operator after the guard chain allows; otherwise the harness replies allow. A missing or unrecognized reply can hold the turn until the turn timeout, so every unsupported or failed evaluation gets a terminal fail-closed response.

### 4.5 Model catalogue discovery

`CodexHarness.discoverModelCatalogue()` handshakes, pages `model/list` (`{cursor}` → `{data, nextCursor}`, bounded at 50 pages) and sends one `thread/start` with `ephemeral: true` plus the configured model; the result names the model a turn would run, which resolves the default among non-hidden entries (`isDefault` marks the catalogue default, not this deployment's). No `turn/start` is sent and the process is stopped. A dedicated subscription home is used as prepared and the probe writes neither `config.toml` nor `AGENTS.md`, because running workers share the home. A missing or mistyped field fails discovery as a whole.

---

## 5. ACP

`AcpHarness`, `AcpClient` (JSON-RPC peer on `json_rpc_2`), config parsing, validation and the registrar live in `dartclaw_acp`. The harness does not extend `BaseHarness`; `ndjsonChannel` (`dartclaw_acp/lib/src/ndjson_channel.dart`) is its line transport and routes undecodable stdout to `onStreamError` so a provider fault ends the turn.

- Every turn creates an ACP session (`session/new`), injects bounded history ahead of the current message, prompts, and closes the session. Cancel sends `session/cancel`, completes the turn as `cancelled`, then stops the process. A process exit fails the active turn and leaves the worker `crashed`; there is no in-place backoff restart, so the coordinator's reuse check (state must be `idle`) discards it.
- No continuity, resume, structured output, cost, tool-approval events, or model/effort overrides (`EffectiveContextCapabilities.unavailable`).
- Reverse-calls are registered only for host execution and bound to the active host session and effective workspace directory; calls outside an active turn are rejected.

| ACP method | Canonical tool | Handling |
|---|---|---|
| `fs/read_text_file` | `file_read` | `GuardChain.evaluateBeforeToolCall` with `rawProviderToolName` set |
| `fs/write_text_file` | `file_write` | same |
| `session/request_permission` | the request's `operation` (or `tool`) | Same call with `rawProviderToolName: session/request_permission`; answers `granted`, and an evaluation error denies |
| `terminal/*` | none | Refused: DartClaw cannot yet prove containment of the whole spawned process tree |

**Guard mediation and containers.** Only `topology: direct` agents that advertise and honor host `fs` capabilities can be guard-mediated. A guarded Goose registration is refused at startup (its profile needs the `terminal` reverse-call, which DartClaw does not advertise); Vibe, which needs only `fs`, is the guard-mediatable verified target. Known relay selectors such as `claude-acp`, `codex-acp` are rejected; `requires_guard_mediation: true` requires `topology: direct`, `verification` and `model_provider`. Relay and unverified agents (the default when `topology` is omitted) claim no mediation, so a container would be their only boundary, and DartClaw mediates no provider credential or host capability for an ACP client inside a container. They are therefore unavailable: config validation requires them to declare `container_isolation_required: true`, and `acpContainerRequirementError` then fails startup for any registration that requires a container boundary. In effect only a `direct` registration with `container_isolation_required: false` starts, and only on host execution. Compatibility comes from `ProviderExecutionSupport.acp` intersected with the resolved execution policy; no launch path substitutes host execution for a rejected container policy.

---

## 6. Turn Lifecycle

### 6.1 Entry points

| Entry | Path |
|---|---|
| Web chat | `POST /api/sessions/<id>/send` → `ConversationService.submit` (durable submission claim) → `_dispatch` → `TurnManager.reserveContextTurn` → `executeTurn`. The response carries an `sseUrl`; `GET /api/sessions/<id>/stream?turn=<id>` relays deltas and tool indicators and ends with `done`/`turn_error`/`turn_cancelled`, replaying the terminal frame when the turn already settled. When provider capacity is unavailable (`BusyTurnException`) the submission is queued and re-dispatched when capacity frees |
| Channels, cron, knowledge inbox | `TurnManager.startTurn` or `reserveTurn` + `executeTurn` |
| Logical agents (`sessions_spawn`/`sessions_send`) | `reserveTurn` with `workerPolicy`, then `waitForOutcome`; no timeout and no cancellation link to the caller's turn |
| Tasks and workflow steps | `ExecutionCoordinator.acquire` directly, then `TurnRunner.reserveAdmittedTurn` / `executeTurn` on the leased runner. A workflow step holds one worker lease for its whole bounded prompt chain (main prompt, follow-ups, finalizer envelope, retry); the task row, workflow state, transcript, budgets and cancellation stay host-owned, and there is no separate provider-CLI execution stack |

Submission claims and conversation state are in [Session & State Architecture](session-state-architecture.md); channel routing is in [Channel Messaging](channel-messaging-architecture.md).

### 6.2 Execution allocation

Global turn governance runs before allocation, with one exception: a fail-fast task or workflow request takes its lane permit without waiting first and skips governance when none is free, so a request the lane cannot run records no loop or rate-limit state. After admission `ExecutionCoordinator` is the sole authority for lane, queue or fail-fast behavior, per-provider capacity permits, reusable-worker lookup, creation, replacement, quarantine and release. Callers never inspect provider identity; provider-specific behavior lives in adapters and composition (`HarnessWiring`).

| Lane | Surfaces | Capacity |
|---|---|---|
| Primary | Channel turns (unless the session is bound to a logical agent). Interactive turns when the request's provider and execution policy equal the primary runner's, else the worker lane | Fixed 1, serialized, outside `pool_size` |
| Worker | Cron/scheduler, tasks, workflow steps, logical agents, temporary conversations | `providers.<id>.pool_size` per provider |

Capacity is a ceiling on concurrent executions, not a process count: idle cached harnesses hold no permit, and container count or lifetime does not change the limit. Interactive, channel, scheduler and temporary requests wait for a permit (`ExecutionAdmission.wait`). Tasks and workflow steps acquire fail-fast: `TaskExecutor`'s poll loop gets `null` or `BusyTurnException` and retries on its next pass, so they never block inside `acquire`. Logical-agent requests also fail fast, so a child never waits on a slot its caller holds. `acquire` returns an idempotent `ExecutionLease`, released exactly once on every success, failure, cancellation or setup-error path. The set of active leases drives runtime busy/free observability.

[![Execution lanes: from request to lease and back](diagrams/protocol-execution-lanes.svg)](diagrams/protocol-execution-lanes.svg)

Reusable-worker lookup (`_takeCached`) matches normalized provider id and the complete effective execution policy, in this order: a healthy exact-session worker (container workers also need the exact logical-agent principal); otherwise any healthy host worker with the same provider, policy, agent and workspace; otherwise a fresh worker from provider wiring. A host worker and a container worker are never interchangeable, nor are container workers from different profiles. A workflow-surface request, or any request carrying `allowedTools`, an artifacts directory or spawn environment, bypasses the cache and gets a single-use worker (its tool grants, mounts and environment are fixed at construction). The cache is opportunistic with no size, TTL or prewarm configuration; idle excess is scavenged oldest first.

Release: an idle healthy host worker returns to the cache. A container worker is retained only for its logical-agent owner or a temporary session; task and workflow containers are disposed at release. Teardown runs in order: harness termination, container authority revocation, container destruction. Replacement requires confirmed termination of the harness's managed root process and a completed revocation and destruction. If either cannot be confirmed, the worker is dropped from the cache and its permit is quarantined: effective provider capacity falls and no overlapping replacement starts ([ADR-058](../adrs/058-report-quarantined-workers-truthfully.md)). An SDK composition with a single harness (no provider capacities) may serialize background tasks on it, only when the request's provider and policy already match; a mismatch fails closed. `ExecutionCoordinator.dispose` shuts down in order: close every gate to new admission, wait for active leases to drain, tear down cached workers, then stop the primary harness. Container ownership, naming, health monitoring and authority lifetime are in [Security Architecture](security-architecture.md); the task side of the same lane model, including the `securityProfile` declaration, is in [Task Execution](task-execution-architecture.md).

### 6.3 Reserve, execute, settle

[![Turn lifecycle: reserve, execute, settle](diagrams/protocol-turn-lifecycle.svg)](diagrams/protocol-turn-lifecycle.svg)

Details the figure cannot carry:

- Step 3 order matters: the read-only budget check comes first, then the session lock (a wait warns after 30 s and is reported stuck after 120 s), then the two checks that record state (loop, rate window), so a request the global cap rejects counts nothing and releases the lock. The coordinator calls `admitTurn` on the primary runner from inside `acquire`; a fail-fast task or workflow request takes its permit first (6.2).
- Step 5 allows one active turn per runner. Provider processes carry no turn identity on a `DeltaEvent`, so two concurrent turns on one worker would corrupt both; admission locks per session, so this is the backstop, and parallel workflow steps on distinct sessions each lease their own worker.
- Step 8 opens `session_cost:<id>` accounting before dispatch and fails the turn with `AccountingPersistenceException` if that write fails. Step 9's harness timeout is the turn budget + 60 s, a crash backstop behind `TurnRunner`'s own timer.
- Step 10 persists usage before the post-turn guard runs. The guard (11) evaluates the unredacted reply and a block stores `[Response blocked by guard: ...]`; redaction applies when the reply is persisted (12).
- Step 12 is also where a failed or cancelled turn lands: a guard block, provider error, timeout or cancel jumps there, the partial buffer is stored redacted (or `[Turn cancelled]` / `[Turn failed]`), and steps 13 to 15 always run.

`reserveTurn` and `executeTurn` are split so a caller can persist the user message between them; `releaseTurn` rolls a reservation back. `waitForOutcome(sessionId, turnId)` returns the `TurnOutcome`, from the retention cache when the turn already settled. The outcome carries status (`completed`, `failed`, `cancelled`), `responseText`, `structuredOutput`, `providerSessionId`, token counters and `tokenUsageComplete`, `turnDuration`, `toolCalls`, `limitBreach`, `loopDetection`. The coordinator forwards it to `RunnerObserver`; `TurnTraceService` and `TaskEventRecorder` consume the same normalized fields ([Task Execution](task-execution-architecture.md)).

Failure paths: an exception in steps 6–12 stores the partial buffer redacted (or `[Turn cancelled]` / `[Turn failed]`) as the assistant message and a failed or cancelled outcome. A provider error result is stored as the redacted error text. A turn whose accounting cannot be persisted before dispatch fails with `AccountingPersistenceException` rather than running unaccounted.

Runner state: `_activeTurns` (sessionId → `TurnContext`), `_cancelledTurns`, `_recentOutcomes` (TTL 30 s), `_outcomePending` completers, `_executionSettledPending`, `executionPolicy` and `providerId` (the runner's reuse identity). The runner is also the enforcement site for tool filters and read-only mode through `TaskToolFilterGuard` and for the loop, budget and rate-limit governance shared across runners.

### 6.4 Tool calls, usage and outcome fields

`TurnToolHookCallbackHandler` correlates `ToolUseEvent` and `ToolResultEvent` by tool id into `ToolCallRecord` (id, canonical name, `success`, `durationMs`, `errorType` of `tool_error` or `incomplete`, redacted `context`/`arguments`/`result` with an `isTruncated` flag, memory `sourceLocators`). At most 64 records are retained, the first 63 plus the latest; counters keep the true totals. A call with no result at turn end is finalized `success: false, errorType: incomplete`. The same handler feeds loop detection (`recordToolCall`) and the progress stream.

**Usage normalization.** Providers report cache tokens under different names; the adapter maps them to `cacheReadTokens`/`cacheWriteTokens` (Claude `cache_read_input_tokens`/`cache_creation_input_tokens`; Codex `cached_input_tokens` as read, write 0; ACP as reported).

Claude's `result.usage` covers only the root conversation, while delegated models bill separately. The harness therefore returns the cumulative per-model snapshot (`modelUsage`, `total_cost_usd`, native `session_id`) beside root usage, with `costUsd` null and `tokenUsageComplete` false. `TurnRunner._normalizeTurnUsage` subtracts the baseline stored with the session to get the turn's increment: root 88 output tokens beside 721 across models charges 721; cumulative 41 then 81 output tokens charges 40 on the second turn. Baseline, ledger and `last_accounted_turn_id` are written atomically in `session_cost:<id>` (KV) at settlement, after `pending_accounting_turn_id` was written before dispatch. A missing baseline, an uncleared pending marker, a different native session, or decreasing counters yields only root `usage` as a lower bound with null cost and sticky `token_usage_complete: false`. Cost availability is independent of token completeness (`estimated_cost_usd` sums known increments; `cost_reported_turn_count` counts them). `total_tokens` is input plus output. Context-window monitoring uses root-session input, not the cross-model sum. Codex reports no cost; ledger and usage-tracker mechanics are in [Observability & Operations](observability-operations-architecture.md).

### 6.5 Liveness, limits and cancellation

Two budgets come from `governance.turn_limits` (`TurnLimitsConfig`): `stall_timeout` (default 5 min) and `turn_timeout` (default 30 min); zero disables either. A step or request can override the wall-clock budget (`TurnContext.turnTimeout`). The stall budget is ignored when the turn budget is not larger.

`TurnLivenessTracker` resets the stall timer on forward progress: text deltas, tool use and results, provider progress events (including background-task holds), and `SystemInitEvent`. Progress also calls `SessionResetService.touchActivity`, so long turns keep the session alive by activity rather than age. While a tool approval is pending, stall accounting is suspended. The wall-clock timer never resets. `stall_action` is `warn` (log and SSE `turn_progress_stall`), `cancel` (default; same event, then cancels) or `ignore` (log only). Wait state (`running`, `waiting`, `stuck`, `cancelling`, terminal) is published as `TurnWaitStateChangedEvent` with reason `session_lock`, `provider_turn`, `tool_approval` or `unknown`.

**Cancellation.** The JSONL protocol has no cancel message. `TurnManager.cancelTurnById(sessionId, turnId, reason)` (`operator_cancel`, `admin_cancel`, `automation_cancel`) answers `TURN_NOT_FOUND` (404) for an unknown turn and `TURN_NOT_CANCELLABLE` (409) once the provider has returned. Called with the API's default check it also refuses a turn that is still plainly `running`, or waiting on a tool approval and not yet stuck (`canCancel`); `cancelTurn(sessionId)` and the automatic stall, timeout and loop cancels skip that check. An accepted cancel settles immediately: the outcome is `cancelled` (with `limitBreach` when a budget caused it), the session lock is released and the turn-state record deleted. Worker recovery then runs in the background (`_worker.cancel()`, `stop()`, `start()`), and the session's next dispatch waits for it (`_awaitAcceptedCancelRecovery`). A failed recovery marks the runner non-reusable. Loop-detection abort and the budget timers use the same path.

Process termination: `cancel()` closes stdin and requests termination; the serialized stop path passes that result to `killWithEscalation` (`initialTerminationAccepted`), which on POSIX hosts sends SIGTERM and SIGKILL after the grace period (2 s default). Platforms without POSIX signals hard-terminate the directly managed root handle and never attempt signal escalation or a bare-PID tree kill. Owners release ownership only after root exit is observed. Provider-created helpers are not owned, and arbitrary descendant containment is a separate capability, which is why ACP `terminal/*` stays refused. Workflow Bash steps track observed descendants and inherited output handles; detached or daemonized processes that escape are unsupported there.

### 6.6 System prompt composition

`TurnRunner._buildSystemPrompt` (`turn_runner_execution.dart`) picks the prompt for each turn; `BehaviorFileService` (`dartclaw_runtime/lib/src/behavior/behavior_file_service.dart`) composes it from workspace files.

- A non-empty per-turn `systemPromptOverride` (logical-agent persona, onboarding prompt) wins outright.
- Otherwise the service is the turn's `behaviorOverride` (task or project-scoped) or the shared one, and the turn's `PromptScope` selects the content. A null scope is treated as `restricted` (fail closed).

| Scope | Content |
|---|---|
| `primary` | `SOUL.md`, `USER.md`, channel origin, `TOOLS.md`, memory-audience guidance, recent errors, `AGENTS.md`, the bounded memory index projection, and for `replace` harnesses the compact-instructions block; onboarding only for human input |
| `task` | `SOUL.md` (or the agent's soul override), agent `USER.md` when the workspace is agent-scoped, origin, `TOOLS.md`, `AGENTS.md`, a memory-retrieval hint instead of memory |
| `restricted` | `TOOLS.md` only (or the soul override), plus a memory hint; falls back to a one-line default prompt |

The memory block is `promptMemoryProjection()`: the canonical `MEMORY.md` index read through `MemoryCorpusService.snapshot`, validated against the collection revision and capped at 32 KiB and 150 lines by default; an unavailable, over-budget or invalid index renders a degraded notice instead. Errors and memory are omitted when personal memory is disabled. Project `SOUL.md` is no longer read (the provider reads `CLAUDE.md`/`AGENTS.md` itself).

How the text reaches the provider depends on `promptStrategy`. For `append` harnesses `composeStaticPrompt` is used and `AGENTS.md` is part of it: Claude receives it as `--append-system-prompt` (so a change restarts the process, 2.5); Codex uses it as the thread's `developerInstructions` plus the no-mid-turn-question guidance (4.2). For `replace` harnesses (ACP) `composeSystemPrompt` plus the `AGENTS.md` append text is prefixed to the prompt. The files read are recorded as `BehaviorPromptProvenance` for context telemetry.

---

## 7. Crash Recovery and Errors

[![Worker crash recovery: WorkerState and what a restart restores](diagrams/protocol-crash-recovery.svg)](diagrams/protocol-crash-recovery.svg)

| Layer | Mechanism |
|---|---|
| Process exit | `BaseHarness` exit watcher (guarded by `_spawnGeneration`, so a stale handler cannot affect a newer process): state `crashed`, `crashCount++`, pending turn completed with the error (or the recorded stream fault). The next `turn()` calls `recoverFromCrash`: delay `baseBackoff × 2^(crashCount-1)` (5, 10, 20, 40, 80 s with the defaults), restart, and throw `StateError('Harness unavailable: max retries exceeded')` once `crashCount > maxRetries` (5). A completed turn resets the counter. Claude re-injects bounded history on the cold process; Codex clears cached thread ids, repeats the handshake, opens a new thread and replays history in `previousResponseItems` (an explicit durable session uses `thread/resume`). ACP has no in-place restart |
| Unconfirmed exit | Neither an in-place restart nor a coordinator replacement may start while the managed root's exit is unconfirmed; the coordinator quarantines the permit (6.2) |
| Output floods | `BaseHarness` bounds each of stdout and stderr: 16 MiB held in an unterminated line and 16 MiB admitted per turn. A breach, or undecodable bytes, is a stream fault: the process is torn down and the turn fails with a `ProcessOutputLimitException`/`ProcessStreamException` message |
| Turn in flight at host crash | `TurnStateStore` (`turn_state.json` in the data dir, or the standalone dir) records `turnId` and `startedAt` per session at reservation, synchronously through `secureWriteFileSync`, and deletes it on settlement or cancel. On serving startup, storage wiring scans before the active-store gate and warns once per orphan without deleting; after `wire()`, `detectAndCleanOrphanedTurns()` removes the records, remembers the session ids and `consumeRecoveryNotice(sessionId)` returns `true` once per session so the web UI shows a recovery banner. Opening the store clears temp siblings and quarantines malformed content; failing to open it exits the process. Headless workflows do not scan or acknowledge serving orphans |
| Messages | Sessions store messages as NDJSON with line-number cursors, so a client resumes from "after cursor X" ([Session & State Architecture](session-state-architecture.md)) |
| Failed task | The worktree is preserved for inspection; cleanup happens on accept, reject or cancel ([Task Execution](task-execution-architecture.md)) |

[![Host crash: the turn_state.json record from reserve to recovery notice](diagrams/protocol-orphaned-turns.svg)](diagrams/protocol-orphaned-turns.svg)

Protocol and turn errors:

| Error | Detection | Result |
|---|---|---|
| Malformed line, unknown type | `parseJsonlLine` / adapter returns `null` | Logged or ignored |
| Unknown `control_request` subtype (Claude) | `_handleControlRequest` default | Empty success response |
| Initialize timeout (10 s) | `Future.timeout` | Startup fails, process stopped |
| Harness not idle | State check at turn start | `StateError` to the caller |
| Turn exceeds budget | `TurnRunner` timer; harness backstop at budget + 60 s | Cancelled outcome with `limitBreach`; harness backstop stops the process (`busy → stopped`) and throws `TimeoutException` |
| Unsupported capability | `requireStructuredOutputSupport` / `requireProviderSessionResumeSupport` | `UnsupportedHarnessCapabilityException`, failed outcome with its message |
| Guard block | Pre- or post-turn | Synthetic assistant message, failed outcome |

---

## 8. MCP Integration

DartClaw exposes tools to harnesses through the internal MCP server, `McpProtocolHandler` behind `mcpRoute` (`dartclaw_runtime/lib/src/mcp/mcp_router.dart`). It is `POST /mcp`, Streamable HTTP, JSON-RPC 2.0, protocol version 2025-03-26 (`GET` is 405). Request bodies are read with a bounded stream and rejected with 413 above 1 MiB. `DartclawServer` mounts it when a gateway token exists or when auth is disabled and the host is loopback; an authentication-disabled non-loopback deployment does not mount it. The Claude harness writes an ephemeral `--mcp-config` file pointing at it (created empty, `chmod 600` before the token is written, in the system temp directory for host spawns, deleted before every start and on every teardown including failed shutdowns); the Codex harness writes an `[mcp_servers.dartclaw]` table into its generated `config.toml` (`CodexConfigGenerator`), with the bearer supplied through an environment variable.

```json
{"mcpServers":{"dartclaw":{"type":"http","url":"http://localhost:3333/mcp",
                           "headers":{"Authorization":"Bearer <token>"}}}}
```

**Callers.** `/mcp` authenticates its own callers (constant-time comparison; failures feed the shared auth rate limiter):

| Bearer | Reaches | Principal |
|---|---|---|
| Gateway token | The full tool set | The deployment (`system`) |
| Host-minted harness bearer (`HarnessMcpBearers`, one per host harness, valid while the harness lives) | The full tool set, with the harness's active turn attached as `TurnProvenance` for tools that read it | The turn |
| Configured named client (`gateway.mcp_clients`, requires `auth_mode: token`) | Only `context_research`, `kg_query`, `kg_timeline` (`contextEngineProfileTools`), shared knowledge scope only; refusals are audited | `mcp-client:<name>` |
| None | Only on an authentication-disabled loopback deployment, which also requires an exact loopback `Host` and, when sent, a loopback `Origin` | Deployment |

Container harnesses reach the server only through their own authority's host bridge (`ContainerManager.mcpBridgeUrl`), identified by the pipe rather than a bearer, and a null bridge URL means no MCP server is configured at all. The request body is capped at 1 MiB (413).

**Dispatch.** Every registered tool is guarded and audited once at the dispatch seam (`McpDispatchGuard` through the `GuardChain`, mapped to canonical tools via `toolCanonicals`), so a tool carries no guard plumbing. `McpTool` requires `name`, `description`, `inputSchema`, `access` (`read` or `write`, undefaulted so a new tool must answer) and `call`; `ContextualMcpTool` and `TurnAwareMcpTool` additionally receive the caller context. Guard semantics: [Security Architecture](security-architecture.md#guard-pipeline).

**Registered tools** (`runtime/service_wiring_mcp_tools.dart`; semantic tools from `HarnessWiring.semanticMcpTools`):

| Group | Tools | Registration |
|---|---|---|
| Memory | `memory_apply`, `memory_observe`, `memory_search`, `memory_read` | When personal memory is composed |
| Knowledge graph and research | `kg_add`, `kg_query`, `kg_timeline`, `kg_invalidate`, `kg_contradictions`, `context_research`, `wiki_write` | Always; writes pass the knowledge write gate (admin rule, audit, no durable writes from temporary conversations) |
| Web | `web_fetch` (SSRF-hardened, content-scanned) | Always |
| Search | `brave_search`, `tavily_search` | When the provider is enabled with an API key |
| Sessions | `sessions_spawn`, `sessions_send` | Always |
| Tasks | `task_create`, `task_review`, `task_list`, `review_list`, `task_bind`, `task_unbind` | Always; binding tools report an absent store at call time |
| Workflows and schedules | `workflow_run`, `workflow_list`, `workflow_resume`, `workflow_cancel`, `workflow_request_changes`, `workflow_status`, `schedule_upsert`, `schedule_list`, `attach_media` | Always |
| Onboarding | `onboarding_complete` | Only while `ONBOARDING.md` exists at startup |
| Outbound MCP | One adapter per surfaced tool of each enabled `mcp_servers` entry | Startup; name collisions are fatal |

`sessions_spawn`/`sessions_send` run the child on a provider worker lease with fail-fast admission and `outputSchemaWhenSupported`. Cancelling the caller's turn does not cancel the child: the dispatch awaits the child's outcome with no link to the parent turn. Outbound MCP (DartClaw as client of external MCP servers) and its egress guard are in [Security Architecture](security-architecture.md) and [ADR-039](../adrs/039-outbound-mcp-trust-boundary-and-transport.md).

---

## 9. Cross-References

| ADR | Relevance |
|---|---|
| [ADR-001](../adrs/001-sdk-integration-and-security-architecture.md) | Direct JSONL approach instead of an SDK layer |
| [ADR-009](../adrs/009-internal-mcp-server.md) | Internal MCP server; `sdkMcpServers` fallback |
| [ADR-016](../adrs/016-multi-provider-harness-architecture.md) | Multi-provider harness design |
| [ADR-027](../adrs/027-claude-harness-setting-sources-default.md) | Settings-source default |
| [ADR-031](../adrs/031-native-first-structured-outputs.md) | Structured-output capabilities |
| [ADR-037](../adrs/037-universal-acp-harness.md) | ACP harness |
| [ADR-052](../adrs/052-native-provider-web-tools-denied-all-container-profiles.md) | Native web tools denied in containers |
| [ADR-054](../adrs/054-model-first-delegation-and-one-authority-per-concern.md) | One authority per concern |
| [ADR-058](../adrs/058-report-quarantined-workers-truthfully.md) | Quarantined workers |

External: [Claude Code headless](https://code.claude.com/docs/en/headless), [CLI reference](https://code.claude.com/docs/en/cli-reference), [hooks](https://code.claude.com/docs/en/hooks), [MCP specification](https://modelcontextprotocol.io/docs/spec).
