# Architecture For SDK Consumers

**SDK Guide** | [Quick Start](quick-start.md) | [Concepts](concepts.md) | [Security](security.md) | [Package Guide](packages.md)

DartClaw's SDK architecture is built around a small host/runtime split. Your Dart code is the host. The native agent binary is the worker. The SDK packages provide the contracts and default implementations needed to keep that split predictable.

## 2-Layer Model

```text
Dart host
  AgentHarness, GuardChain, sessions, storage, channels, events
        |
        | JSONL control protocol
        v
Native agent binary
  model reasoning, provider tool protocol, streamed output
```

The Dart host decides what work may happen, where state is stored, which session a Turn belongs to, and how streamed events reach users. The native binary performs model reasoning and reports events back through the protocol adapter.

## Host Responsibilities

An SDK host normally owns:

- Provider selection and harness lifecycle.
- Guard-chain construction and policy configuration.
- Session and message persistence.
- Message history assembly for each Turn.
- Streaming event fan-out to a terminal, HTTP response, channel, or UI.
- Shutdown and cleanup.
- Credential and environment handling.

The SDK does not force you to deploy the reference server. A small CLI can construct `ClaudeCodeHarness` directly. A service can embed a harness behind its own HTTP routes. A larger runtime can adopt the same session and guard primitives used by `dartclaw_server`.

## Harness Seam

`AgentHarness` is the provider boundary. The current SDK surface includes `ClaudeCodeHarness`, `CodexHarness`, `HarnessFactory`, and related configuration types. The runnable examples use Claude because that is the shortest documented path today, but SDK hosts should keep provider-specific choices behind this seam. Harnesses expose:

- `start()` and `dispose()` for lifecycle.
- `turn()` for a single Turn.
- `events` for streamed `BridgeEvent` values.
- Capability flags and metadata for provider differences.

Application code should consume `BridgeEvent` and `GuardVerdict` rather than parsing provider wire data itself.

## Storage Seam

Use `SessionService` and `MessageService` when file-backed sessions are enough. Add `dartclaw_storage` when you want SQLite-backed memory search, pruning, and repository implementations.

The package split is intentional:

- `dartclaw_core` has no sqlite3 dependency and fits lightweight hosts.
- `dartclaw_storage` owns SQLite-backed persistence and search.
- `dartclaw` re-exports the common SDK surface for consumers who want one dependency.

## Event Seam

`BridgeEvent` values come from the harness stream and represent provider output. `DartclawEvent` and `EventBus` are host-level runtime events. Small examples can listen to the harness directly. Larger hosts can translate important events into their own observability or notification layer.

## Channel Seam

Channels are optional. They normalize external messaging platforms into shared `ChannelMessage` and `ChannelResponse` shapes. Use channel packages when your host needs WhatsApp, Signal, or Google Chat. Skip them for ordinary CLIs, web services, and embedded application flows.

## Reference Implementations

`dartclaw_server` and `dartclaw_cli` are complete reference implementations built on the SDK packages:

- `dartclaw_server` composes HTTP routes, HTMX pages, sessions, tasks, storage, guards, and channels.
- `dartclaw_cli` composes operational commands, server startup, workflow commands, deployment helpers, and maintenance tools.

Study those packages when you need production-sized wiring examples. Start from the runnable SDK examples when you need a small extension point in isolation.

## Extension Seams

Common first extension points are:

- Custom `Guard` implementations for application-specific policy.
- Custom host routing around `AgentHarness.turn()`.
- Session-key strategy with `SessionKey` factories.
- Event subscribers on harness events or the host `EventBus`.
- Channel integrations through `Channel` when a messaging platform is in scope.
- Storage composition through `dartclaw_core` services or `dartclaw_storage` repositories.

Each seam is usable without cloning the reference server.
