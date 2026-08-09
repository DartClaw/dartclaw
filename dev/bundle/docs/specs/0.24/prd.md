# PRD – 0.24 Logical-Agent Correctness and Scheduling Operability

> **Durable milestone record.** This PRD is the persistent plan-bundle record of the requirements, decisions, discovered requirements, and delivered outcomes for 0.24. `plan.json`, story FIS files, and review reports supported execution and may retain superseded implementation-time terminology; they are transient and are not authoritative after the milestone closes. Execution repo: `dartclaw-public`; branch: `feat/0.24`. Originally authored 2026-08-05; reconciled to the delivered design 2026-08-09.

## Status

Implemented and verified on 2026-08-09. The milestone delivered four planned features and a post-implementation consolidation of the logical-agent/session architecture uncovered while validating the original delegation design.

## Problem and Goal

0.24 began with four accepted needs:

1. Agent-specific tool and network policy existed in configuration but was not reliably enforced on live provider calls.
2. Agent persona/model configuration was not applied consistently, and background agent work could not run while the caller occupied the primary harness.
3. Daily turn logs lacked an opt-in process for curating durable memory.
4. Scheduled prompt jobs could not be triggered immediately through normal operator surfaces.

Implementation exposed a deeper design error: `sessions_send` mixed conversation creation and continuation, while `delegate_to_agent` duplicated the same use case through provider-specific machinery. The final goal therefore became one provider-independent logical-agent model with durable DartClaw sessions, host-owned policy, and bounded state-free execution capacity.

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
- Provider-specific handling is limited to external protocol mechanics required to preserve the contract:
  - Codex associates its native threads with DartClaw session IDs.
  - Claude's stateful process restarts when a reused worker switches logical sessions, then receives only the selected session's persisted history.
  - ACP creates a fresh provider session and receives bounded replay-safe persisted history on each turn.
- Reusing a worker must never make provider-local state authoritative or allow state from one DartClaw session to leak into another.

### R4 – Shared bounded worker capacity

- Logical-agent sessions never acquire the primary runner. Background tasks and logical-agent sessions share a bounded pool of additional workers; the existing single-harness task mode may use an idle primary only when worker capacity is disabled.
- `providers.<id>.pool_size` is the only worker-capacity setting. The value is a hard ceiling, including initially supplied and lazily provisioned workers. `tasks.max_concurrent` and agent-specific concurrency quotas are removed.
- A worker is execution capacity only. It may be matched by provider and security profile, but it owns no durable conversation, agent identity, or delegation lifecycle.
- Pool provisioning coalesces concurrent requests, respects exact provider/profile requirements, and never silently grows beyond configured capacity.
- The separate global `max_parallel_turns` setting remains a server admission boundary, not a worker-capacity control.

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
3. **One capacity boundary.** Provider worker pools cover logical-agent turns and structured background tasks. Duplicate task and delegation quotas were removed.
4. **Security fails closed.** Exact provider/profile routing, provider-ID normalization, closed tool semantics, and loopback-only unauthenticated MCP avoid convenience fallbacks that weaken policy.
5. **Adapter differences require evidence.** Provider-specific code is acceptable only where an external protocol demands it and tests prove the common continuity/isolation contract.
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

## Acceptance and Evidence

- Full workspace verification passed: format, fatal static analysis, every package/application suite, 8/8 architecture checks, 31/31 fitness checks, and `git diff --check`.
- Provider continuity tests prove Claude A→B→A process isolation and replay, Codex per-session thread identity, and ACP bounded replay on fresh provider sessions.
- Reconstruction tests prove a logical-agent handle retains exact provider, profile, and history after service and worker reconstruction.
- Capacity tests prove constructor, lazy growth, profile-specific acquisition, nested exhaustion, and provider-specific acquisition cannot exceed the hard ceiling.
- Security tests prove exact own-MCP semantic mapping, deny-union behavior, network overrides, restricted-profile fail-close, auth-enabled bearer enforcement, and auth-disabled loopback-only MCP exposure.
- A production Claude smoke created a logical-agent worker while the primary caller remained active, applied persona/model configuration, returned the guarded result, and released the worker.
- Production memory-journal smokes proved authenticated and auth-disabled-loopback `memory_save`, categorized `MEMORY.md` persistence, exact `ToolSearch` discovery, and denial of sibling memory capabilities.
- Desktop and mobile visual validation passed for Tasks, Settings provider capacity, New Task, and active SYSTEM job states with no layout overflow or browser errors.

## Deferred

- Caller cancellation does not yet propagate causally into an in-flight `sessions_spawn` or `sessions_send` child turn because MCP dispatch does not carry typed caller turn identity. The safe solution is exact parent→child tracking and cancellation, not a global active-child shortcut. This is TD-119, scheduled with caller-aware MCP dispatch work in 0.27.
- Stronger Codex/ACP live tool interception depends on upstream provider protocol surfaces. Current documentation and warnings state the actual enforcement boundary.

## Non-Goals

- A second provider-native logical-agent API or provider-specific orchestration contract.
- Per-agent capacity quotas, independent delegation budgets, or unbounded process spawning.
- Making provider-local conversation state authoritative.
- Silent security-profile fallback or automatic pool expansion.
- Memory-journal delivery/model/prompt knobs, deterministic empty-day prechecks, or changes to consolidation/pruning.
- Synchronous scheduled-job completion waits, per-run overrides, run history, or callback-job execution.

## Story Traceability

- **S01:** Live agent tool/network policy enforcement and exact cross-provider semantic mapping.
- **S02:** Persona/model/onboarding application, reachable background execution, and the logical-agent/session consolidation described above.
- **S03:** Opt-in built-in memory journal, exact closed tool boundary, loopback MCP availability, and live persistence proof.
- **S04:** Generic on-demand scheduled prompt jobs through CLI, API, and Web UI.

The story artifacts preserve execution detail and proof provenance. This PRD preserves the final 0.24 product contract.
