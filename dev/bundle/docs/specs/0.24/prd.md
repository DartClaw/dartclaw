# PRD – 0.24 Logical-Agent Correctness and Scheduling Operability

> **Durable milestone record.** This PRD is the sole persistent plan-bundle record of the requirements, decisions, discovered requirements, implementation, and acceptance evidence for 0.24. `plan.json`, story FIS files, and review reports supported execution and may retain superseded implementation-time terminology; they are transient and are not authoritative after the milestone closes. Execution repo: `dartclaw-public`; branch: `feat/0.24`.

## Status

Implemented and verified. The four planned features, logical-agent/session consolidation, and final execution-authority, worker-capacity, reuse, and lifecycle correction are complete.

## Problem and Goal

0.24 began with four accepted needs:

1. Agent-specific tool and network policy existed in configuration but was not reliably enforced on live provider calls.
2. Agent persona/model configuration was not applied consistently, and background agent work could not run while the caller occupied the primary harness.
3. Daily turn logs lacked an opt-in process for curating durable memory.
4. Scheduled prompt jobs could not be triggered immediately through normal operator surfaces.

Implementation exposed a deeper design error: `sessions_send` mixed conversation creation and continuation, while `delegate_to_agent` duplicated the same use case through provider-specific machinery. Subsequent convergence also found that idle harness objects, capacity, and routing authority were still conflated. The final goal therefore became one provider-independent logical-agent model with durable DartClaw sessions, host-owned policy, one post-governance execution authority, and bounded execution capacity independent from opportunistic process reuse.

## Product Requirements

### R1 – Live agent tool-policy enforcement

- Every live host interception path receives the active logical-agent identity and evaluates the global plus agent policy cascade.
- Allow/deny entries match raw provider names and canonical DartClaw semantics. Known own-MCP tools map exactly: search to `web_search`, fetch to `web_fetch`, and memory persistence to `memory_save`. Unknown, third-party, session, task, and other generic MCP calls remain `mcp_call`.
- Denying `mcp_call` denies all MCP calls, including semantically mapped own-MCP calls. Allowing `mcp_call` does not grant exact mapped capabilities.
- Per-agent network additions apply only to that agent. Own-MCP `web_fetch` is subject to `NetworkGuard` for main and logical-agent turns; null agent identity is not an exemption.
- Provider interception limitations remain explicit. Claude supplies the complete host hook. Codex enforcement depends on approval routing, and ACP enforcement covers only calls surfaced through its permission/reverse-call seams. Startup and documentation must not overstate these boundaries.
- Removed or unenforced agent spawn keys produce migration warnings and never leak into provider payloads.

### R2 – One logical-agent conversation model

- Logical agents are named execution profiles under `agent.agents`. An `AgentDefinition` owns prompt/persona, optional provider, optional model and effort, tool policy, provider-independent security profile, and response-size limit.
- `sessions_spawn(agent, message)` creates a new durable hidden logical-agent session, runs its first turn, and returns both `session_id` and the guarded result.
- `sessions_send(session_id, message)` continues exactly the logical-agent session identified by that handle. It never resolves an agent's shared or main conversation implicitly.
- `delegate_to_agent`, `delegation:`, `SessionDelegate`, `SubagentLimits`, and provider-native agent registration are removed. Their useful policy/persona/model/guard behavior is consolidated into `AgentDefinition` and the ordinary turn path.
- DartClaw session state is authoritative across providers. Each logical-agent session persists its selected provider, security profile, messages, and lifecycle type. It remains hidden from ordinary session/sidebar lists, is explicitly addressable for diagnostics, and participates in normal count and age pruning.
- An omitted logical-agent provider inherits the configured primary provider. An omitted model uses that provider's normal default. No provider-specific logical-agent model default or environment override is injected.
- Provider IDs are trimmed and lowercased across configuration, agent references, runtime maps, workflow discovery, auth preflight, and provisioning. Blank IDs and normalization collisions are rejected rather than routed ambiguously.
- A logical-agent turn acquires an exact provider/security-profile worker and never falls back to the caller's primary harness or to a weaker profile. Explicit `restricted` execution fails closed when isolation is unavailable; `workspace` must be selected explicitly when host access is acceptable.
- Successful results pass through the content guard and UTF-8 byte limit before returning to the caller. A failed or blocked initial spawn is archived because no resumable handle was delivered.
- Logical agents may start other logical-agent sessions when ordinary tool policy permits and worker capacity remains. Capacity exhaustion fails immediately rather than waiting on a worker held by the caller.

