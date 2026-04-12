# Package Guide

**SDK Guide** | [User Guide](../guide/getting-started.md) | [API Reference](https://pub.dev/documentation/dartclaw/latest/) | [Examples](../../examples/sdk/)

> **Pre-publication preview**: These docs reflect the upcoming 0.9.0 release. Until 0.9.0 is published to pub.dev, use `dependency_overrides` to reference local workspace packages. The [runnable example](../../examples/sdk/single_turn_cli/) shows the current local-workspace setup.

DartClaw is a pub workspace of composable packages. Most consumers should start with the `dartclaw` umbrella package, then drop to individual packages only when they need tighter control over dependencies, platform support, or extension points.

## Package Table

| Package | Description | Key Types | When to Use | sqlite3 | pub.dev status |
| --- | --- | --- | --- | --- | --- |
| `dartclaw` | Umbrella package re-exporting the main SDK surface | `ClaudeCodeHarness`, `HarnessConfig`, `Channel`, `BridgeEvent`, `MemoryService` | Default choice for apps that want the core runtime plus storage and channel integrations | Yes, via `dartclaw_storage` | `0.9.0 pending` |
| `dartclaw_models` | Shared data types and small cross-package enums/config DTOs | `Session`, `Message`, `SessionKey`, `ChannelType`, `TaskType` | Shared contracts, serialization, thin client/server packages | No | `0.9.0 pending` |
| `dartclaw_security` | Guard framework and security helpers | `Guard`, `GuardChain`, `CommandGuard`, `FileGuard` | Custom guards, policy plugins, or guard-only consumers | No | `0.9.0 pending` |
| `dartclaw_config` | Typed config loading, metadata, validation, and authoring helpers | `DartclawConfig`, `ConfigMeta`, `ConfigValidator`, `ConfigWriter` | Hosts and tools that need to load, inspect, validate, or rewrite DartClaw config | No | `Repo-only support package` |
| `dartclaw_core` | sqlite3-free runtime primitives | `AgentHarness`, `ClaudeCodeHarness`, `Channel`, `BridgeEvent`, `EventBus` | Flutter desktop, custom storage, or environments where native sqlite3 is a problem | No | `0.9.0 pending` |
| `dartclaw_storage` | SQLite-backed persistence and search | `MemoryService`, `Fts5SearchBackend`, `QmdSearchBackend`, `MemoryPruner` | Storage-only consumers, or apps adding search, memory, and SQLite repositories to a core-only setup | Yes | `0.9.0 pending` |
| `dartclaw_workflow` | Workflow definition, registry, validation, and execution package | `WorkflowService`, `WorkflowExecutor`, `WorkflowDefinitionParser`, `WorkflowDefinitionValidator` | Hosts that need built-in or custom multi-step workflows without pulling in the web server | Yes, via `dartclaw_storage` | `Repo-only support package` |
| `dartclaw_whatsapp` | WhatsApp channel integration via GOWA | `WhatsAppChannel`, `WhatsAppConfig`, `GowaManager` | Add WhatsApp ingress/egress to a DartClaw app | No | `0.9.0 pending` |
| `dartclaw_signal` | Signal channel integration via `signal-cli` | `SignalChannel`, `SignalConfig`, `SignalCliManager` | Add Signal support without pulling in other channels | No | `0.9.0 pending` |
| `dartclaw_google_chat` | Google Chat channel integration | `GoogleChatChannel`, `GoogleChatConfig`, `GoogleChatRestClient` | Add Google Chat support to an existing host | No | `0.9.0 pending` |
| `dartclaw_testing` | Shared test doubles and in-memory helpers for workspace packages | `FakeAgentHarness`, `FakeTurnManager`, `InMemorySessionService`, `TestEventBus` | Workspace tests, package integration tests, or downstream forks mirroring DartClaw internals | No | `Repo-only support package` |
| `dartclaw_server` | Reference HTTP server and HTMX web UI | `DartclawServer` | Study, fork, or deploy the built-in server architecture | Yes | `Repo-only reference implementation` |
| `dartclaw_cli` | Reference CLI application in `apps/` | Executable app | Study or fork the operational CLI commands | Yes | `Repo-only reference implementation` |

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
│  └─ dartclaw_core
├─ dartclaw_whatsapp
│  └─ dartclaw_core
├─ dartclaw_signal
│  └─ dartclaw_core
└─ dartclaw_google_chat
   └─ dartclaw_core

dartclaw_workflow
├─ dartclaw_config
├─ dartclaw_core
├─ dartclaw_models
└─ dartclaw_storage

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
├─ dartclaw_core
├─ dartclaw_models
├─ dartclaw_security
├─ dartclaw_server
└─ dartclaw_google_chat

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

## Umbrella vs Individual Packages

Use `dartclaw` when you want the shortest path to a working agent. It is the convenience import and gives you harness, storage, and channel packages through one dependency.

Use individual packages when footprint matters. `dartclaw_core` is the important split point: it stays sqlite3-free, so it is the right base for Flutter desktop and any runtime where you want to supply your own persistence layer. Add `dartclaw_storage`, `dartclaw_security`, a channel package, or `dartclaw_workflow` only when your app actually needs that capability. `dartclaw_config` is the companion package for config loading and authoring, rather than part of the runtime core.

`dartclaw_server` and `dartclaw_cli` are repo-only reference implementations. They live in this workspace for study, forking, and deployment, but they are not packages you can install with `dart pub add`.
