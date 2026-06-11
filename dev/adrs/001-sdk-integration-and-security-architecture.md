# ADR-001: SDK Integration Strategy and Security Architecture

**Status:** Superseded — Phase 0 Direct Bridge Migration (2026-02-25). Option C (Hybrid: Dart→Deno→claude) replaced by Option D+ (Dart→claude directly via JSONL control protocol). The Deno worker layer was eliminated; Dart now spawns the native `claude` binary as a direct subprocess. See Addendum and Recommendation sections below for the analysis that drove this decision.
**Date:** 2026-02-17 (revised; original: 2026-02-16; addendum: 2026-02-25; superseded: 2026-02-25)
**Deciders:** DartClaw team

## Context

DartClaw is a security-conscious agent runtime: Dart orchestrator (AOT-compiled, zero npm) + Deno subprocess running the Claude Agent SDK. Descends from OpenClaw (layered defense, Docker sandboxing, credential handling) and NanoClaw (per-group isolation, crash recovery, container strategy).

Research into the Claude Agent SDK revealed it provides far more than initially assumed: hooks, permissions, session persistence, streaming, subagents, MCP integration, and sandbox tooling. This forced a re-evaluation of how much to build custom vs. delegate to the SDK.

### Key Discoveries (from trade-off analysis)

1. **Agent SDK architecture** — The SDK (`@anthropic-ai/claude-agent-sdk`) spawns the Claude Code CLI as a subprocess, communicating via JSONL over stdin/stdout. It does NOT call the Anthropic API directly.

2. **Claude Code CLI is a Bun standalone binary** — Anthropic acquired Bun for this purpose. The native `claude` binary (~183-223 MB) embeds the Bun runtime. **Zero Node.js dependency.** Installed via `curl -fsSL https://claude.ai/install.sh | bash`.

