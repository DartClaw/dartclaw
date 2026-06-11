# ADR-009: Internal MCP Server as Primary Tool Extension Point

**Status:** Accepted
**Date:** 2026-03-02
**Deciders:** DartClaw team

## Context

DartClaw spawns the `claude` binary as a subprocess, communicating via bidirectional JSONL over stdin/stdout (the control protocol). The control protocol handles conversation lifecycle — turn management, `PreToolUse`/`PostToolUse` approval hooks, hook callbacks. Adding new tools to the agent's capability surface requires a separate mechanism.

Currently, `sessions_send` (inter-agent delegation) and memory tools are registered via `McpToolRegistry`, which uses the `sdkMcpServers` field in the `initialize` control-protocol handshake. The binary routes `tools/call` invocations to Dart via `mcp_message` control requests. This works but has a key limitation: `sdkMcpServers` is a Claude-SDK-private extension, not the published MCP specification. Tools declared this way are invisible to any external MCP client or inspector — there is no `tools/list` endpoint and the tool manifest cannot be queried outside the running DartClaw+claude-binary pair.

As DartClaw evolves, the tool surface grows:
- `sessions_send` — inter-agent delegation
- Web search (Brave, Tavily) — proper search API independent of `ANTHROPIC_API_KEY`
- `web_fetch` with ContentGuard scanning at the tool boundary (not post-facto)
- SDK extensibility — `dartclaw` SDK consumers need a `server.registerTool(myTool)` API

The `claude` binary supports MCP natively via stdio (subprocess) or SSE/HTTP endpoint. DartClaw already runs a shelf HTTP server.

### The ContentGuard auth problem

`ContentGuard` uses `AnthropicClient`, a raw Dart HTTP client calling `api.anthropic.com/v1/messages` with `x-api-key`. This requires `ANTHROPIC_API_KEY` — OAuth credentials managed by the `claude` binary cannot be used. Users authenticated via OAuth cannot use ContentGuard.

The fix (F12 in the 0.5 PRD) is orthogonal to the MCP server choice: a `ContentClassifier` interface with `ClaudeBinaryClassifier` as default (invokes `claude --print --model <model> --max-turns 1`, inherits binary auth) and `AnthropicApiClassifier` as opt-in.

### The PostToolUse timing problem

The `PostToolUse` hook fires **after** the tool result has been embedded in the binary's context window. `continue: false` aborts the current turn, but the model has already processed the fetched content. For a tool like `web_fetch`, this means ContentGuard scans content after the agent has seen it — not before. For a "security-conscious agent runtime," this is a false boundary for prompt-injection defense.

The only architectural path to genuine pre-agent content scanning for `web_fetch` is for Dart to own the fetch execution and apply ContentGuard synchronously before returning the result.

## Decision Drivers

- **ContentGuard boundary** — `web_fetch` results must pass through ContentGuard before the agent sees them; this requires a Dart-owned tool handler, not a PostToolUse hook
- **SDK story** — SDK consumers need `server.registerTool(myTool)` without knowing MCP internals
- **Standard compliance** — proper MCP manifest visible to external tooling over the published protocol
- **Auth parity** — `web_search` replacement (Brave/Tavily) must not require `ANTHROPIC_API_KEY`
- **Minimalism** — reuse the existing shelf server; no new runtime process dependencies

## Considered Options

### Option A: Continue with `sdkMcpServers` / `McpToolRegistry`

The current approach. `McpToolRegistry` registers tools via the `sdkMcpServers` initialize handshake field; the binary routes `tools/call` invocations as `mcp_message` control requests. **Not raw JSONL stream interception** — tools are declared in a standards-shaped format (JSON Schema schemas, MCP-style dispatch).

- **Pros**: Zero new infrastructure; already working; in-process state access; auth-agnostic; O(1) tool dispatch
- **Cons**: `sdkMcpServers` is a Claude-SDK-private protocol extension (not published MCP spec); tools invisible to external MCP clients; no `tools/list` endpoint; no server-level `registerTool()` API; `web_fetch` ContentGuard still hits PostToolUse timing problem
- **Weighted score: 6.99 / 10**

### Option B: External MCP Server Processes Per Tool Set

Spawn separate MCP server processes (Python for Brave Search, Dart binary for `sessions_send`, etc.). Configure via `--mcp-config`. Each is an independent MCP server.

- **Pros**: Genuine published-spec MCP protocol; language flexibility; proper `tools/list` manifest
- **Cons**: ContentGuard permanently decoupled from tool execution (no pre-agent scanning without IPC); per-process lifecycle management; container isolation model conflict (`network:none`); no DartClaw state access without IPC back-channel; SDK consumer must build and ship a full server process
- **Weighted score: 2.95 / 10** — **disqualified by ContentGuard and container topology conflicts**

### Option C: Internal MCP Server (HTTP Endpoint in DartclawServer) ✓ Chosen

Add a `/mcp` endpoint to the existing shelf server. The `claude` binary's `--mcp-config` points to `http://localhost:<port>/mcp`. All tools are registered against this single in-process server via `DartclawServer.registerTool(McpTool)`.

- **Pros**: Genuine published-spec MCP protocol; pre-agent ContentGuard scanning (handler owns execution); single `registerTool()` SDK call; direct in-process state access; reuses existing shelf server; clean migration path from `sdkMcpServers`
- **Cons**: ~385-490 LOC new code; `mcp_dart` server-side is `dart:io`-bound (requires shelf bridge ~110 LOC); startup ordering constraint; managed teardown required
- **Weighted score: 8.28 / 10**

### Option D: Built-in Claude Tools + PostToolUse Hooks Only

