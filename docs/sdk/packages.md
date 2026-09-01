# Package Guide

**SDK Guide** | [Quick Start](quick-start.md) | [Concepts](concepts.md) | [Architecture](architecture.md) | [Security](security.md) | [User Guide](../guide/getting-started.md) | [Examples](../../examples/sdk/)

DartClaw offers two tiers. Which one you need is the first decision, and it is not a close call for most consumers.

| | Tier 1 — build on a running server | Tier 2 — fork the runtime |
| --- | --- | --- |
| What you depend on | `dartclaw` (umbrella) or `dartclaw_client` | `dartclaw_core`, `dartclaw_kernel`, channel packages |
| What you get | The server's HTTP API and SSE streams, plus the DTO types they carry | The harness, guard chain, sessions, storage, and channels in your own process |
| What you run | A `dartclaw serve` you already operate | Your own composition of the runtime |
| Publication intent | Planned, first wave ([ADR-008](../../dev/adrs/008-sdk-publishing-strategy.md)) | Deferred — no publication, no compatibility promise |
| Native `sqlite3` | No | Yes, through `dartclaw_core` |

Start with tier 1. Reach for tier 2 only when you genuinely need the runtime in your own process, and accept that you are forking: clone the repository, depend by path, and expect breaking changes between milestones.

> **Status**: no DartClaw package is on pub.dev yet. Depend on the client tier via a git-pinned dependency; use `dependency_overrides` against a local checkout for the runtime tier. The [runnable examples](../../examples/sdk/) show the local-workspace setup.

## Tier 1: The Client Tier

| Package | Description | Key Types | When to Use | Publication intent |
| --- | --- | --- | --- | --- |
| `dartclaw` | Umbrella for the client tier — re-exports `dartclaw_client` and the kernel's DTO subset | `DartclawApiClient`, `DartclawApiException`, `Session`, `Message` | Default choice for talking to a running server | Planned, first wave |
| `dartclaw_client` | HTTP and SSE transport. Zero dependencies — no DartClaw package, nothing from pub | `DartclawApiClient`, `ApiTransport`, `ApiRequest`, `ApiResponse`, `DartclawApiException` | You want the client without the DTO types | Planned, first wave |
| `dartclaw_kernel` | Shared data, typed configuration, guard contracts, and deterministic utilities | `Session`, `Message`, `DartclawConfig`, `GuardChain` | You need contracts without runtime or storage machinery | Planned, first wave |

The client tier never opens a DartClaw data directory, reads a config file, or spawns a process. Construction takes a base URI and an explicit bearer token; resolving that token is the composing application's job. See [Security](security.md#token-handling-client-tier).

## Tier 2: Fork The Runtime

| Package | Description | Key Types | When to Use | `sqlite3` | Publication intent |
| --- | --- | --- | --- | --- | --- |
| `dartclaw_core` | Runtime primitives, SQLite persistence, and search | `AgentHarness`, `Channel`, `MemoryService`, `Fts5SearchBackend`, `SqliteTaskRepository` | The base of any in-process runtime | Yes | Deferred |
| `dartclaw_whatsapp` | WhatsApp channel integration via GOWA | `WhatsAppChannel`, `WhatsAppConfig`, `GowaManager` | WhatsApp ingress/egress in your own runtime | No | Deferred |
| `dartclaw_signal` | Signal channel integration via `signal-cli` | `SignalChannel`, `SignalConfig`, `SignalCliManager` | Signal support in your own runtime | No | Deferred |
| `dartclaw_google_chat` | Google Chat channel integration | `GoogleChatChannel`, `GoogleChatConfig`, `GoogleChatRestClient` | Google Chat support in your own runtime | No | Deferred |
| `dartclaw_workflow` | Workflow definition, registry, validation, and execution | `WorkflowService`, `WorkflowExecutor`, `WorkflowDefinitionParser` | Multi-step workflows without the web server | No | Undecided |
| `dartclaw_runtime` | Reference HTTP server, HTMX web UI, MCP tools, outbound MCP client | `DartclawServer`, `ContextResearchTool`, `CitationPacket`, `OutboundMcpPool` | Study, fork, or deploy the built-in server | Yes | Undecided |
| `dartclaw_cli` | Reference CLI application in `apps/` | Executable app | Study or fork the operational CLI commands | Yes | Repo-only (leaning) |
| `dartclaw_testing` | Shared test doubles and in-memory helpers | `FakeAgentHarness`, `InMemorySessionService` | Workspace tests, or forks mirroring DartClaw internals | No | Repo-only (leaning) |
| `dartclaw_bridge` | Framed stdio bridge protocol and the in-container loopback executable | Bridge protocol frames | Container isolation internals | No | Repo-only (leaning) |

