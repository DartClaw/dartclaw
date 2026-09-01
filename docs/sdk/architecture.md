# Architecture For SDK Consumers

**SDK Guide** | [Quick Start](quick-start.md) | [Concepts](concepts.md) | [Security](security.md) | [Package Guide](packages.md)

There are two places you can stand relative to a DartClaw runtime, and the whole SDK architecture follows from which one you pick.

## The Tier Boundary

```text
Tier 1 — your app                         package:dartclaw / dartclaw_client
  DartclawApiClient, DTOs
        |
        | HTTP + SSE, bearer token
        v
dartclaw serve  ──────────────────────────── the tier boundary
        |
Tier 2 — the runtime                      dartclaw_core, _security, _storage
  AgentHarness, GuardChain, sessions, storage, channels, events
        |
        | provider control protocol (JSONL)
        v
Native agent binary
  model reasoning, provider tool protocol, streamed output
```

Tier 1 consumers cross the top boundary only. Tier 2 consumers replace `dartclaw serve` with their own composition and own both lower layers.

## Tier 1: Client-Side Architecture

The client tier is intentionally small enough to describe in a paragraph. `DartclawApiClient` builds an `ApiRequest` (method, resolved URI, headers, encoded body), hands it to an `ApiTransport`, and decodes the `ApiResponse`. `ApiTransport` is the only seam. The default implementation is `dart:io`-based; the package declares no other dependency, which is what lets it drop into a Flutter app, a `dart compile exe` binary, or a test harness without dragging a runtime behind it.

Consumer responsibilities:

- **Resolving a base URI and a token.** The client does not read config files, environment variables, or a DartClaw data directory. `apps/dartclaw_cli/lib/src/commands/connected_command_support.dart` shows how the CLI resolves both from `DartclawConfig` plus `--server`/`--token`, and is the pattern to copy.
- **Choosing a reconnect policy** for `streamEvents`, via `onDisconnect`, `maxReconnects` and `reconnectDelays`.
- **Handling `DartclawApiException`.** The CLI's universal policy — print `error.message`, exit 1 — is in `ConnectedCommand.runConnected`.
- **Interpreting the JSON.** Responses are maps and lists. Type them in your own code if you want typed models.

The endpoints themselves are the contract, documented in [Web UI and API](../guide/web-ui-and-api.md). They are versioned by the server, not by this package.

## Tier 2: Runtime Architecture

The runtime tier is the host/worker split. Your Dart code is the host; the native agent binary is the worker. The packages provide the contracts and default implementations that keep that split predictable.

### Host Responsibilities

- Provider selection and harness lifecycle.
- Guard-chain construction and policy configuration.
- Session and message persistence.
- Message history assembly for each Turn.
- Streaming event fan-out to a terminal, HTTP response, channel, or UI.
- Shutdown and cleanup.
- Credential and environment handling.

`dartclaw_runtime` is one composition of these. A small CLI constructing `ClaudeCodeHarness` directly is another.

### Harness Seam

`AgentHarness` is the provider boundary: `ClaudeCodeHarness`, `CodexHarness`, `AcpHarness`, `HarnessFactory` and their configuration types. Harnesses expose `start()`/`dispose()` for lifecycle, `turn()` for a single Turn, `events` for streamed `BridgeEvent` values, and capability metadata for provider differences. Application code consumes `BridgeEvent` and `GuardVerdict` rather than parsing provider wire data itself.

### Storage Seam

`dartclaw_core` owns both file-backed session services and the default SQLite-backed memory search, pruning, and repository implementations. Keeping their shared aggregate hydration and row mapping together gives persistence one authority.

### Event Seam

`BridgeEvent` values come from the harness stream and represent provider output. `DartclawEvent` and `EventBus` are host-level runtime events. A host that serves tier-1 consumers translates both into the SSE frames those consumers read.

### Channel Seam

Channels normalize external messaging platforms into shared `ChannelMessage` and `ChannelResponse` shapes. Use a channel package when your host needs WhatsApp, Signal, or Google Chat; skip them for ordinary CLIs, web services, and embedded flows.

### Extension Seams

- Custom `Guard` implementations for application-specific policy.
- Custom host routing around `AgentHarness.turn()`.
- Session-key strategy with `SessionKey` factories.
- Event subscribers on harness events or the host `EventBus`.
- Channel integrations through `Channel`.
- Storage composition through `dartclaw_core` services and repositories.

Each seam is usable without cloning the reference server — but the runtime tier as a whole is unpublished, so using any of them means depending on a checkout.

## Choosing A Tier

Cross the boundary at tier 1 when the runtime can be a separate process. That is nearly always: `dartclaw serve` is a supported deployment, the wire contract is stable, your dependency graph stays at one zero-dependency package, and upgrades are a server restart rather than a recompile.

Drop to tier 2 when the runtime genuinely cannot be a separate process — a single-binary distribution, an offline desktop app, an embedded host with no room for a service. Then fork, pin to a commit, and expect to carry the merge cost across milestones.

## Reference Implementations

- `dartclaw_runtime` composes HTTP routes, HTMX pages, sessions, tasks, storage, guards, and channels — the server side of the tier boundary.
- `dartclaw_cli` composes operational commands and server startup on the runtime tier, *and* all its connected command families on the client tier. It is the best worked example of both sides.