Use the binary's built-in `web_search`/`web_fetch`. Apply ContentGuard via `PostToolUse` hook. No new tools beyond what the binary provides natively.

- **Pros**: Zero new code; zero runtime complexity; PostToolUse hook already exists
- **Cons**: PostToolUse fires after agent has seen content (no genuine pre-agent scanning); `web_search` requires `ANTHROPIC_API_KEY` (no OAuth path — API billing, not subscription); cannot add custom tools; incompatible with SDK publishing story
- **Weighted score: 4.80 / 10** — **disqualified by PostToolUse timing and OAuth exclusion**

## Decision

**Option C — Internal MCP server hosted within DartclawServer.**

Option C wins on the three criteria with the highest combined weight: ContentGuard boundary (9 vs 7 over A), SDK extensibility (9 vs 6 over A), long-term scalability (9 vs 6 over A). The 1.29 point gap over the nearest alternative (A: 6.99) reflects a decisive alignment with DartClaw's medium-term goals.

**Staged deployment:** Option A (`McpToolRegistry`) remains correct until Phase G (0.5). Phase G implements Option C and retires `McpToolRegistry`. The migration is atomic and clean — `sessions_send` moves from `sdkMcpServers` interception to a standard `McpTool` implementation.

The tool extension mechanism becomes: implement `McpTool` and call `server.registerTool(tool)`. All registered tools are served via the `/mcp` endpoint. The `claude` binary harness config includes the internal MCP server URL.

ContentGuard auth is resolved separately (F12) via `ContentClassifier` interface + `ClaudeBinaryClassifier` default — orthogonal to this decision but a prerequisite for wiring ContentGuard into the `web_fetch` MCP tool handler.

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                   DartclawServer                    │
│                                                     │
│  /api/*            REST API                         │
│  /webhook/*        Channel webhooks                 │
│  /mcp              MCP server (HTTP/SSE)  ◄── claude │
│                                                     │
│  Tool registry (all in-process):                    │
│    sessions_send   → SessionDelegate                │
│    web_fetch       → ContentGuard → HttpFetch       │
│    brave_search    → BraveClient                    │
│    [user tools]    → SDK extensions                 │
└─────────────────────────────────────────────────────┘

Communication channels:
  JSONL stdin/stdout  — conversation control (turn mgmt, approval hooks)
  MCP/HTTP over HTTP  — tool registration and invocation
```

## Consequences

### Positive

- Tools visible to external MCP tooling via standard `tools/list` endpoint
- `web_fetch` ContentGuard scanning is genuinely pre-agent (handler owns execution)
- `DartclawServer.registerTool()` enables the SDK publishing work described in ADR-008.
- Zero new process management — all tools run in-process on existing shelf server
- Clean retirement of `sdkMcpServers` / `McpToolRegistry` non-standard mechanism
- OAuth users can use ContentGuard (via `ClaudeBinaryClassifier` in F12) and web search (via Brave/Tavily)

### Negative

- ~385-490 LOC net new code for the MCP endpoint and tool infrastructure
- `mcp_dart` server-side transports are `dart:io`-bound; a shelf bridge (`ShelfMcpTransport`, ~110 LOC) is required, or a pure custom implementation (~550 LOC with no new dependency)
- Tool registration is static-at-startup — `registerTool()` must be called before `server.start()`; dynamic hot-add requires future `tools/list_changed` notification support
- Circular topology (DartClaw starts claude which connects back to DartClaw) requires careful shutdown ordering; crash recovery must clean up stale MCP sessions

### Neutral

- The 2025-03-26 Streamable HTTP transport (`type: http`) is preferred over the legacy SSE transport (`type: sse`, 2024-11-05) for new implementations — simpler protocol, no future migration needed. `mcp_dart`'s `StreamableHTTPServerTransport` provides the reference.
- Gateway token must be written to a `0600` temp file passed via `--mcp-config`; passing inline as a CLI string exposes the token in `ps aux`

## Implementation Notes (Phase G)

1. **Transport choice:** Target Streamable HTTP (`type: http`) from the start. `mcp_dart`'s protocol layer (`McpServer`) is reusable with a custom `ShelfStreamableTransport` bridge. Avoids future migration from deprecated SSE transport.
2. **`McpTool` interface:** `name`, `description`, `inputSchema` (JSON Schema), `Future<String> call(Map<String, dynamic> args)`. Intentionally minimal — no MCP knowledge required from implementers.
3. **Auth:** Gateway token written to a temp file (`chmod 0600`) at harness startup; deleted on stop. Passed as `--mcp-config <path>` flag.
4. **Built-in conflict:** When `web_fetch` is registered on the internal server, add `HarnessConfig.disallowedTools: ['web_fetch']` to prevent the binary's built-in from competing.
5. **`McpToolRegistry` retirement:** Remove `sdkMcpServers` initialization path in `_sendInitialize`. Delete `McpToolRegistry`, `McpToolDef`, `McpServerEntry`. Migrate memory tools and `sessions_send` to `McpTool` implementations registered at `DartclawServer` level.
6. **Integration test:** Cover crash recovery → harness respawn → MCP reconnect to validate circular topology behavior under failure.

## References

- [ADR-001](001-sdk-integration-and-security-architecture.md) — original decision to use `claude` binary directly (why control protocol is separate from MCP)
- [ADR-008](008-sdk-publishing-strategy.md) — SDK publishing strategy (Phase G enables `registerTool()` extensibility story)
- 0.5 PRD — implementation scope
- [`mcp_dart` package](https://pub.dev/packages/mcp_dart) — MCP protocol layer for Dart (server-side `McpServer` reusable; transports require shelf bridge)
- Research sources are summarized in the linked research appendix.
