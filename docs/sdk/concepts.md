# Core Concepts

**SDK Guide** | [Quick Start](quick-start.md) | [Architecture](architecture.md) | [Security](security.md) | [Package Guide](packages.md) | [Examples](../../examples/sdk/)

DartClaw has two tiers, and they have different mental models. The [Package Guide](packages.md) explains which one you want; this page explains how each one thinks.

## Tier 1: Client-Tier Concepts

The client tier is a transport plus data types. There is no runtime in your process — the agent, its harness, its guards, and its storage all live inside the `dartclaw serve` you point at.

### The Client

`DartclawApiClient` holds a base URI and a bearer token. That is its entire state. It sends `authorization: Bearer <token>` on every request, requests `application/json`, and hands you the decoded body:

- `get` / `post` / `patch` / `delete` return decoded JSON (`Object?`).
- `getObject` / `getList` / `postObject` / `patchObject` / `deleteObject` assert the JSON shape and raise if it does not match.
- `getText` is for endpoints that emit non-JSON bodies, such as `application/yaml`.
- `probeHealth` reports whether the server answers at all, optionally counting `401`/`403` as "reachable but unauthorized".

Responses are `Map<String, dynamic>` and `List<dynamic>`. The client deliberately mints no per-endpoint DTOs: the types those endpoints carry (`Task`, `WorkflowRun`, `WorkflowDefinition`) are owned by the runtime packages, and copying them into the client would create a second answer for one JSON contract. `Session` and `Message` are the exception — they already live in `dartclaw_kernel`, which the umbrella re-exports.

### Event Streams

`streamEvents(path)` follows an SSE endpoint and yields each `data:` frame decoded as a map. Multi-line frames are joined before decoding; a frame carrying no `data:` line is skipped rather than aborting the stream.

Reconnection is a caller decision. With no `onDisconnect` callback the stream ends on the first drop. Supply one and it is asked, per attempt, whether to reconnect; attempts are spaced by `reconnectDelays` and capped by `maxReconnects`, after which the stream raises `DartclawApiException` with code `SSE_RECONNECT_EXHAUSTED`.

### Errors

Every non-2xx status raises `DartclawApiException`, carrying the server's error envelope: `code`, `statusCode`, and `details`. Transport failures raise the same type with no `statusCode`, and sometimes a `code` — a refused connection is reported as `CONNECTION_REFUSED` on macOS and Linux, but the errno match does not cover Windows, where the same failure arrives with no `code`.

`message` never contains the bearer token, and a `401` carries remediation guidance naming `dartclaw token show`, `dartclaw token rotate`, `gateway.token`, and `--token` instead — DartClaw-CLI-shaped wording, inherited from where this client was extracted from. It can contain the base URI, so keep credentials out of `baseUri` before printing it.

### The Transport Seam

`ApiTransport` is the boundary between the client and the wire, with `ApiRequest` and `ApiResponse` as its value types. The default implementation uses `dart:io`. Implement it yourself to drive the client from a fake in your tests — that is how the DartClaw CLI's own connected-command suites work — or to run over a different transport.

## Tier 2: Runtime Concepts

The runtime tier is what `dartclaw serve` is made of. You reach for it when you want the harness in your own process; you own the fork.

### The Mental Model

A runtime host has two layers:

- The Dart host owns lifecycle, policy, persistence, routing, and integration with the outside world.
- The native agent binary owns model reasoning, tool protocol execution, and streamed response generation.

The main loop is:

1. Create or load a `Session`.
2. Build the message list for the next Turn.
3. Let a `GuardChain` evaluate inbound content and tool approval requests.
4. Send the Turn through an `AgentHarness`.
5. Listen for `BridgeEvent` values such as `DeltaEvent` and `ToolUseEvent`.
6. Persist messages, metadata, usage, and any application state your host needs.

### Harnesses

`AgentHarness` is the common contract for provider-specific workers. `ClaudeCodeHarness` wraps the native `claude` binary; `CodexHarness` wraps Codex's app-server protocol. Both start the worker process, send turns over the provider control protocol, and expose typed stream events. Hosts must call `start()` before the first turn and `dispose()` during shutdown.