Every intent in these two tables mirrors [ADR-008 § Client-tier-first publication](../../dev/adrs/008-sdk-publishing-strategy.md#client-tier-first-publication-2026-08-20). If they disagree, the ADR is the record and this page is the bug.

## Dependency Graph

Client tier:

```text
dartclaw
├─ dartclaw_client   (no dependencies)
└─ dartclaw_kernel
```

Runtime tier:

```text
dartclaw_core
└─ dartclaw_kernel

dartclaw_workflow
├─ dartclaw_core
└─ dartclaw_kernel

dartclaw_whatsapp / dartclaw_signal / dartclaw_google_chat
├─ dartclaw_core
└─ dartclaw_kernel

dartclaw_runtime
├─ dartclaw_bridge
├─ dartclaw_core
├─ dartclaw_kernel
├─ dartclaw_workflow
└─ dartclaw_google_chat, dartclaw_signal, dartclaw_whatsapp

dartclaw_cli
├─ dartclaw_acp
├─ dartclaw_client
├─ dartclaw_core
├─ dartclaw_kernel
├─ dartclaw_runtime
├─ dartclaw_workflow
└─ dartclaw_google_chat
```

## Which Package Do I Need?

| I want to... | Depend on |
| --- | --- |
| Drive a running DartClaw server from my app | `dartclaw` |
| Same, without the DTO types | `dartclaw_client` |
| Share session and message types between my own packages | `dartclaw_kernel` |
| Follow a workflow run or task live from my app | `dartclaw` (`streamEvents`) |
| Load or validate DartClaw config from tooling | `dartclaw_kernel` |
| Deploy the reference server as-is | [User Guide](../guide/getting-started.md) |
| Embed the harness in my own process | Fork the repo; `dartclaw_core` |
| Write a custom guard | Fork the repo; `dartclaw_kernel` |
| Add SQLite-backed memory and search to my own runtime | Fork the repo; `dartclaw_core` |
| Add WhatsApp, Signal, or Google Chat to my own runtime | Fork the repo; `dartclaw_core` + the channel package |
| Fork the reference server as a starting point | Clone the repo and modify `dartclaw_runtime` / `dartclaw_cli` |

## Guides and Examples

- [Quick Start](quick-start.md) — the smallest working program in each tier.
- [Core Concepts](concepts.md) — the mental model for both tiers.
- [Architecture](architecture.md) — where the tier boundary sits and what each side owns.
- [Security](security.md) — token handling for the client tier; guard chains and isolation for the runtime tier.

Runnable local-workspace projects, all fork-the-runtime tier:

- [single_turn_cli](../../examples/sdk/single_turn_cli/README.md) — one prompt and streamed output.
- [custom_guard](../../examples/sdk/custom_guard/README.md) — a custom `Guard`.
- [multi_turn_cli](../../examples/sdk/multi_turn_cli/README.md) — session-backed conversation history.
- [shelf_server](../../examples/sdk/shelf_server/README.md) — a minimal HTTP-hosted runtime.

The client-tier example is the umbrella package's own [`example/example.dart`](../../packages/dartclaw/example/example.dart).

## Why Only The Client Tier Ships

Embedding an agent runtime in a foreign process is a large surface to support: harness lifecycle, guard policy, storage layout, channel adapters, and a native `sqlite3` dependency. Talking to a runtime you already operate is a small one — a URL, a token, JSON, and SSE frames — and it is the surface that real consumers have actually asked for.

So the client tier gets a publication promise and the runtime tier gets a repository. There is deliberately no middle "embeddable runtime" product; if you need one, fork, and open an issue describing what you needed. See [ADR-008](../../dev/adrs/008-sdk-publishing-strategy.md#client-tier-first-publication-2026-08-20).
