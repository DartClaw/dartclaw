# Package Guide

**SDK Guide** | [Quick Start](quick-start.md) | [Concepts](concepts.md) | [Architecture](architecture.md) | [Security](security.md) | [User Guide](../guide/getting-started.md) | [API Reference](https://pub.dev/documentation/dartclaw/latest/) | [Examples](../../examples/sdk/)

> **Status**: DartClaw is not yet published to pub.dev. Until it is, use `dependency_overrides` to reference local workspace packages. The [runnable example](../../examples/sdk/single_turn_cli/) shows the current local-workspace setup. See [ADR-008](../../dev/adrs/008-sdk-publishing-strategy.md) for the publishing strategy.

DartClaw is a pub workspace of composable packages. Most consumers should start with the `dartclaw` umbrella package, then drop to individual packages only when they need tighter control over dependencies, platform support, or extension points.

## Package Table

| Package | Description | Key Types | When to Use | sqlite3 | pub.dev status |
| --- | --- | --- | --- | --- | --- |
| `dartclaw` | Umbrella package re-exporting the main SDK surface | `ClaudeCodeHarness`, `CodexHarness`, `HarnessConfig`, `Channel`, `BridgeEvent`, `MemoryService` | Default choice for apps that want the core runtime plus storage and channel integrations | Yes, via `dartclaw_storage` | `Not yet published`[^adr008] |
| `dartclaw_models` | Shared data types and small cross-package enums/config DTOs | `Session`, `Message`, `SessionKey`, `ChannelType`, `TaskType` | Shared contracts, serialization, thin client/server packages | No | `Not yet published`[^adr008] |
| `dartclaw_security` | Guard framework and security helpers | `Guard`, `GuardChain`, `CommandGuard`, `FileGuard` | Custom guards, policy plugins, or guard-only consumers | No | `Not yet published`[^adr008] |
| `dartclaw_config` | Typed config loading, metadata, validation, and authoring helpers | `DartclawConfig`, `ConfigMeta`, `ConfigValidator`, `ConfigWriter` | Hosts and tools that need to load, inspect, validate, or rewrite DartClaw config | No | `Repo-only support package` |
| `dartclaw_core` | sqlite3-free runtime primitives | `AgentHarness`, `ClaudeCodeHarness`, `CodexHarness`, `Channel`, `BridgeEvent`, `EventBus` | Flutter desktop, custom storage, or environments where native sqlite3 is a problem | No | `Not yet published`[^adr008] |
| `dartclaw_storage` | SQLite-backed persistence and search | `MemoryService`, `Fts5SearchBackend`, `QmdSearchBackend`, `MemoryPruner` | Storage-only consumers, or apps adding search, memory, and SQLite repositories to a core-only setup | Yes | `Not yet published`[^adr008] |
| `dartclaw_workflow` | Workflow definition, registry, validation, and execution package | `WorkflowService`, `WorkflowExecutor`, `WorkflowDefinitionParser`, `WorkflowDefinitionValidator` | Hosts that need built-in or custom multi-step workflows without pulling in the web server | No | `Repo-only support package` |
| `dartclaw_whatsapp` | WhatsApp channel integration via GOWA | `WhatsAppChannel`, `WhatsAppConfig`, `GowaManager` | Add WhatsApp ingress/egress to a DartClaw app | No | `Not yet published`[^adr008] |
| `dartclaw_signal` | Signal channel integration via `signal-cli` | `SignalChannel`, `SignalConfig`, `SignalCliManager` | Add Signal support without pulling in other channels | No | `Not yet published`[^adr008] |
| `dartclaw_google_chat` | Google Chat channel integration | `GoogleChatChannel`, `GoogleChatConfig`, `GoogleChatRestClient` | Add Google Chat support to an existing host | No | `Not yet published`[^adr008] |
| `dartclaw_testing` | Shared test doubles and in-memory helpers for workspace packages | `FakeAgentHarness`, `FakeTurnManager`, `InMemorySessionService`, `TestEventBus` | Workspace tests, package integration tests, or downstream forks mirroring DartClaw internals | No | `Repo-only support package` |
| `dartclaw_server` | Reference HTTP server, HTMX web UI, MCP tools, and outbound MCP client | `DartclawServer`, `ContextResearchTool`, `CitationPacket`, `OutboundMcpPool` | Study, fork, or deploy the built-in server architecture; inspect `context_research` and outbound-MCP reference implementations | Yes | `Repo-only reference implementation` |
| `dartclaw_cli` | Reference CLI application in `apps/` | Executable app | Study or fork the operational CLI commands | Yes | `Repo-only reference implementation` |

[^adr008]: No packages are published to pub.dev yet. See [ADR-008](../../dev/adrs/008-sdk-publishing-strategy.md) for the publishing strategy and the `dartclaw` umbrella namespace plan. Packages marked "Not yet published" are intended for publication; "Repo-only" packages are support/reference code not planned for pub.dev.

## Dependency Graph

```text
dartclaw
├─ dartclaw_core
│  ├─ dartclaw_config
│  │  ├─ dartclaw_models
│  │  └─ dartclaw_security
│  │     └─ dartclaw_models
│  ├─ dartclaw_models
│  └─ dartclaw_security
├─ dartclaw_storage
│  ├─ dartclaw_config
│  ├─ dartclaw_core
│  └─ dartclaw_workflow
├─ dartclaw_whatsapp
│  ├─ dartclaw_config
│  └─ dartclaw_core
├─ dartclaw_signal
│  ├─ dartclaw_config
│  └─ dartclaw_core
└─ dartclaw_google_chat
   ├─ dartclaw_config
   └─ dartclaw_core

dartclaw_workflow
├─ dartclaw_config
├─ dartclaw_core
├─ dartclaw_models
└─ dartclaw_security

dartclaw_server
├─ dartclaw_config
├─ dartclaw_core
├─ dartclaw_models
├─ dartclaw_workflow
├─ dartclaw_storage
├─ dartclaw_security
├─ dartclaw_whatsapp
├─ dartclaw_signal
└─ dartclaw_google_chat

dartclaw_testing
├─ dartclaw_config
├─ dartclaw_core
├─ dartclaw_google_chat
├─ dartclaw_models
├─ dartclaw_security
└─ dartclaw_workflow

dartclaw_cli
├─ dartclaw_config
├─ dartclaw_core
├─ dartclaw_workflow
├─ dartclaw_security
├─ dartclaw_storage
├─ dartclaw_server
├─ dartclaw_whatsapp
├─ dartclaw_signal
└─ dartclaw_google_chat
```

## Which Package Do I Need?

| I want to... | Depend on |
| --- | --- |
| Build a CLI agent with full features | `dartclaw` |
| Embed an agent in a Flutter desktop app | `dartclaw_core` |
| Share session and message types between packages | `dartclaw_models` |
| Load or validate DartClaw config from tooling | `dartclaw_config` |
| Use SQLite-backed memory, search, and repositories from an existing host | `dartclaw_storage` |
| Run built-in or custom workflows from a host app | `dartclaw_workflow` |
| Write a custom guard or security plugin | `dartclaw_security` |
| Add SQLite-backed search and memory to a core-only app | `dartclaw_core` + `dartclaw_storage` |
| Add WhatsApp, Signal, or Google Chat | `dartclaw_core` + the relevant channel package |
| Deploy the reference server as-is | [User Guide](../guide/getting-started.md) |
| Fork the reference server as a starting point | Clone the repo and modify `dartclaw_server` / `dartclaw_cli` |
| Inspect the `context_research` tool or outbound MCP reference runtime | `dartclaw_server` |

## Guides and Examples

After choosing a package, use these SDK-focused guides:

- [Quick Start](quick-start.md) for the smallest working harness snippets.
- [Core Concepts](concepts.md) for the SDK mental model: harnesses, turns, events, sessions, guards, storage, and channels.
- [Architecture](architecture.md) for the 2-layer model and extension seams.
- [Security](security.md) for guard chains, isolation expectations, credentials, and audit hooks.

Runnable local-workspace examples:

- [single_turn_cli](../../examples/sdk/single_turn_cli/README.md) for one prompt and streamed output.
- [custom_guard](../../examples/sdk/custom_guard/README.md) for a custom `Guard`.
- [multi_turn_cli](../../examples/sdk/multi_turn_cli/README.md) for session-backed conversation history.
- [shelf_server](../../examples/sdk/shelf_server/README.md) for a minimal HTTP-hosted SDK integration.

## Umbrella vs Individual Packages

Use `dartclaw` when you want the shortest path to a working agent. It is the convenience import and gives you harness, storage, and channel packages through one dependency.

Use individual packages when footprint matters. `dartclaw_core` is the important split point: it stays sqlite3-free, so it is the right base for Flutter desktop and any runtime where you want to supply your own persistence layer. Add `dartclaw_storage`, `dartclaw_security`, a channel package, or `dartclaw_workflow` only when your app actually needs that capability. `dartclaw_config` is the companion package for config loading and authoring, rather than part of the runtime core.

`dartclaw_server` and `dartclaw_cli` are repo-only reference implementations. They live in this workspace for study, forking, and deployment, but they are not packages you can install with `dart pub add`.