### R3 – Provider-neutral continuity with adapter-local mechanics

- Every provider exposes the same DartClaw logical-session contract. Product orchestration must not branch on provider identity.
- Provider branching is confined to provider adapters and composition/wiring. Scheduling, task, logical-agent, governance, and observability code consume provider-neutral execution contracts.
- Provider-specific handling is limited to external protocol mechanics required to preserve the contract:
  - Codex associates its native threads with DartClaw session IDs.
  - Claude's stateful process restarts when a reused worker switches logical sessions, then receives only the selected session's persisted history.
  - ACP creates a fresh provider session and receives bounded replay-safe persisted history on each turn.
- Reusing a worker must never make provider-local state authoritative or allow state from one DartClaw session to leak into another.

### R4 – Shared bounded worker capacity

- After global turn governance admits a request, one execution coordinator is the sole authority for lane selection, admission, capacity leases, worker reuse, replacement, and release.
- The configured primary provider has one fixed serialized primary-interactive lane for main-agent user and channel turns. Cron and other system jobs, advisor turns, background tasks, and logical-agent sessions never use this lane.
- `providers.<id>.pool_size` is the sole worker-capacity setting and a hard per-provider ceiling on concurrent worker executions. It excludes the fixed primary-interactive lane. `tasks.max_concurrent`, agent-specific quotas, cached process count, and container count do not affect the ceiling.
- Worker surfaces acquire a provider capacity lease before execution. Ordinary worker turns may wait; nested logical-agent acquisition remains fail-fast so a child cannot wait on capacity held by its caller.
- Workflow one-shots acquire the same provider capacity lease but are capacity-only executions: they spawn their bounded CLI process directly and never enter the reusable harness cache.
- Reusable harnesses are an opportunistic cache, not capacity. There are no cache-size, TTL, prewarm, or reuse-policy knobs. Lookup prefers the exact session within the requested canonical construction fingerprint, then any healthy worker with a compatible fingerprint; an unknown compatibility or health state requires a fresh worker.
- A released unhealthy worker is disposed, not cached. Replacement requires confirmed teardown of the managed root process; if confirmation is unavailable, the capacity slot is quarantined instead of spawning a potentially overlapping replacement.
- Containers are amortized independently from harness processes and capacity leases. A long-lived profile container may serve multiple executions without becoming conversation state or changing `pool_size` accounting.
- Runtime busy/free/current-work state is derived from coordinator leases. Cached harness state may enrich diagnostics but is not execution authority.
- SDK compositions that supply only one harness retain a compatibility exception: absent multi-worker coordination, ordinary background tasks may serialize on that harness. The server runtime and logical-agent routing do not use this exception.
- The separate global `max_parallel_turns` setting remains a pre-coordinator server admission boundary, not a worker-capacity control.

### R5 – Human-conversation onboarding scope

- A fresh `ONBOARDING.md` applies to every human-facing conversational transport: Web UI, configured messaging channels, and future interactive transports.
- It is excluded from tasks, cron, workflows, evaluators, and logical-agent turns.
- The scoped prompt contract works across supported providers without persisting onboarding or logical-agent prompt residue into later unrelated turns.

### R6 – Built-in memory journal

- `memory.journal.enabled: true` registers exactly one `memory-journal` SYSTEM prompt job; default is off. `memory.journal.schedule` controls its schedule.
- Registration fails clearly if a user-defined job already uses the reserved ID or name. Disabled deployments remain unaffected.
- The journal reads the current daily turn log and curates decisions, insights, and action items into `MEMORY.md` through exact `memory_save` calls. Journal, existing size-cap consolidation, and pruning remain separate concepts and names.
- The turn receives a closed policy: file read plus exact `memory_save`. Shell, network, delegation/session/task tools, generic MCP, direct file write/edit, and unrelated memory tools remain denied.
- When Claude requires `ToolSearch` to discover own MCP tools, discovery is allowed only when exact `memory_save` is granted. That helper must not grant the discovered tool itself, unrelated MCP tools, or any capability under a toolless policy.
- Authentication-enabled MCP requires the bearer token. When gateway authentication is disabled, unauthenticated MCP may be advertised and mounted only on loopback; non-loopback auth-disabled deployments must not expose it.
- The built-in row is marked runnable so it participates in the generic on-demand action contract.

### R7 – Run scheduled prompt jobs on demand

- `ScheduleService` exposes one on-demand seam with scheduled-fire parity for prompt-type jobs.
- Operators can trigger it through:
  - `dartclaw jobs run <name>`
  - `POST /api/scheduling/jobs/<name>/run`
  - the Web UI Run action
