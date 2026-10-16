# DartClaw System Architecture Overview

The map of the whole system: the two-layer runtime model, the subsystems and where they live in code, the package
topology, the deployment model and the service wiring that assembles it. It stays an overview. Each subsystem's design,
invariants and failure modes live in the document named for it in the [Subsystem Index](#subsystem-index), and this
document owns only package topology, tier order, the composition root, service wiring and the deployment model.

**Current through**: 0.28.0

---

## Design Principles

| Principle | Meaning |
|-----------|---------|
| **Minimal attack surface** | No Node.js or npm in the chain. Few dependencies; prefer the Dart standard library over third-party packages |
| **Dart as host** | AOT-compiled native binary with the formatter, analyzer, linter and test runner built in |
| **Direct control protocol** | Dart spawns the provider binaries (`claude`, `codex`, ACP agents) itself, with no intermediate runtime. State, storage and security stay in Dart |
| **Outpost pattern** | Purpose-built CLI tools in the best language for the job (GOWA in Go for WhatsApp, `signal-cli` for Signal), driven as subprocesses with structured I/O |
| **Auditable** | Dependency direction, per-package `lib/` size targets and the package count are enforced mechanically ([Architecture Governance](architecture-governance.md), [ADR-033](../adrs/033-architectural-governance-via-fitness-functions.md)) |

Product-level philosophy and scale: [PRODUCT.md](../state/PRODUCT.md). Two rules bind every subsystem: model-first
delegation and one authority per concern ([ADR-054](../adrs/054-model-first-delegation-and-one-authority-per-concern.md)).

---

## System Overview

DartClaw is a **2-layer agent runtime**. The Dart host is the control plane and is fully trusted. The provider binaries
(`claude`, `codex`, configured ACP agents) are the execution plane, each with a provider-specific security boundary.
Claude and Codex run in a container or on the host; ACP agents run on the host only. The two layers talk over the provider
control protocol on stdio.

Claude uses bidirectional JSONL, Codex uses JSON-RPC over JSONL, and ACP agents use stdio JSON-RPC. The wire formats,
spawn flags and turn lifecycle are in [Control Protocol & Harness Architecture](control-protocol.md). The 2-layer
decision, and the reverse-engineering of the Claude protocol it rests on, is
[ADR-001](../adrs/001-sdk-integration-and-security-architecture.md).

The host is built on Dart (AOT via `dart build cli`), `shelf` for HTTP, Trellis templates with vendored HTMX for the web
UI, `postgres` for the server database, and `llamadart` for optional in-process embeddings. Versions stay in each
package's `pubspec.yaml` and the workspace `pubspec.lock`; vendored frontend assets are listed in
`packages/dartclaw_runtime/lib/src/static/VENDORS.md`.

| Concern | Layer 1 (host) | Layer 2 (providers) |
|---------|----------------|---------------------|
| State | Sessions, messages, memory, tasks, workflow runs, config, audit | Provider-side conversation continuity only, which the host can reset |
| Security | Guard chain, container orchestration, host gateway, audit | Tool execution inside the active provider boundary |
| Networking | HTTP server, SSE, channel ingress, MCP endpoint | Container executions have no network of their own and reach one upstream through the host gateway |
| Agent logic | Turn orchestration, prompt composition, hook and reverse-call evaluation, admission and governance | LLM reasoning, tool selection and execution |
| Credentials | Holds every credential. Container executions never receive one; host executions receive only their provider-scoped credential | Receives only what its provider family needs |

Credential isolation and the container boundary are in [Security Architecture](security-architecture.md).

### Platform Capability Surface

`PlatformCapabilities` (`packages/dartclaw_kernel/lib/src/platform_capabilities.dart`, [ADR-049](../adrs/049-typed-platform-capability-surface.md))
is the one place that answers operating-system questions: home directory (`HOME`, then `USERPROFILE`), executable
search candidates from `PATH`/`PATHEXT` (never the current directory), trusted Windows system-helper paths, Bash shell
policy, POSIX signal and file-permission availability, process-termination semantics and container-isolation
availability. `UnsupportedCapabilityError` names the capability, the attempted context and a remediation. The value is
policy only. Callers keep subprocess I/O, lookup and their own remediation text.

| Area | Native Windows behaviour |
|---|---|
| Process lifecycle | Hard termination of the directly managed process (`ProcessTerminationSemantics.hardTerminate`), with no SIGTERM-then-SIGKILL escalation |
| Config reload | `gateway.reload.mode: auto` (debounced file watch) works. `signal` (`SIGUSR1`, the default) is POSIX-only |
| Bash workflow steps | Git Bash is required (`BashShellPolicy.gitBashRequired`). Its absence fails the step with an `UnsupportedCapabilityError` message |
| Container isolation | Unavailable. `container.enabled: true` is startup-fatal; otherwise the host runs unisolated with a warning |

---

## Component Map

[![System architecture overview](diagrams/system-overview.svg)](diagrams/system-overview.svg)

Arrows show the main request path. Every subsystem persists through storage and publishes on the `EventBus`; the
provider binaries are the only processes outside the host apart from the channel sidecars.

### Subsystem Index

Paths are under `packages/` unless noted.

| Subsystem | Main components and where to look | Package | Design in |
|-----------|-----------------------------------|---------|-----------|
| Harness and protocols | `AgentHarness`, `HarnessFactory`, `ProtocolAdapter`, Claude and Codex harnesses (`dartclaw_core/lib/src/harness/`); `AcpHarness` (`dartclaw_acp/lib/src/`) | core, acp | [Control Protocol](control-protocol.md) |
| Turn orchestration | `TurnManager`, `TurnRunner`, `TurnLivenessTracker`, `ExecutionCoordinator` (`dartclaw_runtime/lib/src/`); contracts in `dartclaw_core/lib/src/turn/` | runtime | [Control Protocol](control-protocol.md), [Task & Execution](task-execution-architecture.md) |
| Sessions and conversations | `SessionService` (`dartclaw_core/lib/src/storage/`); `ConversationService`, `InboxService` (`dartclaw_runtime/lib/src/conversation/`), session locks (`.../concurrency/`) | core, runtime | [Session & State](session-state-architecture.md) |
| Event bus | `EventBus` and the sealed `DartclawEvent` hierarchy (`dartclaw_core/lib/src/events/`) | core | [Session & State](session-state-architecture.md) |
| Channels | `ChannelManager`, `ChannelTaskBridge`, `MessageQueue`, `ThreadBindingStore` (`dartclaw_core/lib/src/channel/`); adapters `dartclaw_whatsapp`, `dartclaw_signal`, `dartclaw_google_chat`, `dartclaw_slack`; `channel_wiring.dart` | core, channel packages, runtime | [Channel & Messaging](channel-messaging-architecture.md) |
| Tasks, worktrees, projects | `TaskService`, `TaskExecutor`, `TaskReviewService`, `WorktreeManager` (`dartclaw_runtime/lib/src/task/`); `ProjectService` interface in core, implementation in `.../project/` | runtime, core | [Task & Execution](task-execution-architecture.md) |
| Workflows | `WorkflowService`, `WorkflowExecutor`, `WorkflowRegistry`, parser and validator (`dartclaw_workflow/lib/src/workflow/`) | workflow | [Workflow Architecture](workflow-architecture.md) |
| Security and isolation | Guards, `GuardChain`, `MessageRedactor`, `GuardAuditLogger` (`dartclaw_kernel/lib/src/`); `ContainerManager`, `HostGateway` (`dartclaw_runtime/lib/src/container/`); `security_wiring.dart` | kernel, runtime | [Security Architecture](security-architecture.md) |
| Runtime governance | Rate limits, daily token budget, loop detection, turn limits, `/stop` `/pause` `/resume` (`dartclaw_runtime/lib/src/governance/`, `.../emergency/`, `turn_governance_enforcer.dart`) | kernel, runtime | [Security Architecture](security-architecture.md) |
| Configuration | `DartclawConfig`, `ConfigNotifier`, `Reconfigurable`, `ConfigMeta` (`dartclaw_kernel/lib/src/`); `ReloadTriggerService` (`apps/dartclaw_cli/lib/src/commands/`) | kernel, cli | [Configuration](configuration-architecture.md) |
| Persistence | Session, message and KV file services, `PostgresBackend`, `PostgresSchemaGate`, repositories (`dartclaw_core/lib/src/storage/`) | core | [Storage](#storage) below, [Data Model](data-model.md) |
| Observability | `ScheduleService` (`dartclaw_runtime/lib/src/scheduling/`), `AlertRouter` (`.../alerts/`), `UsageTracker`, `TurnTraceService`, `TaskEventRecorder`, health and SSE | runtime, core | [Observability & Operations](observability-operations-architecture.md) |
| HTTP API and CLI | Routes (`dartclaw_runtime/lib/src/api/`); `DartclawApiClient` (`dartclaw_client`); commands (`apps/dartclaw_cli/lib/src/commands/`) | runtime, client, cli | [CLI & API](cli-api-architecture.md) |
| Web UI | [Web UI](#web-ui) below | runtime | this document |
| MCP server | [MCP Server](#mcp-server) below | runtime | this document |
| Memory, search, knowledge | [Memory, Search and Context Research](#memory-search-and-context-research) below | core, search, runtime | this document, [Data Model](data-model.md) |

Bounded contexts and the relationships between them: [Context Map](context-map.md).

### Main Flows

| Flow | Path |
|------|------|
| **Web chat turn** | `POST /api/sessions/<id>/send` admits the message through `ConversationService.submit` (revision-checked; a busy session queues it and returns 202). The returned fragment opens `hx-sse` on `GET /api/sessions/<id>/stream?turn=<turnId>`. `TurnManager` reserves the turn and `TurnRunner` runs it under governance and the guard chain on a lease from `ExecutionCoordinator` |
| **Channel message** | `ChannelManager.handleInboundMessage` resolves the owning channel, the session key and any thread binding, parks the message in `PauseController` while paused (reserved commands excepted), then asks `ChannelTaskBridge.tryHandle` to consume it (reserved commands, per-sender rate limit, bound-thread routing). Unconsumed messages go to `MessageQueue` (per-session FIFO, 1000 ms debounce) and then to a turn |
| **Task** | Created from the API, UI, a channel or an MCP tool, `TaskService` stores it `queued`. `TaskExecutor` polls, requests a worker lease for the task's provider and security profile, runs the turn in a registered worktree if one was declared, then moves it to `review`. `TaskReviewService` merges or cleans up. Status changes are `TaskStatusChangedEvent`s that the notification subscribers turn into channel posts |
| **Workflow step** | `WorkflowExecutor` runs an agent step as a workflow-owned task whose whole prompt chain uses one leased worker. Bash and approval steps are host-owned inside the engine. Connected runs and the standalone CLI share the engine |
| **Config reload** | `SIGUSR1` or a debounced file watch calls `ReloadTriggerService`, which reloads the YAML and hands it to `ConfigNotifier.reload`. The resulting `ConfigDelta` reaches only the `Reconfigurable` services watching the changed sections |

[![Work admission: from entry point to provider turn](diagrams/system-flows.svg)](diagrams/system-flows.svg)

Admission is separate from capacity. `TurnRunner.admitTurn` applies the daily token budget (a read-only check), takes the
session lock, then applies the loop-chain check and the global rate window. The lock comes first because the last two
record state, and an attempt the lock rejects must not count. A polled fail-fast task or workflow request takes its capacity permit
first, so an attempt the lane cannot run leaves no record.

### Cross-Cutting Invariants

- **One execution allocator.** After governance, `ExecutionCoordinator` alone grants capacity: a fixed serialized primary lane plus a hard per-provider worker lease limit (`providers.<id>.pool_size`). Container count and worker capacity are independent ([ADR-016](../adrs/016-multi-provider-harness-architecture.md)).
- **One container, one principal.** A Container Authority is dedicated to a single execution owner and destroyed only after teardown is confirmed. Containers are never shared across principals ([ADR-012](../adrs/012-per-type-container-isolation.md)).
- **Events are notifications, not records.** `EventBus.fire` is fire-and-forget: no buffering, no persistence, and a throwing subscriber is logged inside `runZonedGuarded` without reaching the sender. Facts that must survive live in a store ([ADR-011](../adrs/011-event-driven-architecture.md)).
- **Host-decided provenance.** Who a turn came from, an alert's type and severity, and a tool call's caller identity are set by the host and never parsed from model output.
- **Dependency direction is mechanical.** An import may only point at a strictly lower tier ([Package Architecture](#package-architecture)).

---

## Storage

[![Storage at a glance](diagrams/system-storage.svg)](diagrams/system-storage.svg)

Files under the data directory are authoritative for sessions, messages, memory, configuration and audit.
PostgreSQL 14+ holds tasks, executions, workflow runs, traces, events and knowledge-graph facts, plus search
projections that are derived and rebuilt from the files. Two small file stores sit outside both: `turn_state.json`
for crash recovery and `webhook_deliveries/` for dedup. Headless workflow runs replace PostgreSQL with files under
`<data_dir>/standalone/`.

Startup order matters. Local orphan-turn state is scanned before PostgreSQL opens, the serving interlock is acquired
before the schema gate, and serving runners acknowledge orphan records only after storage wiring returns. Headless and
one-shot clients skip the interlock and the scan. Entities, write safety, retention and recovery are in
[Data Model](data-model.md).

---

## Web UI

Server-rendered HTML with declarative interactivity and no JavaScript build step. Code: `packages/dartclaw_runtime/lib/src/{web,templates,static}/`.

| Layer | Technology |
|-------|-----------|
| Templates | Trellis 0.11 (`.html` with `tl:` attributes), auto-escaping, fragments |
| Interactivity | HTMX 4.0.0 owns navigation, requests, swaps and out-of-band updates. Stimulus controllers (`static/controllers/dc_*_controller.js`, `data-controller="dc-*"`) own browser behaviour on server-rendered DOM |
| Streaming | The bundled HTMX 4 `hx-sse` extension (`static/sse.js`, locally patched); named events feed awaited swaps |
| Markdown | marked.js and highlight.js, sanitized with DOMPurify |
| Styling | `tokens.css` and `design-system.css`, then the app-only `app-tokens.css` and `app.css` |

Navigation swaps `#main-content` with out-of-band sidebar and topbar updates. `wantsFragment()` (`web/web_utils.dart`)
returns a fragment for an `HX-Request` and a full page for a history restore, and each page's `.shell` root carries
`hx-history-elt` so a history refetch restores the route-dependent regions together. The layout applies the loading
indicator and `swap:none` for 4xx/5xx by inheritance, so ordinary form validation errors are status-200 fragments.
Vendored assets are served same-origin; `static/VENDORS.md` records versions and local patches.

`PageRegistry` registers dashboard pages and validates each page's routes at startup: a malformed, reserved or duplicate
route is fatal rather than a request-time surprise. `system_pages.dart` registers Settings, Knowledge and the Knowledge
timeline always; Health, Memory, Scheduling, Tasks, Projects and Workflows depend on the active services and
configuration. SDK hosts add pages with `DartclawServer.registerDashboardPage`. Controller conventions are in
`static/controllers/CONVENTIONS.md`; HTMX and template rules in the [HTMX](../guidelines/HTMX-GUIDELINES.md) and
[Trellis](../guidelines/TRELLIS-GUIDELINES.md) guidelines; the SSE event protocol in
[Observability & Operations](observability-operations-architecture.md).

---

## MCP Server

The host serves MCP on `/mcp` of the same shelf server (`McpProtocolHandler`, `McpRouter` in `dartclaw_runtime/lib/src/mcp/`).
Provider binaries connect back to it ([ADR-009](../adrs/009-internal-mcp-server.md)); how each provider is pointed at the
endpoint is in [Control Protocol](control-protocol.md). Tools are registered at startup by
`service_wiring_mcp_tools.dart` and by hosts through `DartclawServer.registerTool(McpTool)`.

| Family | Tools |
|--------|-------|
| Memory | `memory_apply`, `memory_observe`, `memory_search`, `memory_read` |
| Knowledge | `context_research`, `kg_query`, `kg_timeline`, `kg_contradictions`, `kg_add`, `kg_invalidate`, `wiki_write` |
| Agents | `sessions_spawn`, `sessions_send` |
| Tasks | `task_create`, `task_list`, `review_list`, `task_review`, `task_bind`, `task_unbind` |
| Workflows | `workflow_run`, `workflow_list`, `workflow_status`, `workflow_resume`, `workflow_cancel`, `workflow_request_changes` |
| Scheduling and media | `schedule_upsert`, `schedule_list`, `attach_media` |
| Web | `web_fetch`; `brave_search` and `tavily_search` when that provider is enabled with an API key |
| Onboarding | `onboarding_complete`, registered only while `ONBOARDING.md` exists |

`McpTool` requires `name`, `description`, `inputSchema`, `access` (`McpToolAccess.read` or `.write`, undefaulted so a
tool cannot fall into the permissive half by omission) and `call()`. Guard evaluation and audit belong to dispatch, not
to the tool: after caller-policy authorization and schema validation, `McpProtocolHandler` runs the dispatch guard,
audits, calls the tool with a 120 s timeout, and trims a successful text result to `context.max_result_bytes`
(`ResultTrimmer`, head and tail with a `...[trimmed N bytes]...` marker). Errors are not trimmed.

Callers: the shared gateway token (the steward principal), a host-minted per-harness bearer, and named MCP
clients, whose profile is exactly `context_research`, `kg_query` and `kg_timeline` (`context_engine_profile.dart`).
`ContextualMcpTool` receives a trusted `McpCallerContext` (authority, session, task, agent, knowledge scope).

**Turn provenance.** `McpCallerContext.turn` is a `TurnProvenance` (`dartclaw_core/lib/src/turn/turn_provenance.dart`):
the surface (a channel type, `web` or `cron`), recipient, thread, session key and sender of the turn the calling harness
is running, plus a `delegated` flag for autonomous task or workflow-step turns that carry a requester's identity. The
host builds it where a turn starts, carries it through `TurnManager` into the harness turn context, and resolves it per
call: a container authority reads its own harness's active turn, and every host harness presents a bearer minted by
`HarnessMcpBearers` that is valid until the harness is disposed and maps to that harness's turn. The gateway token and
named clients carry no turn. Only a `TurnAwareMcpTool` receives it, no tool argument can set it, and a turn without a
sender is a non-channel turn that each reading tool gates by its own rule. Consumers are the shared-write and run-approval
gates in [Security Architecture](security-architecture.md).

**Outbound MCP.** `OutboundMcpPool` consumes configured external MCP servers over stdio or HTTP, pools connections with
a 5-minute idle teardown (a pooled connection is reused only after a successful ping, else respawned), and surfaces only tools listed in `mcp_servers.<name>.surface_tools`. Every call passes the
egress guard and is audited first; a guard, governance or audit failure denies the call without contacting the server
([ADR-039](../adrs/039-outbound-mcp-trust-boundary-and-transport.md), [Security Architecture](security-architecture.md#outbound-mcp-egress)).

---

## Memory, Search and Context Research

Search merges the lexical projection of canonical memory, the lexical projection of the chat-facing message NDJSON and
the per-corpus vector projections (built from embeddings) by weighted reciprocal rank fusion (RRF), and returns the
top-K.

Canonical memory is Markdown under the workspace (`MemoryCorpusService`, `MemoryFileService`, `MemoryPruner`, in
`dartclaw_core/lib/src/memory/`); lexical and vector rows in PostgreSQL are derived and rebuilt from it
(`dartclaw rebuild-index`). Conversation rows rebuild from the session NDJSON. Entities and rebuild rules are in
[Data Model](data-model.md).

| Mode (`search.backend`) | Behaviour |
|---|---|
| `lexical` (default) | PostgreSQL full-text search (`PostgresFtsIndex`, `LexicalSearchBackend`). Needs no model and no extension |
| `hybrid` | Adds a per-corpus vector projection (`PostgresVectorIndex`, administrator-provisioned pgvector) and ranks both lists with `HybridSearch` in `dartclaw_search`: reciprocal-rank fusion with k=60 and weights 0.25 keyword, 0.75 vector |

Embeddings come from `NativeEmbeddingProvider` (verified local EmbeddingGemma, default) or `HttpEmbeddingProvider` (an
explicitly configured endpoint that owns its preprocessing; its endpoint and model form a separate fingerprint and trust
boundary). `VectorSynchronizer` reuses only vectors whose content hash and provider fingerprint still match. Candidates
are re-authenticated against current owner-scoped content before publication, so a stale candidate cannot surface after
an await. A provider or vector failure leaves the lexical projection current and reports a structured degradation.
Search adds no agent session, credential or model judgment ([ADR-050](../adrs/050-native-hybrid-search.md)).

**`context_research`** is the Context Engine's one-call retrieval tool ([ADR-042](../adrs/042-context-research-synthesis-and-citation-model.md)).
It fans out over three sources: the caller's private personal-memory search (only where the caller's tool policy grants
it), temporal-KG facts and timelines for entities derived from the query, and wiki documents on the shared published
surface. The source authority is `McpCallerContext`: owner and default calls use principal `owner`, a named agent uses
only its pinned `agent:<id>` principal, and a named MCP client is shared-only. Results are de-duplicated with source
metadata and synthesized through the injected background-turn seam into a `CitationPacket` (statements, source
references, degraded layers, `noSourcesFound`). Malformed synthesis falls back to citation-preserving snippets, and
nothing is cached: every call reruns retrieval and synthesis.

---

## Package Architecture

A Dart pub workspace with 16 members: 14 packages under `packages/`, `apps/dartclaw_cli` and the non-shipping
`dev/fitness` gates. `dev/package_tiers.txt` is the sole authority for dependency direction: **an import or re-export
may only point at a strictly lower tier, and same-tier edges are forbidden.** There is no per-edge exception mechanism
([ADR-034](../adrs/034-enforced-package-dependency-direction.md), [ADR-056](../adrs/056-package-topology-consolidation.md);
the gates are in [Architecture Governance](architecture-governance.md)).

[![Package topology: tier order](diagrams/system-package-topology.svg)](diagrams/system-package-topology.svg)

The figure omits edges implied by a longer path. The CLI also depends directly on `core`, `kernel`, `workflow`,
`search`, `google_chat` and `slack`, the runtime on `core` and `kernel`, and every other package above T0 except
`client`, `bridge` and `fitness` on `kernel`. Each `pubspec.yaml` lists the full set.

| Package | Owns | Key constraint |
|---------|------|----------------|
| `dartclaw_kernel` | Shared models, database and repository ports (`DatabaseBackend`), typed config and `ConfigMeta`, guards and content classification, redaction and audit primitives, `PlatformCapabilities`, dependency-free utilities | No workspace dependency and no `EventBus`, so guards and typed config work without server wiring |
| `dartclaw_core` | `AgentHarness` contracts and the Claude and Codex harnesses, `HarnessRegistrar`, channel contracts and routing, `EventBus` and events, file persistence, `PostgresBackend` and repositories, PostgreSQL lexical and vector indexes, memory corpus, `McpTool` | Runtime and persistence authority. No server or workflow dependency |
| `dartclaw_search` | `HybridSearch`, `VectorSynchronizer`, embedding providers over injected indexes | Owns no corpus and no database driver |
| `dartclaw_acp` | ACP client and harness, reverse-call mediation, target validation, `harness.acp` config, `AcpHarnessRegistrar` | The CLI composes it. The runtime never imports it, and it sits beside the runtime at the same tier |
| `dartclaw_workflow` | `WorkflowService`, `WorkflowExecutor`, parser and validator, registry, materialization, `SkillIntrospector`, workflow-run persistence | Framework-agnostic engine shared by server and CLI; kernel and core only |
| `dartclaw_whatsapp`, `_signal`, `_google_chat`, `_slack` | One channel adapter each, with its sidecar or transport client and config parsing | Heavy transitive dependencies stay out of core. Google Chat and Slack ship fakes behind an opt-in `lib/testing.dart` |
| `dartclaw_bridge` | Framed bridge protocol and the executable delivered into `network:none` containers | Standing zero-dependency leaf: `dart compile exe` rejects build-hook graphs ([ADR-051](../adrs/051-container-bridge-binary-packaging.md)) |
| `dartclaw_client` | HTTP and SSE client and transport DTOs | Zero dependencies, so the client tier stays free of the runtime |
| `dartclaw` | Umbrella re-export of `dartclaw_client` and part of `dartclaw_kernel` | Never re-exports runtime packages |
| `dartclaw_runtime` | `DartclawServer`, turn and execution stack, tasks, projects, alerts, scheduling, container orchestration, MCP server, web UI, HTTP API, `DartclawRuntime.build` | The service graph lives here. Server-only |
| `dartclaw_testing` | Shared doubles (`FakeAgentHarness`, `FakeGuard`, `InMemorySessionService`, `InMemoryTaskRepository`, `TestEventBus`) | Kernel and core only. A double for a port owned above core lives in that port's package |
| `dartclaw_cli` | Command layer: `serve`, workflow, tasks, config, sessions and maintenance commands; connected versus standalone execution | Thin; composes the runtime and registers `AcpHarnessRegistrar` |

Publication intent ([ADR-008](../adrs/008-sdk-publishing-strategy.md)): the client tier (`dartclaw_client`, `dartclaw`)
is the publishable set. Everything else is the fork-the-runtime tier, and no package is published yet. Embedding the
runtime in-process means depending on `dartclaw_core` and its neighbours by path.

---

## Deployment Model

One administrator per instance, one process on one host. The host is an AOT binary built with `dart build cli`
(`dev/tools/build.sh`); the server listens on `server.port` (default 3333).

Runtime prerequisites:
- `claude` and `codex` CLIs for the providers in use (see the [getting started guide](../../docs/guide/getting-started.md))
- Docker or Podman for container isolation (`ContainerManager.runtimeBinaries`)
- PostgreSQL 14+, native or managed, for the server. pgvector is needed only for `hybrid` search. Standalone workflow execution needs only local files
- Optional sidecars: GOWA (WhatsApp), `signal-cli` (Signal)

[![Container isolation topology](diagrams/system-containers.svg)](diagrams/system-containers.svg)

The container name is `dartclaw-<fnv1a32(dataDir) as 8 hex digits>-<profile>-<authority>`, so installs sharing a host
do not collide. API keys live on the host and never enter a container environment. A container reaches exactly one
upstream, through the framed pipes `HostGateway` serves for its authority, and the provider adapter strips any
client-supplied credential before injecting the host's. Claude and Codex have a verified adapter and run on either
boundary. ACP registrations have none, so they never run in a container; the computed compatibility rule is in
[Control Protocol](control-protocol.md).

**Isolation posture.** `resolveContainerPosture` settles it once at startup ([ADR-055](../adrs/055-container-by-default-posture.md)).
An unset `container.enabled` means "isolate if a runtime is detected" and degrades to host execution with a warning if
none is. A declared `true` keeps its fail-closed refusals, and a declared `false` is never overridden. With the posture
disabled, harnesses run as direct host subprocesses and guards still evaluate, but there is no OS-level boundary.
`examples/dev.yaml` declares `false` for development checkouts.

---

## Service Wiring

`DartclawRuntime.build` (`dartclaw_runtime/lib/src/runtime/service_wiring.dart`) is the dependency-injection root. It
constructs and wires every service and returns a `DartclawRuntime` carrying the handles `ServeCommand` needs plus
`shutdown()`. Two parameters shape the composition:

- `headless: true` composes the same guarded execution, task and workflow stacks but no `DartclawServer`, channel
  manager, schedule service or token service. It omits the personal-memory corpus, search backends, knowledge graph and
  self-improvement service, and keeps session, task and turn state in files under `<data_dir>/standalone/` guarded by a
  `StandaloneExecutionLease`; no PostgreSQL connection is opened unless a backend factory is injected. The standalone
  workflow CLI uses it, and `DartclawRuntime.stageHeadless` pauses it after base assembly so the CLI can resolve a
  definition and gate provider authentication before any execution capacity exists.
- `harnessRegistrars` lets the composer contribute provider families the runtime does not name. `serve` passes
  `AcpHarnessRegistrar`; either registrar member may throw to abort assembly fail-closed.

### Construction Order (connected runtime, simplified)

```
Base (wireBase)
 1.  workflow-skill bootstrap, subscription credential store, EventBus, ConfigNotifier
 2.  projects (ProjectService)
 3.  storage: file services, memory preflight, turn-state store, orphan-turn scan,
              PostgreSQL pool → serving interlock → schema gate → derived-index reconciliation
 4.  workflow registry
Execution (completeWithExecution)
 5.  security: container posture, ContainerManagers + HostGateway, GuardChain, audit
 6.  harnesses: HarnessFactory, ExecutionCoordinator, primary harness (workers stay lazy)
 7.  task wiring (TaskService, TaskExecutor, review)
 8.  channels and AlertRouter (not headless)
 9.  provider status, TurnManager and TurnRunner, orphan-turn acknowledgement
10.  WorkflowService, WorkflowRunControl, thread-binding lifecycle, run notifications
11.  credential health, scheduling (ScheduleService), group-session initialization
12.  DartclawServer composition and MCP tool registration
13.  start: primary harness, TaskExecutor, ScheduleService
```

`ServeCommand` scaffolds the workspace before the build. After the build returns, it binds the HTTP server, starts the
session reset service, connects channels, installs signal handlers and starts `ReloadTriggerService`. Shutdown stops
the reload trigger, closes the HTTP server and calls `runtime.shutdown()` under a 10 s ceiling. All services are single-instance
and single-threaded; isolates are used only for blocking git clone, fetch and push.

---

## Related Documents

| Document | Content |
|----------|---------|
| [Control Protocol & Harness](control-protocol.md) | Harness abstraction, Claude/Codex/ACP protocols, turn lifecycle, crash recovery |
| [Security Architecture](security-architecture.md) | Threat model, guards, container isolation, credentials, audit chain, runtime governance |
| [Data Model & Persistence](data-model.md) | Stores, schemas, entities, write safety, retention, backup |
| [Session & State](session-state-architecture.md) | Sessions, keys, locking, event bus, maintenance, conversation attempts |
| [Channel & Messaging](channel-messaging-architecture.md) | Adapters, inbound pipeline, thread binding, outbound delivery |
| [Task & Execution](task-execution-architecture.md) | Task pipeline, worktrees, review, budgets, execution lanes |
| [Workflow Architecture](workflow-architecture.md) | Definitions, executor, step types, gates, loops |
| [Configuration](configuration-architecture.md) | Config model, loading, validation, hot reload, settings UI |
| [CLI & API](cli-api-architecture.md) | CLI structure, connected versus standalone, HTTP API surface |
| [Observability & Operations](observability-operations-architecture.md) | Health, alerts, audit mechanics, usage, logging, SSE |
| [Context Map](context-map.md) | Bounded contexts and context-mapping patterns |
| [Architecture Governance](architecture-governance.md) | Fitness functions and structural gates |
| [LEARNINGS](../state/LEARNINGS.md), [UBIQUITOUS_LANGUAGE](../state/UBIQUITOUS_LANGUAGE.md) | Known traps; canonical terms |
| [User-facing architecture overview](../../docs/guide/architecture.md) | Operator-oriented summary |

### Key ADRs

| ADR | Decision |
|-----|----------|
| [001](../adrs/001-sdk-integration-and-security-architecture.md) | Dart spawns `claude` directly over JSONL; the Deno middle layer was dropped |
| [002](../adrs/002-file-based-storage.md) | File-based storage for sessions and messages; the search index is derived |
| [009](../adrs/009-internal-mcp-server.md) | Internal MCP server at `/mcp` as the tool extension point |
| [011](../adrs/011-event-driven-architecture.md) | Lightweight event bus with a sealed event hierarchy |
| [012](../adrs/012-per-type-container-isolation.md), [055](../adrs/055-container-by-default-posture.md) | Security-profile containers per execution owner; container-by-default posture |
| [016](../adrs/016-multi-provider-harness-architecture.md), [037](../adrs/037-universal-acp-harness.md) | Abstract harness plus protocol adapter; execution lanes; ACP |
| [034](../adrs/034-enforced-package-dependency-direction.md), [056](../adrs/056-package-topology-consolidation.md) | Tiered, strictly downward dependencies; current package topology |
| [049](../adrs/049-typed-platform-capability-surface.md) | `PlatformCapabilities` |
| [054](../adrs/054-model-first-delegation-and-one-authority-per-concern.md) | Model-first delegation; one authority per concern |
| [060](../adrs/060-postgresql-only-storage.md) | PostgreSQL server storage and standalone workflow files |
