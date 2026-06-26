# Core Concepts

**SDK Guide** | [Quick Start](quick-start.md) | [Architecture](architecture.md) | [Security](security.md) | [Examples](../../examples/sdk/)

DartClaw is a Dart SDK for building agent runtimes around native agent binaries. The SDK gives your Dart host a stable set of primitives for turns, streaming events, policy checks, sessions, storage, and channels. The deployable `dartclaw_server` and `dartclaw_cli` are reference implementations that compose those same packages into a full application.

## The Mental Model

A DartClaw app has two layers:

- The Dart host owns lifecycle, policy, persistence, routing, and integration with the outside world.
- The native agent binary owns model reasoning, tool protocol execution, and streamed response generation.

The main loop is:

1. Create or load a `Session`.
2. Build the message list for the next Turn.
3. Let a `GuardChain` evaluate inbound content and tool approval requests.
4. Send the Turn through an `AgentHarness`.
5. Listen for `BridgeEvent` values such as `DeltaEvent` and `ToolUseEvent`.
6. Persist messages, metadata, usage, and any application state your host needs.

## Harnesses

`AgentHarness` is the common contract for provider-specific workers. `ClaudeCodeHarness` wraps the native `claude` binary; `CodexHarness` wraps Codex's app-server protocol. Both start the worker process, send turns over the provider control protocol, and expose typed stream events. Hosts are responsible for calling `start()` before the first turn and `dispose()` during shutdown.

Use a harness directly for small tools and examples. Larger hosts usually construct harnesses through a factory or pool so they can share provider config, guard chains, and worker lifecycle policy.

## Turns and Events

A Turn is one round of user input, agent reasoning, tool use, and response streaming. `turn()` accepts a `sessionId`, message list, and system prompt, then returns metadata such as stop reason and usage.

Text streams before the final result. Subscribe to `harness.events` and handle the event types your host cares about:

- `DeltaEvent` streams assistant text.
- `ToolUseEvent` reports requested tools.
- `SystemInitEvent` reports provider initialization.

The event stream is the right place to update a terminal, send Server-Sent Events, append timeline records, or feed your own observability layer.

## Sessions and Messages

`SessionService` and `MessageService` are file-backed primitives for hosts that want SDK-managed session state without adopting the full reference server. `SessionKey` gives deterministic routing keys for web, direct-message, group, cron, and task sessions.

For simple CLIs, a stable session key plus `MessageService.getMessages()` is enough to build a multi-turn history. For services, the same primitives let you separate user sessions, channel sessions, and background job sessions while keeping persistence in ordinary files.

## Guards

`Guard` is the policy extension point. A guard receives a `GuardContext` and returns a `GuardVerdict`:

- `GuardPass` allows the action.
- `GuardWarn` allows the action and records a warning.
- `GuardBlock` denies the action.

`GuardChain` evaluates guards in order. The first block wins, warnings are preserved, and unexpected guard failures fail closed unless you explicitly opt into fail-open behavior. The guard chain can run before tool calls, when messages arrive, or before content is sent back to a user.

## Storage and Memory

`dartclaw_core` stays sqlite3-free and provides file-backed session, message, key-value, and memory-file services. `dartclaw_storage` adds SQLite-backed memory search, pruning, and repository implementations. Most consumers start with the `dartclaw` umbrella package and split to `dartclaw_core` plus their own storage only when they need a smaller dependency graph or a custom persistence backend.

## Context Engine and MCP

The reference server exposes MCP tools through its in-process MCP server. The `dartclaw_server` package also includes
an outbound MCP client for hosts that consume configured external MCP servers. Servers are configured by name, and the
pool applies guard, audit, and per-server governance checks before external `tools/call` dispatch. SDK consumers can
study or reuse the server-side types exported by `dartclaw_server` for the outbound client and tool models.

`context_research` is the built-in Context Engine synthesis tool. It retrieves across memory search, temporal KG facts,
and wiki/source documents, then returns a compact citation packet. The tool is registered as an `McpTool` by the
reference server, and the packet model preserves source references so UI and agent consumers can distinguish cited
statements from unattributed fallback snippets. Synthesized packets are never cached.

## Channels

`Channel` and `ChannelManager` model external messaging platforms. Channel packages such as `dartclaw_whatsapp`, `dartclaw_signal`, and `dartclaw_google_chat` adapt specific platforms into the shared channel message and response types. If you are building a web app or service, you can use the harness/session/guard pieces without any channel package.

## Reference Implementations

`dartclaw_server` and `dartclaw_cli` show how to compose the SDK into a complete HTTP API, HTMX web UI, operational CLI, task runtime, and deployment workflow. Treat them as working reference implementations. They are not required to use the SDK, and they are intentionally larger than the runnable SDK examples.

## Where To Go Next

- [Architecture](architecture.md) explains the 2-layer model, package graph, and extension seams.
- [Security](security.md) explains guard chains, isolation, credentials, and audit expectations.
- [custom_guard](../../examples/sdk/custom_guard/) shows a minimal guard extension.
- [multi_turn_cli](../../examples/sdk/multi_turn_cli/) shows session-backed conversation history.
- [shelf_server](../../examples/sdk/shelf_server/) shows a minimal HTTP host.
