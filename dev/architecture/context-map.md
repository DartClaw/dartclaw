# Context Map

Strategic-design view of DartClaw: subdomain investment posture, bounded contexts, and the named patterns that
integrate them. This document owns context **ids**, used by architecture/domain models and for grouping the
[Ubiquitous Language](../state/UBIQUITOUS_LANGUAGE.md), which owns the terms. Package topology and tier order are in
[System Architecture](system-architecture.md); this map says where each context lives, not how packages depend on each
other.

**Current through**: 0.28.0

> **Contexts are linguistic boundaries, not packages.** DartClaw has 14 packages, one app and 15 contexts, mapped
> many-to-many. `dartclaw_runtime` alone hosts eight contexts, while `dartclaw_core` hosts runtime fragments and the
> PostgreSQL adapters for several. See [Observed Structure vs. Contexts](#observed-structure-vs-contexts).

---

## How to Read This

- **Subdomain type**: `core` (differentiated; invest maximally), `supporting` (necessary, undifferentiated; keep
  fit-for-purpose), `generic` (commodity; integrate, don't build). Evans; Khononov ch. 1.
- **Integration pattern**: one of Partnership, Shared Kernel, Customer/Supplier, Conformist, Anticorruption Layer (ACL),
  Open Host Service (OHS), Published Language, Separate Ways, Big Ball of Mud. A pattern marked _accepted_ differs from
  the ideal and is tracked in [Drift Findings](#drift-findings).

---

## Subdomains

| Subdomain | Type | Rationale | Key invariant |
|---|---|---|---|
| Execution isolation & credential mediation | **core** | The product claim: OS boundaries over application boundaries. High model complexity (principal, authority, single-use container, host-side credential injection) | A container never crosses principals; credentials never enter a container environment |
| Provider control protocol | **core** | Reimplementing Claude JSONL, Codex JSON-RPC and ACP directly in Dart is what removes npm from the chain. Three incompatible vendor models normalized to one contract | One host-owned execution contract; provider branching stays inside adapters |
| Tool-call guarding | **core** | Defense-in-depth Layer 3 is the security posture at application level (SSRF, pipe analysis, symlink resolution, LLM classification) | Fail-closed by default; every verdict is auditable |
| Turn & execution orchestration | **core** | The runtime's heart: one serialized primary lane, hard per-provider lease capacity, worker reuse | Capacity is lease-based; reuse is an optimization, never the capacity authority |
| Durable knowledge & memory | **core** | Cross-session memory is a daily-driver differentiator: canonical entries, temporal KG, citation synthesis | The search index is a rebuildable projection; authoritative KG facts live in durable storage |
| Workflow orchestration | **core** _(contested, see H-1)_ | Deterministic host-driven pipelines instead of prompt choreography, with a git branch topology. The largest package | The engine validates declared schema only; framework semantics live in definitions and skills (ADR-041) |
| Task & review lifecycle | supporting | Intricate (worktree reconciliation, promotion, review) but the differentiation sits in the isolation and orchestration underneath | Worktrees stay keyed by task UUID; shared identity fields select bindings but never derive paths |
| Conversation & session routing | supporting | Session keying and scoping are load-bearing plumbing, not the product claim | The session key is deterministic and decouples scoping from session discovery |
| Channel integration | supporting | Reaching the assistant from a phone is a stated property, but the adapters are commodity vendor-API work | Every platform normalizes to `ChannelMessage` before routing |
| Runtime governance | supporting | Cost, abuse and runaway controls. Thin model, all default-disabled | Governance is pre-execution; the coordinator is post-governance |
| Project & source control | supporting | Multi-repo checkout management serving both tasks and workflows | `remoteUrl == ''` is the single local-only discriminator |
| Configuration & platform policy | supporting | Typed operator intent and deterministic OS capability policy | Capability values are policy only; consumers own I/O and remediation |
| Observability & alerting | supporting | Operator-facing evidence of what the runtime did | Traces are best-effort and async; task events are synchronous and lossless |
| Operator interface | supporting | One surface over every capability; server-rendered, zero JS build | Zero external origins in shipped assets |
| HTTP authentication | **generic** | Gateway-token auth, deliberately minimal (ADR-006) | – |
| Distribution & packaging | **generic** | Homebrew/Scoop, embedded assets, release builds, already outsourced to platform tooling | – |

No generic subdomain is treated as core. The one over-investment risk is workflow orchestration (H-1).

---

## Bounded Contexts

Ids are stable and are the canonical names for downstream models and glossary sections. Paths are under `packages/`
unless noted.

| Context | Purpose | Subdomains owned | Code location | Boundary rationale |
|---|---|---|---|---|
| `provider-mediation` | Translate provider-native control protocols into one host-owned execution contract | Provider control protocol | `dartclaw_core/lib/src/{harness,bridge,worker}/`, `dartclaw_acp/` | One dominant abstraction (`AgentHarness` + `ProtocolAdapter`), sized by the number of vendor protocols, not by feature growth |
| `execution-isolation` | Bind each execution to one trust principal and mediate its provider traffic host-side | Execution isolation & credential mediation | `dartclaw_runtime/lib/src/container/`, `execution_policy_resolver.dart`, `dartclaw_bridge/`, `dartclaw_core/lib/src/container/`, `CredentialRegistry` in `dartclaw_kernel` | Small in code, large in invariant density. Principal, Authority, Gateway and Bridge are one indivisible trust story (ADR-012, ADR-051) |
| `guarding-audit` | Evaluate every tool call, inbound message and egress against policy, and record the verdict | Tool-call guarding | `dartclaw_kernel/lib/src/` (guard contracts, `GuardChain`), `dartclaw_runtime/lib/src/{security,audit}/`, `ToolPolicyGuard` in `dartclaw_core/lib/src/agents/` | Deliberately EventBus-free so guards run standalone; that constraint keeps the context from absorbing server wiring |
| `turn-orchestration` | Admit, run and observe one unit of agent work end to end | Turn & execution orchestration | `dartclaw_runtime/lib/src/turn_*.dart`, `execution_coordinator*.dart`, `worker_capacity_gate.dart`, `{concurrency,context,behavior}/`; `dartclaw_core/lib/src/{turn,agents,concurrency}/` | The densest coupling cluster. Correctly one context, incorrectly spread over a flat directory of top-level files |
| `runtime-governance` | Enforce pre-execution limits on cost, rate and runaway autonomy | Runtime governance | `dartclaw_runtime/lib/src/{governance,emergency}/`, `turn_governance_enforcer.dart`, `GovernanceConfig` and `SlidingWindowRateLimiter` in `dartclaw_kernel` | Small but linguistically sharp. Separate from `turn-orchestration` because the glossary draws the pre/post-governance line explicitly |
| `conversation-session` | Own conversation identity, retention, submissions, attempts, history, effective context, inbox state, and the rules deciding which conversation a message belongs to | Conversation & session routing | `dartclaw_core/lib/src/{storage,scoping}/`, `dartclaw_runtime/lib/src/{session,conversation,maintenance}/`, conversation API and web routes | Distinct lifecycle and snapshot authority, consumed by turn orchestration and projected into operator surfaces |
| `channel-integration` | Normalize external messaging platforms into one inbound/outbound contract | Channel integration | `dartclaw_core/lib/src/channel/`, `dartclaw_{whatsapp,signal,google_chat,slack}/`, webhook and pairing routes in `dartclaw_runtime` | Naturally partitioned per platform behind one interface. A new platform adds an adapter, not context surface |
| `task-review` | Run discrete reviewable units of work against a project checkout, with a git-backed review flow | Task & review lifecycle | `dartclaw_runtime/lib/src/{task,scheduling}/`, `dartclaw_core/lib/src/task/` | The largest context inside `dartclaw_runtime`. Absorbs scheduling, which is too thin to stand alone |
| `workflow-orchestration` | Execute declarative multi-step pipelines deterministically, including git branch topology and conflict resolution | Workflow orchestration | `dartclaw_workflow/`, workflow glue in `dartclaw_runtime`, workflow commands in `apps/dartclaw_cli` | Sized by its own vocabulary (Run, Step, Promotion, Story Branch), which shares almost no terms with `task-review` |
| `knowledge-memory` | Retain, curate and synthesize durable knowledge; serve citation-backed context to agents | Durable knowledge & memory | `dartclaw_core/lib/src/{memory,search,knowledge,storage}/`, `dartclaw_search/`, `dartclaw_runtime/lib/src/{memory,knowledge}/`, `memory_handlers.dart` | Persistence and search contracts share a package with the corpus owners; the runtime owns curation and presentation |
| `tool-surface` | Publish host-owned tools to provider binaries and consume external MCP servers under guard | (shared: guarding, knowledge) | `dartclaw_runtime/lib/src/mcp/` | Kept apart from `provider-mediation` because it is the mirror direction (host serves the provider) with its own trust boundary (ADR-039) |
| `project-registry` | Manage the git checkouts that tasks and workflows execute against | Project & source control | `dartclaw_runtime/lib/src/project/`, `ProjectConfig` and `Project` in `dartclaw_kernel` | Small, but a shared upstream of two contexts. Folding it into either would hide a cross-context dependency |
| `configuration-platform` | One typed, validated, hot-reloadable source of operator intent, plus deterministic OS capability policy | Configuration & platform policy | `dartclaw_kernel/lib/src/` (typed sections, parsers), `dartclaw_runtime/lib/src/config/`, `ReloadTriggerService` in `apps/dartclaw_cli` | Grows linearly with config surface, not in complexity |
| `operator-interface` | Give the operator one coherent surface over every runtime capability | Operator interface, HTTP authentication | `dartclaw_runtime/lib/src/{api,web,templates,auth,health}/`, `server.dart`, `apps/dartclaw_cli/` | Presentation-heavy and the largest by volume; the size is template and route surface, not model complexity |
| `observability-alerting` | Record what the runtime did and route operational signals to the operator | Observability & alerting | `dartclaw_runtime/lib/src/{alerts,observability,health,logging}/`, trace/event writers in `dartclaw_core` | Consumes the event bus rather than reaching into domains, the cleanest boundary in the repo |

**Shared kernel.** `dartclaw_kernel` is not a context. It is an explicit Shared Kernel of dependency-free values, storage
ports including `DatabaseBackend`, typed configuration, guard contracts and deterministic utilities shared verbatim
across contexts. Its zero-workspace-dependency position is enforced by the tier order
([Architecture Governance](architecture-governance.md)).

**Ownership.** Contexts are linguistic and documentation boundaries, not team boundaries.

---

## Integration Patterns

Every ordered pair that exchanges data, with its named pattern.

[![Bounded contexts and integration patterns](diagrams/context-map-contexts.svg)](diagrams/context-map-contexts.svg)

The figure shows the point-to-point integrations between contexts; the tables carry every pair, with notes.

### Internal

| Upstream | Downstream | Pattern | Notes |
|---|---|---|---|
| `dartclaw_kernel` | all contexts | **Shared Kernel** | No DartClaw dependencies; one bottom-tier owner for shared values, config, guards and utilities |
| `configuration-platform` | all contexts | **Open Host Service** | Typed sections consumed everywhere; `registerExtensionParser()` is the published extension point |
| `configuration-platform` | reconfigurable services | **Published Language** | `ConfigDelta` + `Reconfigurable.watchKeys` is the exchange format for hot reload |
| `provider-mediation` | `turn-orchestration` | **Open Host Service** | `AgentHarness` is the stable contract for many consumers; `BridgeEvent` is its published language |
| `execution-isolation` | `provider-mediation` | **Partnership** | The host gateway pins upstream per provider while the adapter strips client credentials; neither half is correct alone |
| `execution-isolation` | `turn-orchestration` | **Partnership** | Authority grant, confirmed teardown and lease replacement share fate on execution correctness |
| `execution-isolation` | in-container bridge | **Published Language** | `dartclaw_bridge` holds both halves of the frame format in one zero-dependency package so the wire cannot skew |
| `guarding-audit` | `turn-orchestration` | **Open Host Service** | `GuardChain` + `GuardVerdictCallback`; the callback keeps the guard code EventBus-free |
| `guarding-audit` | `tool-surface` | **Open Host Service** | The egress guard mediates every outbound MCP call before dispatch (ADR-039) |
| `guarding-audit` | `execution-isolation` | **Separate Ways** | Deliberate: Layer 3 and Layer 5 are independent defenses. Guard verdicts know nothing about authorities; they compose only in `turn-orchestration` |
| `runtime-governance` | `turn-orchestration` | **Customer/Supplier** | Governance gates admission; the coordinator is the post-governance authority |
| `conversation-session` | `channel-integration` | **Customer/Supplier** | The scoping model serves channel routing; session-key shapes are driven by channel needs |
| `conversation-session` | `turn-orchestration` | **Customer/Supplier** | Turn persistence and cursor-based crash recovery follow the session record's contract |
| `conversation-session` | `operator-interface` | **Published Language** | Revisioned conversation snapshots, history records, inbox entries, attention events and command availability are server-owned projections consumed by web clients |
| `knowledge-memory` | `conversation-session` | **Open Host Service** | Named-agent sessions use their pinned principal for ordinary memory and search; `context_research` is the explicit owner-knowledge grant |
| `task-review` | `channel-integration` | **Customer/Supplier** | Task lifecycle notifications return through channel delivery; `ChannelTaskBridge` owns only deterministic inbound routing |
| `task-review` | `workflow-orchestration` | **Customer/Supplier** | Workflow steps create tasks carrying engine-computed execution declarations; the authored step type stays on workflow execution metadata (ADR-023, ADR-024) |
| `workflow-orchestration` | `operator-interface` | **Open Host Service** | Inverted: the engine publishes `WorkflowGitPort` / `WorkflowTurnAdapter`; server and CLI adapt to them (ADR-034) |
| `project-registry` | `task-review` | **Open Host Service** | `Task.projectId` is the consumer-side name |
| `project-registry` | `workflow-orchestration` | **Open Host Service** | `WorkflowDefinition.project` is the second consumer-side name for the same upstream, deliberately a distinct term |
| `knowledge-memory` | `tool-surface` | **Open Host Service** | `memory_apply`, `memory_observe`, `memory_search`, `memory_read` and `context_research` are published as MCP tools |
| `knowledge-memory` | `turn-orchestration` | **Customer/Supplier** | A bounded canonical-memory index projection is injected into every primary turn prompt |
| all contexts | `observability-alerting` | **Published Language** | The sealed `DartclawEvent` hierarchy is the exchange format; subscribers never reach into domains (ADR-011) |
| all contexts | `operator-interface` | **Conformist** _(accepted, D-1)_ | Routes and templates import domain services directly. Accepted for a server-rendered zero-JS UI |
| `tool-surface` | `execution-isolation` | **Customer/Supplier** | Container executions reach `/mcp` only through the per-authority framed bridge |

### External

| Upstream | Downstream | Pattern | Notes |
|---|---|---|---|
| Provider CLI wire formats (`claude`, `codex`, ACP) | `provider-mediation` | **Conformist** | Vendor protocols cannot be negotiated; DartClaw reimplements them as specified |
| Provider CLI models | `provider-mediation` | **Anticorruption Layer** | `ProtocolAdapter` translates three vendor models into `BridgeEvent` + the canonical tool taxonomy, so provider drift stops at the adapter |
| Messaging platform APIs (WhatsApp/GOWA, signal-cli, Google Chat, Slack) | `channel-integration` | **Anticorruption Layer** | Per-platform adapters normalize to `ChannelMessage`; vendor quirks stay inside the adapter |
| External MCP servers | `tool-surface` | **Conformist** | Their tool schemas are taken as given; only tools listed in `surface_tools` are surfaced, and the egress guard mediates every call |
| AndThen framework | `workflow-orchestration` (engine) | **Separate Ways** | Explicit non-integration, enforced by `dev/tools/fitness/check_no_framework_coupling.sh` and ADR-041 |
| AndThen framework | `workflow-orchestration` (built-in definitions) | **Conformist** | The shipped YAML definitions name AndThen skills directly, the sanctioned home for framework semantics |
| Docker / OS platform | `execution-isolation` | **Conformist** | Docker semantics are taken as given. An explicit `container.enabled` on native Windows exits rather than degrading |

---

## Ubiquitous Language

[UBIQUITOUS_LANGUAGE.md](../state/UBIQUITOUS_LANGUAGE.md) has one `##` section per context, each heading slugging to the
id above (`Guarding & Audit` becomes `guarding-audit`). Listed here are only terms whose meaning is contested or
load-bearing at a boundary; the glossary's [Overloaded Terms](../state/UBIQUITOUS_LANGUAGE.md#overloaded-terms) table
carries the full disambiguation.

| Context | Contested / load-bearing terms |
|---|---|
| `provider-mediation` | **Bridge** (vs. container bridge), **Capability** (harness capability vs. platform capability), Protocol Adapter, Canonical Tool Taxonomy |
| `execution-isolation` | **Principal**, **Container Authority**, **Host Gateway**, **Bridge**, Execution Policy, Security Profile |
| `guarding-audit` | **Audit** (guard evidence vs. observability trace), Guard Verdict, egress guard, Tool Approval Request |
| `turn-orchestration` | **Turn**, **Worker**, **Context** (context window vs. Workflow Context vs. Context Engine), Execution Lease, Execution Fingerprint, Logical Agent |
| `runtime-governance` | **Budget** (governance daily tokens vs. workflow step budget), Emergency Control, Loop Detector |
| `conversation-session` | **Session** (record vs. platform chat thread), Session Key, Session Scope, Cursor, Workspace Binding, Conversation Attempt, Effective Context, Attention Event, Action Availability, Temporary Conversation |
| `channel-integration` | **Thread** (platform thread vs. Dart threading), **Message** (channel DTO vs. persisted record), Thread Binding, Sender Attribution |
| `task-review` | **Merge** (task-to-main vs. workflow Promotion), Worktree, Task Project ID, Scheduled Job (not a Task) |
| `workflow-orchestration` | **Context**, **Drain**, **Project** (Workflow Project vs. Task Project ID), Promotion Conflict, Serialize-remaining |
| `knowledge-memory` | **Context Engine** (synthesis layer, explicitly not the turn context assembler), Canonical Memory Entry, Memory Locator, Search Index, citation packet |
| `tool-surface` | **Tool** (MCP tool vs. canonical taxonomy name), outbound MCP client, `surface_tools` |
| `project-registry` | **Project**: three distinct senses across contexts, separated in the glossary |
| `configuration-platform` | Composed Config, Reconfigurable Service, Behavior Files, **Capability** |
| `operator-interface` | Connected Mode, Standalone Mode, API Client, Server Detection |
| `observability-alerting` | **Event** (`DartclawEvent` vs. `BridgeEvent` vs. `TaskEvent` vs. DDD domain event), **Audit**, Alert Routing |

---

## Observed Structure vs. Contexts

Packages are the observed modules; contexts are the linguistic boundaries. Where they diverge:

| Package | Contexts hosted | Gap |
|---|---|---|
| `dartclaw_runtime` | `turn-orchestration`, `execution-isolation`, `task-review`, `tool-surface`, `operator-interface`, `observability-alerting`, `runtime-governance`, `project-registry` (+ parts of 4 more) | Eight contexts in one package with no intra-package boundary enforcement. The only structural signal is directory naming, and two directories are misnamed (D-2) |
| `dartclaw_core` | Claude/Codex `provider-mediation`, `conversation-session`, `channel-integration` (interfaces), plus fragments of `turn-orchestration`, `task-review`, `knowledge-memory`, `observability-alerting`, `runtime-governance` | "Core" is a dependency-position name, not a context. Runtime contracts and the PostgreSQL persistence adapter share one owner where aggregate hydration requires it |
| `dartclaw_acp` | ACP `provider-mediation` | Clean protocol-family owner: runtime, config parser, validation and registrar live together; the CLI composes it through the server's generic registrar seam |
| `dartclaw_kernel` | shared kernel, `configuration-platform`, `guarding-audit` (partial) | One bottom-tier package for contracts consumed together; EventBus and runtime wiring stay above it |
| `dartclaw_workflow` | `workflow-orchestration` | Clean 1:1, the only large context with its own package |
| `dartclaw_bridge` | `execution-isolation` (wire contract) | Clean 1:1, and the strictest boundary in the repo (zero dependencies) |
| `dartclaw_search` | `knowledge-memory` (retrieval composition) | Hybrid fusion and embedding providers only; corpus mapping stays with the corpus owner |
| channel packages (`whatsapp`, `signal`, `google_chat`, `slack`) | `channel-integration` | Clean 1:4, one context with four adapters |
| `dartclaw_client` | none | Pure transport for the server's HTTP/SSE surface. Owns no domain language and mints no DTOs, so endpoint types keep one owner |
| `dartclaw`, `dartclaw_testing` | none | Client-tier umbrella re-export and test doubles; no domain ownership |

A package addition needs an explicit owner decision. Package size is governed by recorded targets with a 110% failure
margin (`dev/tools/arch_check.dart`, ADR-033).

---

## Drift Findings

| Id | Gap | Root cause | Smallest closing move |
|---|---|---|---|
| **D-1** _(accepted)_ | `operator-interface` is Conformist to every context it renders, with no translation layer: `api/` imports 15 sibling directories of `dartclaw_runtime/lib/src`, `web/` 16 (21 imports of `task/` from `api/` alone), and `templates/` reaches back into `task/`, `session/`, `audit/`, `scheduling/`, `knowledge/` | The server-rendered UI grew alongside the domains it renders. Normal for this stack; no read-model seam was ever needed | None now. If a domain rename starts rippling into templates, introduce view-model DTOs for the highest-traffic pages first |
| **D-2** | Two `dartclaw_runtime` directories are misnamed relative to the contexts they serve. `config/` holds hot-reload fan-out wiring (appliers and subscribers importing `behavior/`, `context/`, `workspace/`, `scheduling/`, `task/`), not configuration. `emergency/emergency_stop_handler.dart` imports `../api/sse_broadcast.dart`, putting a safety-critical path downstream of the HTTP route layer | Vocabulary collision between `configuration-platform` (the context, mostly in `dartclaw_kernel`) and `dartclaw_runtime/lib/src/config/` (wiring), plus a transport helper filed under `api/` | Rename `config/` to `reconfiguration/`; move `sse_broadcast.dart` out of `api/` into a transport-neutral location. Both are renames with no behavior change. Do this first: the collision is live and a safety path depending on the route layer resists testing |

**Recorded non-issues**, considered and dismissed so the reasoning is not re-derived:

- **Context count vs. cognitive load.** 15 contexts against the "2-3 per team" heuristic looks alarming, but the
  heuristic bounds team hand-offs and there is no team boundary to cut across. The real bound is the auditability
  principle, already governed by LOC targets. The glossary's many overloaded terms are evidence the boundaries were
  discovered, not invented.
- **Merging `tool-surface` into `provider-mediation`.** Both are host-to-provider contracts, but they run in opposite
  directions with different trust boundaries, and ADR-039 already settles the outbound one.
- **Splitting `dartclaw_runtime`.** Eight contexts in one package is real, but the package count is at its ceiling of
  14 and the philosophy favors staying lean. This map is the boundary record; fitness machinery to police it would be
  the ceremony the project rules out. Revisit only if a split is actually proposed.

### Hotspot

**H-1: is `workflow-orchestration` core or supporting?** Recorded rather than forced; it needs an owner decision.

_For core_: deterministic host-driven pipelines are a stated differentiator against prompt choreography; the git branch
topology (integration/story branches, promotion, agent-resolved merge) has no off-the-shelf equivalent; it carries the
richest vocabulary in the glossary.
_For supporting_: `dartclaw_workflow` is the largest package after the runtime and core, inside a product whose
philosophy ([PRODUCT.md](../state/PRODUCT.md)) favors minimal scope; a general agent runtime does not obviously need a
workflow engine to be differentiated.
_Why it matters_: a supporting classification limits workflow investment to what the agent runtime needs; a core
classification supports broader workflow capability. LOC targets stay a separate structural check under ADR-033. Settle
this before the next workflow investment, e.g. with `andthen:architecture --mode decompose` scoped to
`workflow-orchestration` vs. `task-review`.