- A successful request acknowledges start without waiting for completion. Unknown, non-runnable, and already-running jobs return distinct errors.
- Manual execution uses the configured prompt, delivery, retry, project, tool policy, and other scheduled-fire behavior, while leaving timer cadence, pause state, and next-run state untouched.
- Callback-only jobs and scheduled task definitions remain non-runnable through this seam. No per-run overrides, restart-pending queue, or run-history subsystem is introduced.

### R8 – Clear operational language

- **Logical agent** means a named execution profile; **logical-agent session** means its durable conversation.
- **Harness** means the provider protocol adapter; **runner** means an observable host turn runner; **worker** means pooled background execution capacity.
- Observability surfaces use runner language: CLI `runners`, API `/api/runners`, SSE `runner_state`, and `RunnerObserver`.
- UI pool counts exclude the primary runner and state the relationship explicitly, for example `1 primary + 1 worker`.

## Architectural Decisions

1. **Host-owned orchestration.** DartClaw owns logical-agent identity, lifecycle, persistence, guards, and routing. Provider-native agent features are not a second orchestration API. This supersedes the initial two-tier native-subagent decision and is recorded in `dev/state/DECISIONS.md` and the 2026-08-09 addendum to ADR-003.
2. **Sessions are canonical; workers are replaceable.** Durable DartClaw state is replayed or resumed through adapter capabilities. A pooled harness is never the record of a conversation.
3. **One capacity boundary and one authority.** A post-governance execution coordinator owns the fixed primary lane and per-provider worker leases. `pool_size` limits concurrent worker execution; cached harnesses and containers are independently amortized resources.
4. **Security fails closed.** Exact provider/profile routing, provider-ID normalization, closed tool semantics, and loopback-only unauthenticated MCP avoid convenience fallbacks that weaken policy.
5. **Adapter differences require evidence.** Provider-specific code is acceptable only in adapters and composition/wiring where an external protocol demands it and tests prove the common continuity/isolation contract.
6. **Breaking cleanup over compatibility scaffolding.** The project is pre-alpha; obsolete APIs and configuration are removed, with targeted parser/documentation warnings rather than parallel legacy runtime paths.

## Changes from the Initial Plan

The original F2 design treated `sessions_send` as both spawn and send, retained `delegate_to_agent`, named sessions `delegated`, registered Claude-native agents, and supplied provider-specific search model defaults. Validation showed that this duplicated orchestration, obscured conversation identity, and produced provider-dependent behavior. The delivered design therefore:

- split creation and continuation into `sessions_spawn` and handle-based `sessions_send`;
- renamed the domain from delegated sessions to logical-agent sessions;
- removed the parallel delegation API/configuration and provider-native agent registration;
- made provider and security profile part of persisted session identity;
- removed special search-agent model selection in favor of the chosen provider's default;
- narrowed the pool from task/delegation state machinery to shared bounded worker capacity;
- renamed agent-process observability to runner/worker terminology;
- added exact normalization, hard-cap, fail-closed profile, reconstruction, and cross-session continuity requirements.

The implemented final correction separates admission, execution capacity, and process reuse: one coordinator owns all post-governance execution; the primary-interactive lane is fixed and serialized; worker `pool_size` is lease capacity rather than a process-count target; workflow one-shots consume capacity without entering the cache; reuse is fingerprinted and opportunistic; and unconfirmed teardown quarantines capacity.

These are accepted requirement and design changes, not compatibility defects against the transient FIS wording.

## Migration

| Removed/renamed surface | Replacement |
|---|---|
| `delegate_to_agent` | `sessions_spawn`, then `sessions_send` with the returned handle |
| `delegation:` | logical-agent definitions under `agent.agents` |
| `tasks.max_concurrent` | `providers.<id>.pool_size` |
| CLI `agents` | CLI `runners` |
| `/api/agents` | `/api/runners` |
| SSE `agent_state` | `runner_state` |

Removed configuration keys are recognized only to produce migration warnings. They do not create runtime state or widen policy.

## Acceptance Evidence