3. **Agent SDK works under Deno** — Proven by [claude-agent-deno-starter](https://github.com/PittampalliOrg/claude-agent-deno-starter). The SDK's `executable: "deno"` option + `pathToClaudeCodeExecutable` pointing to the native binary means the entire chain runs without Node.js.

4. **Deno's `--allow-run` defeats its sandbox** — Deno's own docs: "granting `--allow-run` essentially invalidates the security sandbox." Docker kernel namespaces are the real security boundary.

5. **`ANTHROPIC_BASE_URL` is the canonical credential isolation pattern** — Anthropic's secure deployment guide recommends proxy via Unix socket with `network:none` containers. The SDK natively supports `baseURL` redirection.

### Security Issues Driving Architecture

1. **Credential exposure** — Contradiction between "never expose secrets to worker" and the agent needing API access. Resolved by Dart host proxy injecting credentials at the network layer; container env is clean.

2. **Unrestricted `--allow-run`** — Agent can execute any binary via Deno. Resolved by Docker isolation: even with arbitrary execution, exfiltration is blocked at the network level and filesystem is scoped via mounts.

## Decision Drivers

- **Security boundary strength** — OS-level (kernel namespace) isolation, not application-level
- **Code minimalism** — Don't reinvent what the SDK/CLI already provides
- **Zero Node.js** — No Node.js runtime in the chain (native Bun binary solves this)
- **Credential isolation** — API keys never exist inside the agent container (Phase 2; env vars in Phase 1)
- **Network control** — Defense-in-depth with multiple enforcement layers
- **Maintenance burden** — Prefer battle-tested components over custom implementations

## Considered Options

### Option A: SDK-First

Thin Dart orchestrator; SDK handles sandbox, hooks, permissions, sessions, tool execution, subagents. No Docker.

- ~1200 LOC. Lowest code.
- Application-level isolation only (bubblewrap/Seatbelt). No kernel-level boundary.
- Credentials must exist in worker process env. No proxy option.
- `sandbox-runtime` is Node.js-specific, doesn't fit Deno.

### Option B: Raw Anthropic SDK (Custom Tool Execution)

Use `@anthropic-ai/sdk` directly (not the Agent SDK). Build custom tool execution (bash, file ops) in the Deno worker. Dart manages permissions, sessions, hooks.

- ~2500 LOC. Maximum control.
- Loses Claude Code's agent harness: tool execution, context management, prompt caching, session resume, streaming optimizations.
- Must track raw Claude API changes and build tool implementations (~300 LOC).
- `toolRunner` helper handles the API loop, but not the full agent experience.

### Option C: Hybrid — Agent SDK + Native CLI in Docker (Chosen)

Agent SDK in Deno spawns native `claude` binary (Bun). Docker provides hard security boundary. Dart host manages Docker lifecycle, network proxy, credential injection. SDK features are defense-in-depth inside the container.

- ~1950 LOC. Defense-in-depth (Docker kernel + SDK application).
- **Zero Node.js** — native Bun binary, Deno worker, no npm CLI.
- Credentials never in container in Phase 2 (injected via Dart proxy); env vars in Phase 1.
- Full agent harness: tool execution, hooks, permissions, sessions, streaming, subagents, MCP.

### Option D: Dart Spawns Claude CLI Directly

Skip Deno and Agent SDK entirely. Dart host spawns the native `claude` binary directly with `--output-format stream-json --input-format stream-json`.

- ~1500 LOC. Simplest architecture.
- ~~Hooks/MCP configured via files only (`.claude/hooks.json`), no programmatic control.~~ **Corrected 2026-02-25**: Programmatic hook control IS available via the JSONL protocol — see Addendum below.
- No Deno layer means no custom bridge logic, no in-process MCP servers.
- Strong alternative if the Deno layer proves unnecessary.

### Option E: Embedded JS Runtime via FFI

Embed a JavaScript runtime (V8, Deno, QuickJS, libnode) directly in the Dart process via `dart:ffi`. JS runs in-process with zero IPC overhead.

Candidates investigated (2026-02-25):

- **globe_runtime (Invertase)** — V8 via Rust cdylib. v1.0.8, 9 pub.dev likes. Has `fetch` + basic Web APIs. Bidirectional comms work (JS→Dart via `Dart.send_value()` — corrected from original assessment). **But**: no `child_process`/`fs`/`net` — cannot run Agent SDK. External binary dep (`~/.globe/runtime/`).
- **deno_core as cdylib** — Theoretically possible (Rust crate wrapping V8 + Tokio). No production precedent for C ABI exposure. Must implement Node stdlib, module resolution, TypeScript transpilation manually. V8 init is once-per-process (global statics). Deno maintainer: *"deno is only available as a binary target."* Effort: extreme.
- **libnode (Node.js as shared library)** — Full Node compat including `child_process`. But: must compile Node.js from source, community prebuilts only, ~100 MB dylib per platform. Immature (`libnode_sys`: 13 commits, April 2025).
- **QuickJS** — Dart FFI bindings exist (`quickjs_dart`, `flutter_js`). Tiny (~1-2 MB). But: no Node APIs at all — impossible for Agent SDK.
- **dart:js_interop / Wasm** — Browser-only. Irrelevant for server-side.

**Rejected (all candidates)**: The Agent SDK requires `child_process.spawn()` to launch the `claude` binary — a hard dependency no embeddable JS engine satisfies today. Even if solved, in-process embedding eliminates the process isolation boundary that is DartClaw's core security property. Agent JS code sharing Dart's heap means a single V8 bug could corrupt the host.

## Decision Outcome

**Option C (Hybrid)** chosen. Combines the strongest isolation model (Docker kernel namespaces) with the full Claude Code agent harness and zero Node.js dependency.

### Runtime Architecture

```
Dart Host (AOT binary, runs on host)
  +-- Credentials store (Phase 1: env vars; Phase 2: network proxy)
  +-- SQLite DB (sessions, messages, memory)
  +-- Web UI (shelf + HTMX + SSE)
  +-- Container orchestrator (Docker API)
  +-- Network proxy + allowlist enforcer (Phase 2)
  |
  +-- Docker Container (Phase 2; direct subprocess in Phase 1)
        +-- Deno worker (TypeScript)
        |     +-- Agent SDK (npm:@anthropic-ai/claude-agent-sdk)
        |     +-- NDJSON bridge to Dart host (json_rpc_2)
        |     +-- MCP servers for custom tools (memory search, etc.)
        |
        +-- claude binary (~185-234 MB, Bun standalone)
              +-- Agent harness: tool execution, streaming, sessions
              +-- Built-in tools: Bash, Read, Write, Edit, Glob, Grep
              +-- Hooks: PreToolUse/PostToolUse
              +-- Writes sessions to ~/.claude/projects/ (disable with persistSession: false)
              +-- NO Node.js, NO npm
```

> **Verified 2026-02-23**: SDK architecture confirmed by npm package inspection and runtime testing. The `@anthropic-ai/claude-agent-sdk` package bundles platform-specific `claude` binaries (manifest.json), spawns them as child processes (`ChildProcess` via stdio), and communicates over JSONL. It does NOT call the Anthropic API directly. Session persistence to `~/.claude/projects/` is controlled by the `persistSession` SDK option (default: `true`). DartClaw should set `persistSession: false` to avoid duplicate session storage. The `CLAUDECODE` env var must be cleared in the worker to prevent nesting errors.

### Use from SDK/CLI (don't build custom)

1. Agent loop + tool execution (Claude Code CLI handles autonomously)
2. Hooks — `PreToolUse`/`PostToolUse` for bash sanitization, path validation, audit
3. Permission system — `allowedTools` + `canUseTool` + permission modes
4. Session persistence + resume + crash recovery
5. Streaming events
6. Subagents (Task tool for isolated agents)
7. System prompt management (`systemPrompt` + `settingSources`)
8. MCP integration (`createSdkMcpServer` for custom memory tools)

### Build custom

1. Dart-Deno bridge protocol (json_rpc_2 + StreamChannel over NDJSON pipes)
2. Docker container orchestration (Phase 2)
3. Network proxy in Dart (credential injection, domain allowlist — Phase 2)
4. HTMX web UI + HTTP API (shelf + SSE)
5. SQLite for sessions, messages, memory search (FTS5)
6. Behavior file loading (SOUL.md, CLAUDE.md, MEMORY.md → `systemPrompt`)

### Skip entirely

- Custom agent loop (Claude Code CLI handles it)
- Custom permission system (SDK provides it)
- Custom session management (SDK provides it; augment with SQLite)
- Custom streaming parser (SDK provides it)
- Custom tool execution (CLI provides bash, file ops, etc.)
- `sandbox-runtime` (Docker provides better isolation)
- Hybrid memory search with sqlite-vec (deferred — FTS5-only for Phase 1)

## Comparison

| Aspect | A: SDK-First | B: Raw SDK | C: Hybrid (chosen) | D+: Dart-Native CLI |
|---|---|---|---|---|
| Security boundary | bubblewrap/Seatbelt | Docker + proxy | Docker + SDK hooks + proxy | Docker + hooks + proxy |
| Credential isolation | In worker env | Never in container | Never in container | Never in container |
| Node.js needed | Yes (cli.js fallback) | No | **No (native Bun binary)** | **No** |
| Agent harness | Full (SDK+CLI) | Partial (raw API only) | **Full (SDK+CLI)** | **Full (control protocol)** |
| Network control | sandbox-runtime | Docker + Deno flags | Docker + Deno + proxy | Docker + proxy |
| Code complexity | Low (~1200) | High (~2500) | Medium (~1950) | **Low-Medium (~1500)** |
| Programmability | High (SDK API) | High (custom code) | **High (SDK API + MCP)** | Medium-High (JSONL protocol) |
| Isolation strength | Application-level | OS-level | **OS + application** | OS-level |

## Sub-Decisions

### Bridge Protocol: json_rpc_2 (changed from custom NDJSON)

The `json_rpc_2` Dart package with `StreamChannel` adapter replaces the planned ~200 LOC custom NDJSON implementation.

**Why**: `stream_channel` is already a planned dependency. The `Peer` class implements both client and server over a single channel — exactly DartClaw's bidirectional pattern (Dart→Deno requests + Deno→Dart notifications + Phase 4 Deno→Dart requests for memory operations). Battle-tested request-response correlation, error handling, and parameter validation. ~150 LOC vs ~320 LOC custom, eliminating bug-prone `Completer` management.

### Container Runtime: Docker via OrbStack

Docker (via OrbStack on macOS, native Engine on Linux) is the only viable production isolation.

- **Deno-only disqualified**: `--allow-run` defeats the sandbox (Deno's own docs confirm)
- **Apple Containers**: Not ready (macOS 26 only, pre-1.0, no Linux)
- **Podman**: No meaningful advantage; no OrbStack equivalent on macOS

Container hardening: `--cap-drop=ALL`, `--security-opt=no-new-privileges`, non-root user, read-only root fs, `network:none` + custom bridge.

### Credential Management: Dart Host Proxy (Phased)

Anthropic's own `sandbox-runtime` uses this pattern: Unix socket proxy, `network:none`, `ANTHROPIC_BASE_URL` pointing to proxy.

- **Phase 1 (dev)**: Env var injection. Acceptable risk for trusted developer.
- **Phase 2 (production)**: Dart HTTP proxy on Unix socket. `ANTHROPIC_BASE_URL=http+unix:///var/run/proxy.sock`. Container has zero network except via proxy.

### Memory Search: FTS5-Only for Phase 1 (changed from hybrid)

sqlite-vec is pre-v1 with no Dart bindings (PR stalled 16+ months). FTS5 is built into SQLite — zero additional deps, zero platform concerns.

- BM25 is strong for expected corpus (hundreds of keyword-rich memory chunks)
- `SearchResult` interface designed for future vector scores
- Upgrade path: add sqlite-vec + Deno ONNX embeddings when BM25 proves insufficient

## Security Architecture

```
Dart Host (AOT binary, runs on host)
  +-- Credentials store (env vars, never on disk)
  +-- SQLite DB (sessions, messages, memory + FTS5)
  +-- Web UI (shelf + HTMX + SSE)
  +-- Container orchestrator (Docker API)
  +-- Network proxy + allowlist enforcer
  |
  +-- Main Agent Container
  |     +-- Deno worker + Agent SDK
  |     +-- claude binary (Bun standalone, no Node.js)
  |     +-- FS: /workspace (rw via mount)
  |     +-- Bash: unrestricted (SDK hooks sanitize; Docker limits blast radius)
  |     +-- Net: allowlist (Docker network:none + Dart proxy)
  |     |     api.anthropic.com, github.com, npmjs.org, pypi.org, (user-defined)
  |     +-- SDK hooks: PreToolUse bash sanitization, PostToolUse audit
  |
  +-- Search Agent Container (Phase 4)
        +-- Deno worker + Agent SDK (web tools only)
        +-- FS: none
        +-- Bash: none
        +-- Net: open (for web search)
        +-- Tools: WebSearch, WebFetch only
```

### Security Properties

| Property | Mechanism |
|---|---|
| Credential isolation | Dart host owns all secrets; injects via network proxy (Phase 2) or env var (Phase 1); container env is clean in production |
| Network control | Docker `network:none` + Dart proxy (dual enforcement); Deno `--allow-net` as defense-in-depth |
| Filesystem isolation | Docker mounts: only `/workspace` (rw) and read-only config; symlink resolution + blocked patterns |
| Process isolation | Docker kernel namespaces (pid, net, mount, user) |
| Runtime isolation | No Node.js, no npm CLI in container. Deno + Bun binary only |
| Bash safety | SDK `PreToolUse` hooks sanitize commands; Docker limits blast radius |
| Audit trail | SDK `PostToolUse` hooks + SQLite logging in Dart host |
| Network allowlist config | `~/.dartclaw/network-allowlist.yaml` with sensible defaults; user-extensible |

## Consequences

### Positive

- Defense-in-depth: SDK application-level security inside Docker kernel-level isolation
- **Zero Node.js** in the runtime chain — native Bun binary eliminates npm supply chain concern
- ~40% less custom code vs Option B by reusing SDK/CLI features
- Credentials never exist inside agent containers (production mode)
- Battle-tested at both layers (Claude Code CLI in production at Anthropic, Docker proven for isolation)
- Clean separation: Dart host = orchestration + security, Deno worker = SDK bridge, `claude` binary = agent intelligence
- json_rpc_2 provides battle-tested bidirectional protocol with zero custom correlation logic

### Negative

- Docker required for full security guarantees (dev mode without Docker has weaker isolation)
- `claude` binary is large (~183-223 MB) — container images will be ~280-350 MB
- Network proxy adds latency to API calls (Phase 2; LLM latency dominates)
- Two configuration surfaces (SDK permissions + Docker/network config)
- AVX CPU instruction required for Bun binary (most modern CPUs; fallback to Node.js + cli.js for legacy)
- FTS5-only search misses semantic similarity (upgrade path to hybrid search exists)

### Risks

| Risk | Severity | Mitigation |
|------|----------|------------|
| SDK breaking changes | Medium | Pin version, test upgrades. Coupling contained to Deno worker. |
| Bun binary AVX requirement | Low | Most modern CPUs have AVX. Fallback: Node.js + cli.js. |
| Docker container escape | Low | Non-root, dropped caps, read-only root fs, monitor CVEs (CVE-2024-21626, CVE-2025-9074). Use OrbStack over Docker Desktop. |
| Proxy as bottleneck | Medium | Async I/O, graceful restart. LLM latency dominates. |
| Deno Agent SDK compat | Low | Proven by claude-agent-deno-starter. Deno `child_process` compat covers `spawn()`. |
| json_rpc_2 Deno protocol drift | Low | Integration tests validate both sides. JSON-RPC 2.0 is a stable spec. |
| FTS5 insufficient for semantic queries | Medium | Clean upgrade path to hybrid search (sqlite-vec + Deno ONNX). |
| JSONL control protocol change | Low | Protocol used by official SDKs in 3+ languages — breaking changes unlikely without versioning. `AgentHarness` abstraction allows swapping implementation. Fallback option: Deno + Agent SDK shim (see note below). |

## Addendum: Dart-Native CLI Protocol (2026-02-25)

### New Discovery: The JSONL Protocol Is Reimplementable

Research into the Claude Agent SDK's internals and the claude binary's wire protocol revealed that the TypeScript SDK is a thin process manager + protocol handler. The protocol has been independently reimplemented in Python (official Anthropic SDK), Go (community), and Elixir (community, v0.14.0 on hex.pm).

This means **Option D is significantly stronger than originally assessed**. The Deno/TypeScript layer may be unnecessary.

### Protocol Details (confirmed from Python SDK source + Elixir reimplementation)

The claude binary supports a bidirectional JSONL protocol via `--input-format stream-json --output-format stream-json --verbose`:

**Host → claude stdin:**
```json
{"type": "user", "message": {"role": "user", "content": "query"}}
{"type": "control_response", "request_id": "req_1_abc", "response": {"subtype": "success", "response": {"behavior": "allow"}}}
```

**claude stdout → host:**
```json
{"type": "stream_event", "event": {"delta": {"type": "text_delta", "text": "..."}}}
{"type": "control_request", "request_id": "req_1_abc", "request": {"subtype": "can_use_tool", "tool_name": "Bash", "input": {"command": "ls"}}}
{"type": "result", ...}
```

**Key correction**: Tool approval hooks (`control_request`/`control_response` with `can_use_tool`) work over the JSONL protocol — not just via file-based `.claude/hooks.json`. This was the main reason Option D scored low on "Programmability."

### What the TypeScript SDK Adds (Over Raw Protocol)

**Confirmed 2026-02-25**: The full control protocol was reverse-engineered from both the TypeScript SDK (`sdk.mjs`, v0.2.56) and Python SDK (`subprocess_cli.py`, v0.1.43). **All SDK features are available over the JSONL protocol** — the SDK is a convenience wrapper, not a capability gate.

The SDK provides:
1. Typed message objects + version compat checks (min claude `2.0.0`)
2. `control_request` multiplexing (request_id matching — trivial in Dart)
3. Convenience constructors for hooks, MCP servers, agents
4. Error recovery and retry logic

The SDK does **not** provide capabilities unavailable via the raw protocol.

### Control Protocol Reference (reverse-engineered from SDK source)

#### Initialize handshake (SDK→binary, before any user message)

```json
{
  "type": "control_request",
  "request_id": "req_init_001",
  "request": {
    "subtype": "initialize",
    "hooks": {
      "PreToolUse": [{"matcher": "Bash", "hookCallbackIds": ["hook_0"], "timeout": 30}],
      "PostToolUse": [{"matcher": null, "hookCallbackIds": ["hook_1"]}]
    },
    "sdkMcpServers": ["dartclaw-memory"],
    "systemPrompt": "You are DartClaw...",
    "appendSystemPrompt": "Additional instructions...",
    "agents": {"reviewer": {"description": "...", "prompt": "..."}},
    "jsonSchema": null,
    "promptSuggestions": true
  }
}
```

Binary responds with `control_response` containing `commands`, `models`, `account`.

#### Tool approval (`--permission-prompt-tool stdio` enables this)

Binary→SDK: `{"type": "control_request", "request_id": "X", "request": {"subtype": "can_use_tool", "tool_name": "Bash", "input": {...}, "tool_use_id": "toolu_01..."}}`

SDK→Binary: `{"type": "control_response", "response": {"subtype": "success", "request_id": "X", "response": {"behavior": "allow"|"deny", "toolUseID": "toolu_01..."}}}`

#### Hook callbacks (registered in initialize, invoked by binary)

Binary→SDK: `{"type": "control_request", "request_id": "X", "request": {"subtype": "hook_callback", "callback_id": "hook_0", "input": {"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {...}}}}`

SDK→Binary: `{"type": "control_response", "response": {"subtype": "success", "request_id": "X", "response": {"continue": true, "hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}}}}`

#### In-process MCP servers (proxied JSONRPC over control protocol)

Binary→SDK: `{"type": "control_request", "request_id": "X", "request": {"subtype": "mcp_message", "server_name": "dartclaw-memory", "message": {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {...}}}}`

SDK→Binary: `{"type": "control_response", "response": {"subtype": "success", "request_id": "X", "response": {"mcp_response": {"jsonrpc": "2.0", "id": 1, "result": {...}}}}}`

#### Other control messages (SDK→binary, post-initialize)

`interrupt`, `set_permission_mode`, `set_model`, `set_max_thinking_tokens`, `apply_flag_settings`, `rewind_files`, `stop_task`, `mcp_set_servers`, `mcp_status`, `mcp_reconnect`

### Revised Option Assessment

| Option | Effort | Layers | Container Size | Programmability | Risk |
|---|---|---|---|---|---|
| **C: Hybrid (current)** | Done | 3 (Dart→Deno→claude) | ~280-350 MB | High (SDK API) | Low (proven) |
| **D+: Dart-native** | Medium | 2 (Dart→claude) | ~200-250 MB | **High (full control protocol)** | Medium (protocol stability) |
| **E: FFI embedding** | Extreme | 1 (in-process) | N/A | N/A | Dead end |

**Option D+ advantages over Option C:**
- Eliminates Deno runtime dependency (~50-80 MB)
- Eliminates TypeScript code and build/maintenance
- Removes one full IPC layer (Dart↔Deno NDJSON bridge gone)
- Simpler debugging (Dart + claude binary, no middle layer)
- Smaller container image
- Zero npm/Deno supply chain surface

**Option D+ risks:**
- Protocol stability — no formal versioning guarantee (but Python SDK pins to min version `2.0.0`)
- MCP server registration — unclear if possible without SDK `initialize` handshake
- UTF-8 chunk boundary handling in Dart streams (non-trivial but solved problem — Elixir SDK handles it)
- Must track claude binary protocol changes (vs. SDK absorbing them)

### Proof-of-Concept Results (2026-02-25)

A ~250 LOC Dart PoC (`prototypes/claude_direct_bridge_poc.dart`) validated the core protocol. Zero external dependencies — pure `dart:io`, `dart:convert`, `dart:async`.

**Spawn command**:
```
claude --print --input-format stream-json --output-format stream-json \
       --verbose --include-partial-messages --no-session-persistence \
       --model haiku
```

**Environment**: Must clear `CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` env vars (nesting detection). Use `Process.start(..., includeParentEnvironment: false)` with a filtered copy of `Platform.environment`.

**Results — all 3 test cases pass**:

| Turn | Prompt | Response | Duration | Tools |
|---|---|---|---|---|
| 1 | "What is 2+2?" (no tools) | `"4"` | 1.3s | 0 |
| 2 | "Use Bash to echo..." (tool use) | `"Done! ... hello from dartclaw poc"` | 3.5s | Bash (auto-approved) |
| 3 | "What was the output?" (multi-turn) | `"hello from dartclaw poc"` | 1.0s | 0 |

**Protocol observations**:
- `system:init` event provides session ID + available tools list (85 tools)
- Session ID persists across turns within a single process — multi-turn works
- Streaming text deltas arrive via `stream_event` → `content_block_delta` → `text_delta`
- Complete assistant messages arrive via `assistant` type (use one or the other, not both, to avoid double-counting)
- Tool execution (Bash) happens autonomously inside the claude binary
- `LineSplitter` handles NDJSON chunk boundaries correctly — no custom buffering needed
- 126–299 NDJSON lines parsed per 3-turn session, all valid JSON

**`control_request` — WORKS after initialize handshake**: Adding `--permission-prompt-tool stdio` and sending an `initialize` control request with `hooks.PreToolUse` registered, the binary correctly sends `hook_callback` control requests to Dart before tool execution. Dart responds with allow/deny decisions. Confirmed working for Bash tool with PreToolUse hook:

```
CONTROL REQUEST #1: hook_callback (PreToolUse, tool: Bash, callback: hook_bash_pre)
HOOK RESPONSE #1: ALLOW
```

**Full control protocol validated**: initialize handshake, hook callbacks, tool execution, streaming, multi-turn — all working from ~300 LOC pure Dart, zero TypeScript.

### Resolved Questions (2026-02-25)

1. **`initialize` handshake** — **Fully reverse-engineered** from TS SDK v0.2.56 and Python SDK v0.1.43. Format documented above. All fields optional except `subtype: "initialize"`.
2. **`canUseTool` activation** — `--permission-prompt-tool stdio` CLI flag enables it. Binary sends `control_request` with `subtype: "can_use_tool"` for every tool invocation.
3. **MCP server registration** — Two paths: (a) External stdio/sse/http servers via `--mcp-config` CLI flag; (b) In-process "SDK" MCP servers via `sdkMcpServers` in `initialize` + `mcp_message` control requests proxying JSONRPC. Dart can implement MCP servers in-process using path (b).
4. **Hooks via protocol** — Registered in `initialize` with callback IDs. Binary invokes via `control_request` with `subtype: "hook_callback"`. Dart handles in-process — no shell scripts needed.
5. **Hooks via CLI** — Also possible via `--settings` flag with `hooks` JSON (shell command handlers). Two independent mechanisms.
6. **Protocol stability** — Documented in Claude Code headless docs. Python SDK pins to min version `2.0.0`. Control protocol used by official SDKs in 3 languages.

### Remaining Open Question

- **Protocol versioning** — No explicit version negotiation in the initialize handshake. Breaking changes would need to be detected via claude binary version check (`claude --version`), similar to how the Python SDK enforces min version `2.0.0`.

### Considered Fallback: Deno + Agent SDK Shim (2026-03-09)

Evaluated building a thin Deno CLI app using `@anthropic-ai/claude-agent-sdk` that speaks the same JSONL protocol and CLI flags as the `claude` binary — a drop-in replacement binary that DartClaw could spawn via `AgentHarness`. The Agent SDK wraps the same `claude` binary internally, so the shim would produce identical JSONL output.

**Decision: Deferred indefinitely.** The protocol is stable (used by official SDKs in Python, Go, Elixir + community implementations), and the `AgentHarness` abstraction already provides the swap point. If Anthropic signals a protocol change (deprecation notice, SDK major version), there would be sufficient runway to build the shim then. The cost of maintaining it speculatively outweighs the insurance value.

### Recommendation

**Option D+ is fully validated.** All three previously-blocking features — programmatic tool approval, in-process hooks, and in-process MCP servers — work over the JSONL control protocol without the TypeScript SDK. The Deno layer provides no capabilities that Dart cannot replicate directly.

**Recommended path forward**:
1. Build a Dart `ClaudeProtocolClient` class implementing the control protocol (~500-800 LOC)
2. Replace the current 3-layer architecture (Dart→Deno→claude) with 2-layer (Dart→claude)
3. Eliminate the Deno worker, TypeScript code, and `@anthropic-ai/claude-agent-sdk` dependency
4. Implement DartClaw MCP servers (memory search, etc.) as in-process handlers responding to `mcp_message` control requests
5. Implement PreToolUse/PostToolUse hooks as in-process handlers responding to `hook_callback` control requests

**Benefits**: ~80 MB smaller container (no Deno), zero TypeScript maintenance, simpler debugging, one fewer IPC layer, zero npm/Deno supply chain surface. **Risk**: protocol changes require updating Dart code directly (vs. SDK absorbing them). Mitigated by version checking and the protocol's stability across 3 official SDK implementations.

### Multi-Provider Model Support

The `claude` binary natively supports **Claude models only**, but via three deployment targets (direct API, AWS Bedrock, Google Vertex AI). The only seam for non-Anthropic models is `ANTHROPIC_BASE_URL` — an env var that redirects all API calls to a custom endpoint.

**Working patterns for non-Anthropic models:**
- **LiteLLM proxy** — translates Anthropic Messages API → OpenAI/Gemini/etc. Officially documented by Anthropic
- **Ollama v0.14+** — native Anthropic Messages API compat, no proxy needed
- **Community proxies** — claude-code-proxy, claude-code-router, claude-code-mux (OpenRouter, DeepSeek, etc.)

**Practical limitation**: The proxy translation is solved, but model capability is the real bottleneck. Claude Code's dense, multi-step tool sequences require strong tool-calling ability — weaker models fail. 32K-64K context minimum. Extended thinking blocks are Claude-specific.

**DartClaw implication**: `ANTHROPIC_BASE_URL` is just an env var. The Dart host controls the agent process environment — multi-provider is a configuration concern, not an architecture concern. Works identically for both Option C and D+.

### Alternative Agent Harnesses

Research into alternative agent SDKs/harnesses for potential integration alongside or instead of the Claude Agent SDK:

**Pi by badlogic** (`pi-mono`, 16.4k stars) — the **only** non-Anthropic framework with a documented subprocess RPC protocol:
- `pi --mode rpc` exposes bidirectional NDJSON over stdin/stdout — purpose-built for non-Node.js host integration
- Supports all major model providers natively (Anthropic, OpenAI, Google, Mistral, Groq, Ollama, OpenRouter, etc.)
- Built-in tool execution (read/write/edit/bash) — no external binary needed
- Session management, context compaction, model switching at runtime
- Node.js required (~100-200 MB)
- Pi SDK README references openclaw — DartClaw's lineage project

**Other frameworks evaluated** (OpenAI Agents SDK, Pydantic AI, CrewAI, AutoGen/MS Agent Framework, Mastra): All are library-only with no subprocess RPC protocol. Would require custom Python/TS wrapper scripts for Dart integration. Not practical without significant glue code.

**Pluggable backend architecture**: Technically feasible with two clean implementations sharing the same transport pattern:
1. `ClaudeBackend` — Dart speaks JSONL to `claude` binary
2. `PiBackend` — Dart speaks NDJSON to `pi --mode rpc`

Both are subprocess + line protocol — the Dart-side abstraction is natural. **Recommendation: defer.** Complexity-to-value ratio is poor for DartClaw's single-user, Claude-native focus. But Pi is worth noting as the strongest multi-model fallback if needed.

**MCP as integration layer**: Rather than per-framework bridges, DartClaw's custom capabilities (memory search, scheduling, etc.) can be exposed as MCP servers consumable by any MCP-compatible agent. This aligns with the existing `createSdkMcpServer` pattern and works across frameworks.

### Existing Implementations in Other Languages

| Runtime | Project | Status |
|---|---|---|
| Python | `claude-agent-sdk-python` (Anthropic official) | Production, subprocess + JSONL |
| Go | `claude-agent-sdk-go` (community) | Active, port of Python SDK |
| Elixir | `claude_agent_sdk` (hex.pm v0.14.0) | Active, full streaming via Erlexec |
| Dart | `claude_code_sdk` (pub.dev v2.1.0) | Low quality — `Process.run()`, no streaming |

## References

- [Claude Agent SDK docs](https://platform.claude.com/docs/en/agent-sdk/)
- [SDK secure deployment guide](https://platform.claude.com/docs/en/agent-sdk/secure-deployment)
- [Claude Code sandboxing](https://www.anthropic.com/engineering/claude-code-sandboxing)
- [Bun joins Anthropic](https://bun.com/blog/bun-joins-anthropic) — Claude Code as Bun standalone binary
- [Native binary announcement](https://www.threads.com/@boris_cherny/post/DQfE5QyEmrQ/) — no more Node.js/npm dependency
- [claude-agent-deno-starter](https://github.com/PittampalliOrg/claude-agent-deno-starter) — proven Deno + Agent SDK
- [sandbox-runtime](https://github.com/anthropic-experimental/sandbox-runtime) — Anthropic's proxy pattern
- [Docker AI agent sandboxing](https://www.docker.com/blog/docker-sandboxes-a-new-approach-for-coding-agent-safety/)
- [OrbStack](https://docs.orbstack.dev/compare/docker-desktop) — recommended Docker runtime for macOS
- [json_rpc_2](https://pub.dev/packages/json_rpc_2) — Dart JSON-RPC 2.0 package
- [sqlite-vec](https://github.com/asg017/sqlite-vec) — future hybrid search (pre-v1)
- [OpenClaw security patterns](https://github.com/openinterface-ai/openclaw)
- [NanoClaw](https://github.com/qwibitai/nanoclaw) — per-group isolation, crash recovery
- SDK security architecture trade-off analysis is archived privately.

### Added 2026-02-25

- [Claude Code headless/programmatic docs](https://code.claude.com/docs/en/headless) — stream-json protocol reference
- [claude-agent-sdk-python](https://github.com/anthropics/claude-agent-sdk-python) — Python SDK (subprocess + JSONL, same architecture)
- [claude-agent-sdk-go](https://github.com/schlunsen/claude-agent-sdk-go) — Go community port
- [claude_agent_sdk (Elixir)](https://hexdocs.pm/claude_agent_sdk/) — Elixir reimplementation (hex.pm v0.14.0)
- [claude_code_sdk (Dart)](https://pub.dev/packages/claude_code_sdk) — community Dart package (no streaming, low quality)
- [Inside the Claude Agent SDK](https://buildwithaws.substack.com/p/inside-the-claude-agent-sdk-from) — protocol deep dive
- [globe_runtime](https://pub.dev/packages/globe_runtime) — Invertase V8 bridge (v1.0.8, bidirectional but no Node APIs)
- [deno_core embedding discussion](https://github.com/denoland/deno/discussions/21968) — Deno as library crate
- [rustyscript](https://github.com/rscarson/rustyscript) — Rust deno_core wrapper (no C ABI)
- [libnode_sys](https://github.com/alshdavid/libnode_sys) — Rust bindings for embedded Node.js (immature)
- [pi-mono](https://github.com/badlogic/pi-mono) — TypeScript agent with RPC subprocess mode
- [pi RPC protocol docs](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/rpc.md) — NDJSON protocol reference
- [Claude Code LLM Gateway docs](https://code.claude.com/docs/en/llm-gateway) — ANTHROPIC_BASE_URL + proxy
- [LiteLLM Claude Code integration](https://docs.litellm.ai/docs/tutorials/claude_non_anthropic_models) — multi-provider via proxy
- [Ollama Anthropic API compat](https://ollama.com/blog/claude) — native Anthropic Messages API in Ollama v0.14+
- [claude-code-proxy](https://github.com/1rgs/claude-code-proxy) — community OpenAI/Gemini proxy
- [claude-code-mux](https://github.com/9j/claude-code-mux) — Rust multi-provider router
- [Claude Code Settings schema](https://json.schemastore.org/claude-code-settings.json) — hooks, permissions JSON schema
- [Claude Code Hooks Reference](https://code.claude.com/docs/en/hooks) — PreToolUse/PostToolUse via settings
- [Claude Code CLI Reference](https://code.claude.com/docs/en/cli-reference) — all flags
- TypeScript SDK source: `@anthropic-ai/claude-agent-sdk@0.2.56` (`sdk.mjs`) — initialize, processControlRequest
- Python SDK source: `claude-agent-sdk-python@0.1.43` (`subprocess_cli.py`, `query.py`, `types.py`)
- PoC: `prototypes/claude_direct_bridge_poc.dart`

## Amendment (0.16.4) — lean-dependency security posture reinforced

Recorded retroactively 2026-05-31. 0.16.4 reinforced this ADR's minimal-attack-surface / security-by-design posture with concrete, recurring decisions worth noting here:

- **Zero new third-party dependency for the CLI HTTP/SSE client** — `DartclawApiClient` (connected workflow execution + SSE progress streaming, see [ADR-030](030-connected-by-default-workflow-execution.md)) is built on `dart:io` `HttpClient` + `dart:convert`, with no `package:http` / `package:dio`. The lean-dependency principle held even for a substantial new HTTP subsystem.
- **Fail-closed asset integrity** — the CLI asset downloader verifies SHA-256 before use.
- **Git credential-helper suppression** — DartClaw-orchestrated git operations inject `GIT_CONFIG_*` overrides to neutralize ambient OS credential helpers (osxkeychain, manager-core, libsecret), preventing accidental reuse of host credentials.

See CHANGELOG `[0.16.4]`.