Use a harness directly for small tools and examples. Larger hosts construct harnesses through a factory or pool so they can share provider config, guard chains, and worker lifecycle policy.

### Turns and Events

A Turn is one round of user input, agent reasoning, tool use, and response streaming. `turn()` accepts a `sessionId`, message list, and system prompt, then returns a typed `TurnResult` with stop reason and usage.

Text streams before the final result. Subscribe to `harness.events`:

- `DeltaEvent` streams assistant text.
- `ToolUseEvent` reports requested tools.
- `SystemInitEvent` reports provider initialization.

This is where a host updates a terminal, emits its own Server-Sent Events, appends timeline records, or feeds an observability layer. The SSE frames the *client* tier consumes are one host's rendering of exactly this stream.

### Sessions and Messages

`SessionService` and `MessageService` are file-backed primitives for hosts that want SDK-managed session state. `SessionKey` gives deterministic routing keys for web, direct-message, group, cron, and task sessions.

For simple CLIs, a stable session key plus `MessageService.getMessages()` is enough for multi-turn history. For services, the same primitives separate user sessions, channel sessions, and background job sessions while keeping persistence in ordinary files.

### Guards

`Guard` is the policy extension point. A guard receives a `GuardContext` and returns a `GuardVerdict`: `GuardPass` allows, `GuardWarn` allows and records, `GuardBlock` denies.

`GuardChain` evaluates guards in order. The first block wins, warnings are preserved, and unexpected guard failures fail closed unless you explicitly opt into fail-open behavior. The chain can run before tool calls, when messages arrive, or before content is sent back to a user.

### Storage and Memory

`dartclaw_core` provides file-backed session, message, key-value, and memory-file services together with SQLite-backed memory search, pruning, and repository implementations. Repository contracts remain substitutable when a host provides another persistence backend.

### Context Engine and MCP

The reference server exposes MCP tools through its in-process MCP server. Inbound `tools/call` dispatch is guarded and audited at one seam in the protocol handler — after caller authorization and schema validation, before the tool runs — so a registered tool never carries that plumbing itself. A guard block, a guard evaluator that throws, and an audit-write failure each refuse the call; an individual guard's own error still follows `security.guards.fail_open`. Every `McpTool` declares a required `access` classification (`read` or `write`). `dartclaw_runtime` also includes an outbound MCP client for hosts that consume configured external MCP servers; servers are configured by name, and the pool applies guard, audit, and per-server governance checks before external `tools/call` dispatch.

`context_research` is the built-in Context Engine synthesis tool. It retrieves across memory search, temporal KG facts, and wiki/source documents, then returns a compact citation packet. The packet model preserves source references so UI and agent consumers can distinguish cited statements from unattributed fallback snippets. Synthesized packets are never cached.

### Channels

`Channel` and `ChannelManager` model external messaging platforms. Channel packages such as `dartclaw_whatsapp`, `dartclaw_signal`, and `dartclaw_google_chat` adapt specific platforms into the shared channel message and response types. A host that has no messaging platform in scope skips them entirely.

## Reference Implementations

`dartclaw_runtime` and `dartclaw_cli` compose the runtime tier into a complete HTTP API, HTMX web UI, operational CLI, task runtime, and deployment workflow. They are working implementations, not the SDK, and they are intentionally larger than the runnable examples.

`dartclaw_cli` is also the largest consumer of the *client* tier: its connected command families (`tasks`, `traces`, `config`, `projects`, `sessions`, `workflow`, `runners`, `jobs`) all speak to a server through `dartclaw_client`. Read `apps/dartclaw_cli/lib/src/commands/` for a production-sized example of tier 1.

## Where To Go Next

- [Architecture](architecture.md) — the tier boundary and the seams on each side.
- [Security](security.md) — token handling, guard chains, isolation, credentials, audit.
- [custom_guard](../../examples/sdk/custom_guard/) — a minimal guard extension.
- [multi_turn_cli](../../examples/sdk/multi_turn_cli/) — session-backed conversation history.
- [shelf_server](../../examples/sdk/shelf_server/) — a minimal HTTP host over the runtime.
