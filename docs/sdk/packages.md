# Package Guide

**SDK Guide** | [User Guide](../guide/getting-started.md) | [API Reference](https://pub.dev/documentation/dartclaw/latest/) | [Examples](../../examples/sdk/)

> **Pre-publication preview**: These docs reflect the upcoming 0.9.0 release. Until 0.9.0 is published to pub.dev, use `dependency_overrides` to reference local workspace packages. The [runnable example](../../examples/sdk/single_turn_cli/) shows the current local-workspace setup.

DartClaw is a pub workspace of composable packages. Most consumers should start with the `dartclaw` umbrella package, then drop to individual packages only when they need tighter control over dependencies, platform support, or extension points.

## Package Table

| Package | Description | Key Types | When to Use | sqlite3 | pub.dev status |
| --- | --- | --- | --- | --- | --- |
| `dartclaw` | Umbrella package re-exporting the public SDK surface | `ClaudeCodeHarness`, `HarnessConfig`, `Channel`, `BridgeEvent`, `MemoryService` | Default choice for CLI apps and servers that want the full SDK | Yes, via `dartclaw_storage` | `0.9.0 pending` |
| `dartclaw_core` | sqlite3-free core runtime primitives | `AgentHarness`, `ClaudeCodeHarness`, `Channel`, `BridgeEvent`, `EventBus` | Flutter desktop, custom storage, or environments where native sqlite3 is a problem | No | `0.9.0 pending` |
| `dartclaw_models` | Zero-dependency shared data types | `Session`, `Message`, `SessionKey`, `MemoryChunk` | Shared contracts, serialization, thin client/server packages | No | `0.9.0 pending` |
| `dartclaw_storage` | SQLite-backed persistence and search | `MemoryService`, `Fts5SearchBackend`, `QmdSearchBackend`, `MemoryPruner` | Storage-only consumers, or apps adding search, memory, and SQLite repositories to a core-only setup | Yes | `0.9.0 pending` |
| `dartclaw_security` | Guard framework and security helpers | `Guard`, `GuardChain`, `CommandGuard`, `FileGuard` | Custom guards, policy plugins, or guard-only consumers | No | `0.9.0 pending` |
| `dartclaw_whatsapp` | WhatsApp channel integration via GOWA | `WhatsAppChannel`, `WhatsAppConfig`, `GowaManager` | Add WhatsApp ingress/egress to a DartClaw app | No | `0.9.0 pending` |
| `dartclaw_signal` | Signal channel integration via `signal-cli` | `SignalChannel`, `SignalConfig`, `SignalCliManager` | Add Signal support without pulling in other channels | No | `0.9.0 pending` |
| `dartclaw_google_chat` | Google Chat channel integration | `GoogleChatChannel`, `GoogleChatConfig`, `GoogleChatRestClient` | Add Google Chat support to an existing host | No | `0.9.0 pending` |
| `dartclaw_server` | Reference HTTP server and HTMX web UI | `DartclawServer` | Study, fork, or deploy the built-in server architecture | Yes | `Repo-only reference implementation` |
| `dartclaw_cli` | Reference CLI application in `apps/` | Executable app | Study or fork the operational CLI commands | Yes | `Repo-only reference implementation` |

## Dependency Graph

```text
dartclaw
├─ dartclaw_core
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

dartclaw_server
├─ dartclaw_core
├─ dartclaw_storage
├─ dartclaw_security
├─ dartclaw_whatsapp
├─ dartclaw_signal
└─ dartclaw_google_chat

dartclaw_cli
├─ dartclaw_core
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
| Use SQLite-backed memory, search, and repositories from an existing host | `dartclaw_storage` |
| Write a custom guard or security plugin | `dartclaw_security` |
| Add SQLite-backed search and memory to a core-only app | `dartclaw_core` + `dartclaw_storage` |
| Add WhatsApp, Signal, or Google Chat | `dartclaw_core` + the relevant channel package |
| Deploy the reference server as-is | [User Guide](../guide/getting-started.md) |
| Fork the reference server as a starting point | Clone the repo and modify `dartclaw_server` / `dartclaw_cli` |

## Umbrella vs Individual Packages

Use `dartclaw` when you want the shortest path to a working agent. It is the convenience import and gives you harness, storage, guards, and channel packages through one dependency.

Use individual packages when footprint matters. `dartclaw_core` is the important split point: it stays sqlite3-free, so it is the right base for Flutter desktop and any runtime where you want to supply your own persistence layer. Add `dartclaw_storage`, `dartclaw_security`, or a channel package only when your app actually needs that capability.

`dartclaw_server` and `dartclaw_cli` are repo-only reference implementations. They live in this workspace for study, forking, and deployment, but they are not packages you can install with `dart pub add`.