- A throwaway runnable spike separated capacity from caching and measured the actual reuse envelope. A capacity-one gate queued for about 64 ms and recovered after an exception; a workflow one-shot held the former worker lease for about 293 ms without invoking its harness. Claude 2.1.226 measured 1,075 ms startup, 3,011 ms cold execution, 1,150 ms exact-session warm execution, and 4,050 ms after a session switch. Codex 0.146.0 kept one App Server across A→B→A; ACP kept one initialized process while creating fresh provider sessions. Container lifecycle was independently amortized.
- Structural checks prove production execution surfaces use the single post-governance coordinator, obsolete pool/coordinator constructs are removed, and provider identity branching remains confined to adapters and composition/wiring.
- Routing tests prove the coordinator derives the lane from the execution surface: clients cannot choose one. Main user/channel turns serialize on the fixed primary lane while retaining distinct execution provenance; cron/system jobs, advisor turns, tasks, and logical-agent sessions use the selected provider's worker capacity. The SDK single-harness background compatibility path serializes and cannot serve server logical-agent execution.
- Gate and coordinator tests prove FIFO queueing, prompt failure of queued/future waiters after final-slot quarantine, fail-fast acquisition, release after success/error/cancellation, hard per-provider capacity, capacity-only one-shots without unused harness construction, exact provider/profile isolation, exact-session affinity before compatible-fingerprint reuse, fresh construction for incompatibility, cache scavenging, and truthful lease events/snapshots.
- Lifecycle tests prove turn-token-owned guard reset, lease release only after provider cleanup, paired admission callbacks, single-owner session admission, fail-closed continuity reset during active and pending acquisition, rejection and teardown of non-idle factory results, disposal after failed cancellation recovery even when the harness later reports idle, independent stop/dispose cleanup after failed startup, confirmed replacement, unconfirmed-root quarantine, capacity health degradation, shutdown draining of delayed worker creation, idempotent concurrent shutdown, and no cross-session lock or provider-state leakage.
- Observability tests prove busy/free/current-work state comes only from leases; terminal outcomes update primary and worker metrics exactly once at the shared runner-settlement seam; disposed workers leave current runner registries; and fingerprint churn cannot accumulate stale runner rows or references.
- Provider-routing tests prove mixed-case task overrides are normalized before persistence and exact runtime-map lookup.
- Provider continuity tests prove Claude A→B→A process isolation and bounded replay, Codex per-session thread identity, and ACP bounded replay through fresh provider sessions on a compatible initialized process.
- Reconstruction and security tests prove logical-agent handles retain exact provider, profile, and history; exact own-MCP semantic mapping, deny-union behavior, network overrides, primary/worker ACP permission-callback parity with isolated runner policies, restricted-profile fail-close, authenticated bearer enforcement, and auth-disabled loopback-only MCP exposure remain intact.
- Terminal-outcome tests prove polling, waiting, status lookup, SSE reconnect, and idempotent cancellation remain available through the configured TTL after an opportunistic worker is disposed, without retaining that runner; reset and exact expiry remove the retained outcome.
- Full workspace verification passes formatting, fatal static analysis, every package/application suite, 8/8 architecture checks, fitness checks, and `git diff --check`.
- Desktop and mobile visual validation passes for Tasks execution capacity and Settings provider capacity with canonical meters, zero scoped accessibility violations, no horizontal overflow, and no browser console/page errors.

## Deferred

- Caller cancellation does not yet propagate causally into an in-flight `sessions_spawn` or `sessions_send` child turn because MCP dispatch does not carry typed caller turn identity. The safe solution is exact parent→child tracking and cancellation, not a global active-child shortcut. This is TD-119, scheduled with caller-aware MCP dispatch work in 0.27.
- Stronger Codex/ACP live tool interception depends on upstream provider protocol surfaces. Current documentation and warnings state the actual enforcement boundary.

## Non-Goals

- A second provider-native logical-agent API or provider-specific orchestration contract.
- Per-agent capacity quotas, independent delegation budgets, or unbounded process spawning.
- Cache tuning, prewarming, TTLs, or coupling process/container counts to execution capacity.
- Provider-specific routing or observability behavior outside adapters and composition/wiring.
- Making provider-local conversation state authoritative.
- Silent security-profile fallback or automatic pool expansion.
- Memory-journal delivery/model/prompt knobs, deterministic empty-day prechecks, or changes to consolidation/pruning.
- Synchronous scheduled-job completion waits, per-run overrides, run history, or callback-job execution.

## Story Traceability

- **S01:** Live agent tool/network policy enforcement and exact cross-provider semantic mapping.
- **S02:** Persona/model/onboarding application, reachable background execution, logical-agent/session consolidation, and the final execution-authority correction described above.
- **S03:** Opt-in built-in memory journal, exact closed tool boundary, loopback MCP availability, and live persistence proof.
- **S04:** Generic on-demand scheduled prompt jobs through CLI, API, and Web UI.

The story artifacts preserve execution detail and proof provenance. This PRD preserves the final 0.24 product contract.
