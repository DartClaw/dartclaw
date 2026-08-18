# Context Map

Strategic-design view of DartClaw: subdomain investment posture, bounded contexts, and the named patterns that
integrate them. Canonical source for context **ids** used by architecture/domain models and for grouping the
[Ubiquitous Language](../state/UBIQUITOUS_LANGUAGE.md).

**Path**: brownfield – derived from observed code structure, `dev/architecture/*.md`, package `AGENTS.md` boundary
rules, and the existing UL. **Current through**: 0.24.

> **Contexts are linguistic boundaries, not packages.** DartClaw has 14 workspace members and 15 contexts; the
> mapping is many-to-many. `dartclaw_server` alone hosts eight contexts, and `dartclaw_storage` hosts none – it is the
> SQLite adapter layer for four of them. See [Observed Structure vs. Contexts](#observed-structure-vs-contexts).

---

## How to Read This

- **Subdomain type** – `core` (differentiated; invest maximally) · `supporting` (necessary, undifferentiated; keep
  fit-for-purpose) · `generic` (commodity; integrate, don't build). Evans; Khononov ch. 1.
- **Integration pattern** – one of the 9-pattern catalog: Partnership, Shared Kernel, Customer/Supplier, Conformist,
  Anticorruption Layer (ACL), Open Host Service (OHS), Published Language, Separate Ways, Big Ball of Mud.
- **Current / Target** – Current is what the code does today; Target is the accepted shape. Rows are identical unless
  the Target column says otherwise; every difference appears in [Drift Findings](#drift-findings).

---

## Subdomains

| Subdomain | Type | Rationale | Key invariant |
|---|---|---|---|
| Execution isolation & credential mediation | **core** | The product claim – "OS boundaries over application boundaries". High differentiation, high model complexity (principal, authority, single-use container, host-side credential injection) | A container never crosses principals; credentials never enter a container environment |
| Provider control protocol | **core** | Reimplementing Claude JSONL / Codex JSON-RPC / ACP directly in Dart is what removes npm from the chain. High complexity: three incompatible vendor models normalized to one contract | One host-owned execution contract; provider branching stays inside adapters |
| Tool-call guarding | **core** | Defense-in-depth Layer 3 is the security-conscious posture at application level. Moderate differentiation, high complexity (SSRF, pipe analysis, symlink resolution, LLM classification) | Fail-closed by default; every verdict is auditable |
| Turn & execution orchestration | **core** | The runtime's heart: one serialized primary lane, hard per-provider lease capacity, knob-free reuse. High complexity | Capacity is lease-based; reuse is an optimization, never the capacity authority |
| Durable knowledge & memory | **core** | "Remember things across sessions" is a named daily-driver differentiator. High complexity: canonical entries, temporal KG, citation synthesis | Search index is a rebuildable projection; authoritative KG facts live in durable storage |
| Workflow orchestration | **core** _(contested – see H-1)_ | Deterministic host-driven pipelines instead of prompt choreography, with a git branch topology. Highest complexity in the repo (~24K LOC) | Engine validates declared schema only; framework semantics live in definitions and skills (ADR-041) |
| Task & review lifecycle | supporting | Necessary and intricate (worktree reconciliation, promotion, review flows), but the differentiation sits in the isolation and orchestration underneath it. Classic high-complexity/medium-differentiation position | Worktrees stay keyed by task UUID; shared identity fields select bindings but never derive paths |
| Conversation & session routing | supporting | Session keying and scoping are load-bearing plumbing, not the product claim | Session key is deterministic and decouples scoping from session discovery |
| Channel integration | supporting | Reaching the assistant from a phone is a stated daily-driver property, but the adapters themselves are commodity vendor-API work | Every platform normalizes to `ChannelMessage` before routing |
| Runtime governance | supporting | Cost/abuse/runaway controls. Thin model, all default-disabled | Governance is pre-execution; the coordinator is post-governance |
| Project & source control | supporting | Multi-repo checkout management serving both tasks and workflows | `remoteUrl == ''` is the single local-only discriminator |
| Configuration & platform policy | supporting | Typed operator intent and deterministic OS capability policy | Capability values are policy only; consumers own I/O and remediation |
| Observability & alerting | supporting | Operator-facing evidence of what the runtime did | Traces are best-effort/async; task events are synchronous and lossless |
| Operator interface | supporting | One coherent surface over every capability; server-rendered, zero JS build | Zero external origins in shipped assets |
| HTTP authentication | **generic** | Single-user token auth. Deliberately minimal (ADR-006) | – |
| Distribution & packaging | **generic** | Homebrew/Scoop, embedded assets, release builds. Commodity; already outsourced to platform tooling | – |

**Anti-pattern check** – no generic subdomain is being treated as core. The one over-investment risk is Workflow
Orchestration (H-1).

---

## Bounded Contexts

Ids are stable and are the canonical names for downstream models and glossary clusters.

| Context | Purpose | Subdomains owned | Code location | Sizing rationale |
|---|---|---|---|---|
| `provider-mediation` | Translate provider-native control protocols into one host-owned execution contract | Provider control protocol | `dartclaw_core/lib/src/harness/`, `bridge/`, `worker/` | ~8.1K LOC, one dominant abstraction (`AgentHarness` + `ProtocolAdapter`). Sized by the number of vendor protocols, not by feature growth |
| `execution-isolation` | Bind each execution to exactly one trust principal and mediate its provider traffic host-side | Execution isolation & credential mediation | `dartclaw_server/lib/src/container/`, `execution_policy_resolver.dart`, `dartclaw_bridge/`, `dartclaw_core/lib/src/container/`, `CredentialRegistry` in `dartclaw_config` | Small in LOC (~2.9K), large in invariant density. Kept whole because Principal, Authority, Gateway, and Bridge are one indivisible trust story (ADR-012, ADR-051) |
| `guarding-audit` | Evaluate every tool call, inbound message, and egress against policy, and record the verdict | Tool-call guarding | `dartclaw_security/`, `dartclaw_server/lib/src/security/`, `audit/`, `ToolPolicyGuard` in `dartclaw_core` | ~3.6K LOC. Deliberately EventBus-free leaf so guards run standalone; that constraint is what keeps the context from absorbing server wiring |
| `turn-orchestration` | Admit, run, and observe one unit of agent work end to end | Turn & execution orchestration | `dartclaw_server/lib/src/turn_*.dart`, `execution_coordinator*.dart`, `worker_capacity_gate.dart`, `concurrency/`, `context/`, `behavior/`, `dartclaw_core/lib/src/turn/`, `agents/`, `concurrency/` | ~6K LOC across loose top-level files. The densest coupling cluster in the repo – correctly one context, incorrectly one flat directory (D-2) |
| `runtime-governance` | Enforce pre-execution limits on cost, rate, and runaway autonomy | Runtime governance | `dartclaw_server/lib/src/governance/`, `emergency/`, `turn_governance_enforcer.dart`, `GovernanceConfig` and `SlidingWindowRateLimiter` in `dartclaw_config` | Small (~0.6K) but linguistically sharp. Separate from `turn-orchestration` because the UL draws the pre/post-governance line explicitly |
| `conversation-session` | Own the durable conversation record and the rules deciding which conversation a message belongs to | Conversation & session routing | `dartclaw_core/lib/src/storage/`, `scoping/`, `dartclaw_server/lib/src/session/`, `maintenance/` | ~1.5K LOC. Distinct lifecycle (types, scopes, archival, prune protection) that `turn-orchestration` only consumes |
| `channel-integration` | Normalize external messaging platforms into one inbound/outbound contract | Channel integration | `dartclaw_core/lib/src/channel/`, `dartclaw_whatsapp/`, `dartclaw_signal/`, `dartclaw_google_chat/`, webhook + pairing routes in `dartclaw_server` | ~10.8K LOC but naturally partitioned per platform behind one interface. Adding a platform adds an adapter, not context surface |
| `task-review` | Run discrete reviewable units of work against a project checkout, with a git-backed review flow | Task & review lifecycle | `dartclaw_server/lib/src/task/`, `advisor/`, `scheduling/`, `dartclaw_core/lib/src/task/`, task repos in `dartclaw_storage` | ~13K LOC – the largest context inside `dartclaw_server`. Also absorbs Scheduling, which is too thin (~1.2K LOC) to stand alone |
| `workflow-orchestration` | Execute declarative multi-step pipelines deterministically, including git branch topology and conflict resolution | Workflow orchestration | `dartclaw_workflow/`, workflow glue in `dartclaw_server`, workflow commands in `apps/dartclaw_cli` | ~25.9K LOC – the largest context in the repo, at a fitness ceiling of 30K. Sized by its own vocabulary (Run, Step, Promotion, Story Branch), which shares almost no terms with `task-review` |
| `knowledge-memory` | Retain, curate, and synthesize durable knowledge; serve citation-backed context to agents | Durable knowledge & memory | `dartclaw_core/lib/src/memory/`, `dartclaw_storage/lib/src/{memory,search,knowledge}/`, `dartclaw_server/lib/src/{memory,knowledge}/`, `memory_handlers.dart` | ~10.7K LOC spread over four packages – the most physically scattered context (D-3) |
| `tool-surface` | Publish host-owned tools to provider binaries and consume external MCP servers under guard | (shared: guarding, knowledge) | `dartclaw_server/lib/src/mcp/` | ~4K LOC. Kept separate from `provider-mediation` because it is the mirror direction (host serves the provider) with its own trust boundary (ADR-039) |
| `project-registry` | Manage the git checkouts that tasks and workflows execute against | Project & source control | `dartclaw_server/lib/src/project/`, `ProjectConfig`, `Project` in `dartclaw_models` | ~1K LOC. Small, but a shared upstream of two contexts – folding it into either would hide a cross-context dependency |
| `configuration-platform` | Single typed, validated, hot-reloadable source of operator intent, plus deterministic OS capability policy | Configuration & platform policy | `dartclaw_config/`, `dartclaw_server/lib/src/config/`, `ReloadTriggerService` in `apps/dartclaw_cli` | ~11.6K LOC, almost entirely typed sections and parsers. Grows linearly with config surface, not in complexity |
| `operator-interface` | Give the single operator one coherent surface over every runtime capability | Operator interface, HTTP authentication | `dartclaw_server/lib/src/{api,web,templates,auth,params,health}/`, `server.dart`, `apps/dartclaw_cli/` | ~36K LOC (largest by volume). Presentation-heavy; the size is template and route surface, not model complexity |
| `observability-alerting` | Record what the runtime did and route operational signals to the operator | Observability & alerting | `dartclaw_server/lib/src/{alerts,observability,health,logging}/`, trace/event writers in `dartclaw_storage` | ~1.5K LOC. Consumes the event bus rather than reaching into domains – the cleanest boundary in the repo |

**Shared kernel** – `dartclaw_models` is not a context. It is an explicit Shared Kernel: zero-dependency value types
(`Session`, `Message`, `SessionKey`, `Task`, `Project`, `TaskEvent`) shared verbatim by every context, with its
leaf position enforced by fitness function.

**Owning team** – all contexts: single maintainer. Contexts here are linguistic and documentation boundaries, not
ownership boundaries; see [Recorded non-issues](#drift-findings).

---

## Integration Patterns

Every ordered pair that exchanges data, with its named pattern. Rows where Current and Target differ carry a drift id.

### Internal

| Upstream | Downstream | Pattern (Current) | Pattern (Target) | Notes |
|---|---|---|---|---|
| `dartclaw_models` (kernel) | all contexts | **Shared Kernel** | Shared Kernel | Zero-dep by rule; kernel stays small because services and parsers are forbidden in it |
| `configuration-platform` | all contexts | **Open Host Service** | OHS | Typed sections consumed everywhere; `registerExtensionParser()` is the published extension point |
| `configuration-platform` | reconfigurable services | **Published Language** | Published Language | `ConfigDelta` + `Reconfigurable.watchKeys` is the exchange format for hot reload |
| `provider-mediation` | `turn-orchestration` | **Open Host Service** | OHS | `AgentHarness` is the stable contract for many consumers; `BridgeEvent` is its published language |
| `execution-isolation` | `provider-mediation` | **Partnership** | Partnership | Host gateway pins upstream per provider while the adapter strips client credentials – neither half is correct alone |
| `execution-isolation` | `turn-orchestration` | **Partnership** | Partnership | Authority grant, confirmed teardown, and lease replacement co-evolved through 0.24; shared fate on execution correctness |
| `execution-isolation` | in-container bridge | **Published Language** | Published Language | `dartclaw_bridge` holds both halves of the frame format in one zero-dependency package so the wire cannot skew |
| `guarding-audit` | `turn-orchestration` | **Open Host Service** | OHS | `GuardChain` + `GuardVerdictCallback`; the callback is what keeps the guard package EventBus-free |
| `guarding-audit` | `tool-surface` | **Open Host Service** | OHS | Egress guard mediates every outbound MCP call before dispatch (ADR-039) |
| `guarding-audit` | `execution-isolation` | **Separate Ways** | Separate Ways | Deliberate: Layer 3 and Layer 5 are independent defenses. Guard verdicts know nothing about authorities; they compose only at `turn-orchestration` |
| `runtime-governance` | `turn-orchestration` | **Customer/Supplier** | Customer/Supplier | Governance gates admission; the coordinator is explicitly the post-governance authority |
| `conversation-session` | `channel-integration` | **Customer/Supplier** | Customer/Supplier | Scoping model exists to serve channel routing; session-key shapes are driven by channel needs |
| `conversation-session` | `turn-orchestration` | **Customer/Supplier** | Customer/Supplier | Turn persistence and cursor-based crash recovery follow the session record's contract |
| `task-review` | `channel-integration` | **Customer/Supplier** | Customer/Supplier | Task side injects `TaskCreator`/`TaskLister` callbacks shaped for channel triggers; `ChannelTaskBridge` is the seam |
| `task-review` | `workflow-orchestration` | **Customer/Supplier** | Customer/Supplier | Workflow steps create coding tasks; authored step type survives as metadata (ADR-023, ADR-024) |
| `workflow-orchestration` | `operator-interface` | **Open Host Service** | OHS | Inverted: the engine publishes `WorkflowGitPort` / `WorkflowTurnAdapter`; server and CLI adapt to them (ADR-034) |
| `project-registry` | `task-review` | **Open Host Service** | OHS | `Task.projectId` is the consumer-side name |
| `project-registry` | `workflow-orchestration` | **Open Host Service** | OHS | `WorkflowDefinition.project` is the second consumer-side name for the same upstream – deliberately distinct terms |
| `knowledge-memory` | `tool-surface` | **Open Host Service** | OHS | `memory_apply`, `memory_observe`, `memory_search`, `memory_read`, `context_research` published as MCP tools |
| `knowledge-memory` | `turn-orchestration` | **Customer/Supplier** | Customer/Supplier | Bounded canonical-memory index projection is injected into every primary turn prompt |
| all contexts | `observability-alerting` | **Published Language** | Published Language | Sealed `DartclawEvent` hierarchy is the exchange format; subscribers never reach into domains (ADR-011) |
| all contexts | `operator-interface` | **Conformist** | Conformist _(accepted)_ | **D-1** – routes and templates import domain services directly (`api/` from 13 directories, `web/` from 11). Accepted for a server-rendered zero-JS UI; an ACL becomes worth its cost only if domain renames start rippling into templates |
| `tool-surface` | `execution-isolation` | **Customer/Supplier** | Customer/Supplier | Container executions reach `/mcp` only through the per-authority framed bridge |

### External

| Upstream | Downstream | Pattern | Notes |
|---|---|---|---|
| Provider CLI wire formats (`claude`, `codex`, ACP) | `provider-mediation` | **Conformist** | Vendor protocols cannot be negotiated; DartClaw reimplements them as specified |
| Provider CLI models | `provider-mediation` | **Anticorruption Layer** | `ProtocolAdapter` translates three incompatible vendor models into `BridgeEvent` + the canonical tool taxonomy, so provider drift stops at the adapter |
| Messaging platform APIs (WhatsApp/GOWA, signal-cli, Google Chat) | `channel-integration` | **Anticorruption Layer** | Per-platform adapters normalize to `ChannelMessage`; vendor quirks (sealed sender, two auth paths, dual slash-command shapes) stay inside the adapter |
| External MCP servers | `tool-surface` | **Conformist** | Their tool schemas are taken as given; only tools listed in `surface_tools` are surfaced, and the egress guard mediates every call |
| AndThen framework | `workflow-orchestration` (engine) | **Separate Ways** | Explicit non-integration, enforced by `check_no_framework_coupling.sh` (zero `andthen` literals in `lib/src/`) and ADR-041 |
| AndThen framework | `workflow-orchestration` (built-in definitions) | **Conformist** | The shipped YAML definitions name AndThen skills directly – the sanctioned home for framework semantics |
| Docker / OS platform | `execution-isolation` | **Conformist** | Docker semantics are taken as given; unavailability fails closed rather than degrading (Windows) |

---

## Ubiquitous Language

[UBIQUITOUS_LANGUAGE.md](../state/UBIQUITOUS_LANGUAGE.md) is grouped one `##` section per context, each heading
slugging to the id below (`Guarding & Audit` → `guarding-audit`). This document owns context identity; the glossary
owns the terms. Listed here are only the terms whose meaning is contested or load-bearing at a boundary – the
glossary's [Overloaded Terms](../state/UBIQUITOUS_LANGUAGE.md#overloaded-terms) table carries the full disambiguation.

| Context | Contested / load-bearing terms |
|---|---|
| `provider-mediation` | **Bridge** (vs. container bridge), **Capability** (harness capability vs. platform capability), Protocol Adapter, Canonical Tool Taxonomy |
| `execution-isolation` | **Principal**, **Container Authority**, **Host Gateway**, **Bridge**, Execution Policy, Security Profile |
| `guarding-audit` | **Audit** (guard evidence vs. observability trace), Guard Verdict, egress guard, Tool Approval Request |
| `turn-orchestration` | **Turn**, **Worker**, **Context** (context window vs. Workflow Context vs. Context Engine – triple overload), Execution Lease, Execution Fingerprint, Logical Agent |
| `runtime-governance` | **Budget** (governance daily tokens vs. workflow step budget), Emergency Control, Loop Detector |
| `conversation-session` | **Session** (record vs. platform chat thread), Session Key, Session Scope, Cursor |
| `channel-integration` | **Thread** (Google Chat thread vs. Dart threading), **Message** (channel DTO vs. persisted record), Thread Binding, Sender Attribution |
| `task-review` | **Type** (task type vs. workflow step type), **Merge** (task-to-main vs. workflow Promotion), Worktree, Task Project ID, Scheduled Job (the scheduling entity – not a Task) |
| `workflow-orchestration` | **Context**, **Drain**, **Project** (Workflow Project vs. Task Project ID), Promotion Conflict, Serialize-remaining |
| `knowledge-memory` | **Context Engine** (synthesis layer, explicitly *not* the turn context assembler), Canonical Memory Entry, Memory Locator, Search Index, citation packet |
| `tool-surface` | **Tool** (MCP tool vs. canonical taxonomy name), outbound MCP client, surface_tools |
| `project-registry` | **Project** – three distinct senses across contexts, all three now separated in the glossary |
| `configuration-platform` | Composed Config, Reconfigurable Service, Behavior Files, **Capability** |
| `operator-interface` | Connected Mode, Standalone Mode, API Client, Server Detection |
| `observability-alerting` | **Event** (`DartclawEvent` vs. `BridgeEvent` vs. `TaskEvent` vs. DDD domain event), **Audit**, Alert Routing |

---

## Observed Structure vs. Contexts

Packages are the observed modules; contexts are the linguistic boundaries. Where they diverge:

| Package | Contexts hosted | Gap |
|---|---|---|
| `dartclaw_server` | `turn-orchestration`, `execution-isolation`, `task-review`, `tool-surface`, `operator-interface`, `observability-alerting`, `runtime-governance`, `project-registry` (+ parts of 4 more) | Eight contexts in one package with no intra-package boundary enforcement. The only structural signal is directory naming, and two directories are misnamed (D-2) |
| `dartclaw_core` | `provider-mediation`, `conversation-session`, `channel-integration` (interfaces), plus fragments of `turn-orchestration`, `task-review`, `knowledge-memory`, `runtime-governance` | "Core" is a dependency-position name, not a context. Its real invariant is *sqlite3-free and Flutter-shareable*, which cuts across contexts |
| `dartclaw_storage` | none | Pure adapter layer: SQLite implementations for `conversation-session`, `task-review`, `knowledge-memory`, `observability-alerting`. Correct as ports-and-adapters, but means "which context owns this table" is answerable only by reading imports |
| `dartclaw_config` | `configuration-platform` | Clean 1:1 |
| `dartclaw_workflow` | `workflow-orchestration` | Clean 1:1 – the only large context with its own package |
| `dartclaw_security` | `guarding-audit` (partial) | Clean, except `ToolPolicyGuard` sits in `dartclaw_core` to preserve the security package's leaf position – an acknowledged compromise |
| `dartclaw_bridge` | `execution-isolation` (wire contract) | Clean 1:1, and the strictest boundary in the repo (zero dependencies) |
| channel packages | `channel-integration` | Clean 1:3 – one context, three adapters |
| `dartclaw_models` | shared kernel | Clean |
| `dartclaw`, `dartclaw_testing` | none | Umbrella re-export and test doubles; no domain ownership |

**Hard constraint on any restructuring**: the fitness ceilings are effectively at their limits – 14 workspace members
against a ceiling of 14, and `dartclaw_core` at 20,944 LOC against a warn threshold of 20,700 and a hard fail at
21,050. New packages and code migrations *into* core both require an owner decision to raise a ceiling first
(`dev/tools/arch_check.dart`, ADR-033).

---

## Drift Findings

Findings survived an adversarial filter pass; downgraded items are stated at their filtered severity.

| Id | Gap | Root cause | Smallest closing move |
|---|---|---|---|
| **D-1** _(note)_ | `operator-interface` is Conformist to every context it renders, with no translation layer: `api/` imports 13 sibling directories (21 references to `task/` alone), `web/` imports 11 (43 to `templates/`), and `templates/` reaches back into `task/`, `session/`, `audit/`, `scheduling/`, `knowledge/` | Server-rendered UI grew alongside the domains it renders. Normal for this stack – no read-model seam was ever needed | None now. Recorded as the shape to watch: if a domain rename starts rippling into templates, introduce view-model DTOs for the highest-traffic pages first |
| **D-2** | Two `dartclaw_server` directories are misnamed relative to the contexts they serve: `config/` holds hot-reload *fan-out* wiring (it imports `behavior/`, `context/`, `workspace/`), not configuration; `emergency/` imports `../api/sse_broadcast.dart`, putting a safety-critical path downstream of the HTTP route layer | Vocabulary collision between `dartclaw_config` (the context) and `server/src/config/` (wiring), plus a transport helper filed under `api/` | Rename `server/src/config/` to `reconfiguration/`; move `sse_broadcast.dart` out of `api/` into a transport-neutral location. Both are renames – no behavior change |
| **D-3** _(downgraded)_ | `knowledge-memory` is spread across four packages: file services in `dartclaw_core`, persistence and search in `dartclaw_storage`, curation and knowledge hub in `dartclaw_server`, tools in `mcp/`, plus a loose `memory_handlers.dart` at the server package root | Layered decomposition by technical concern, applied to a context that also wants a model owner | Move `memory_handlers.dart` under `server/src/memory/`. Consolidation beyond that is blocked by the core LOC ceiling and the sqlite3 rule, and is not worth forcing |
| **D-4** ✅ _resolved 2026-08-14_ | The UL's `Bounded Context` column carried roughly 50 distinct ad-hoc labels ("Server orchestration", "Multi-provider", "Protocol spec", "Crash recovery", …) that mapped to no registered context | The glossary predated any context map – labels were invented per row | Closed: the glossary is regrouped one `##` section per context and the column is gone. Context identity now lives here, terms live there |
| **D-5** ✅ _resolved 2026-08-14_ | Scheduling had substantial behavior (cron/interval/once jobs, delivery modes, heartbeat, `ScheduledTaskRunner`) across ~1.2K LOC and **zero** glossary presence | Capability grew without a naming pass; it sits in `task-review` by adjacency rather than by decision | Closed: six scheduling terms added under `task-review` (Scheduled Job, Schedule Type, Cron Expression, Delivery Mode, Scheduled Task Definition, Heartbeat). It stays inside `task-review` – its size does not justify a context of its own |

No drift against a previously registered Context Map – this is the first registration.

**Recorded non-issues** – considered and dismissed, so the reasoning is not re-derived later:

- **Context count vs. cognitive load.** 15 contexts against the "2–3 per team" heuristic looks alarming, but the
  heuristic bounds *team* hand-offs, and there is one maintainer and no team boundary to cut across. The real bound is
  the auditability principle, already governed by LOC ceilings. No action.
- **Merging `tool-surface` into `provider-mediation`.** Superficially attractive (both are the host↔provider
  contract), but they run in opposite directions with different trust boundaries, and ADR-039 already settles the
  outbound one. Nothing is forcing the question. No action.

---

## Recommendations

Ordered by value per unit of effort.

1. **Close D-2 – both moves are renames.** `server/src/config/` vs. `dartclaw_config` is a live vocabulary collision,
   and a safety path (`emergency/`) depending on the route layer is an inversion that will resist testing. Near-zero
   cost, immediate clarity.
2. **Settle H-1 before the next workflow investment.** It is the one decision here with a real forcing function
   (a LOC ceiling already raised once) and it changes what the next raise means. Hand off:
   `andthen:architecture --mode decompose` scoped to `workflow-orchestration` vs. `task-review`.
3. **Do not split `dartclaw_server`.** Eight contexts in one package is real, but the workspace package ceiling is
   *at* 14, `dartclaw_core` is inside its warn band, and the philosophy is explicit about staying lean. This map is
   the boundary record; adding fitness machinery to police a map written today would be the ceremony the project
   rules out. Revisit only if a split is actually proposed.
4. ~~**Regroup the glossary onto these ids** (D-4) and add the Scheduling cluster (D-5).~~ **Done 2026-08-14** – the
   glossary is now one `##` section per context and points back here for context identity.
5. **Leave the context count alone.** Every one of the 15 has a genuine linguistic claim: the UL already documents
   nine overloaded terms across them, which is evidence the boundaries were discovered, not invented.

### Hotspot

One unresolved call, recorded rather than forced. It needs an owner decision.

**H-1 – Is `workflow-orchestration` core or supporting?**
_For core_: deterministic host-driven pipelines are a stated differentiator against prompt choreography; the git
branch topology (integration/story branches, promotion, agent-resolved merge) has no off-the-shelf equivalent; it
carries the richest vocabulary in the glossary.
_For supporting_: it is the largest context in the repo (~25.9K LOC against a 30K ceiling, raised once already) inside
a product whose stated philosophy is "minimal viable scope per milestone" and "when in doubt, leave it out"; a general
agent runtime does not obviously need a workflow engine to be differentiated; and the workspace `CLAUDE.md` notes
Workflow Studio may be built in the separate smiðia repo rather than here.
_Why it matters_: a supporting classification caps further investment and makes the 30K ceiling a stop sign rather
than a bump. A core classification justifies the next raise.

---

## Changelog

- 2026-08-14: D-4 and D-5 closed by the `andthen:ubiquitous-language` run – the glossary is regrouped one section per
  context and carries the scheduling vocabulary. Ubiquitous Language section rewritten to match: cluster names dropped
  (the mapping is now 1:1), contested terms retained.
- 2026-08-14: Initial registration. Brownfield strategic-design run over the whole repository – 16 subdomains,
  15 bounded contexts, one shared kernel. Findings passed an adversarial filter: 5 drift findings retained
  (D-1…D-5, two downgraded), one hotspot (H-1), two candidate findings dismissed as non-issues.
