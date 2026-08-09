# ADR-016: Multi-Provider Agent Harness Architecture

**Status:** Accepted. Implemented in 0.13; **partially amended by [ADR-037](037-universal-acp-harness.md)** for the ACP adapter family; execution-routing amendment implemented in 0.24.
**Date:** 2026-03-22 (validated 2026-03-24)
**Deciders:** DartClaw team
**Research:** [Research appendix](research/016-multi-provider-harness-architecture.md)
**Depends on:** [ADR-007: System Prompt Architecture](007-system-prompt-architecture.md)

## Context

DartClaw is locked to a single LLM provider (Anthropic) via the `claude` binary. The `AgentHarness` interface (ADR-007, shipped 0.2) was designed for multiple implementations, but only `ClaudeCodeHarness` exists. Competitive pressure (Maestro supports 6 backends, OpenClaw forks add OpenAI) and strategic opportunity (Codex CLI's `app-server` protocol is structurally analogous to DartClaw's existing JSONL control protocol) make this the right time to ship a second harness.

Three contested architectural dimensions need resolution before implementation:

1. **Tool name abstraction**: Guards hardcode Claude tool names (`Bash`, `Read`, `Write`). Codex uses different names (`command_execution`, `file_change`). How should the guard chain evaluate tool calls from different providers?

2. **Pool composition**: `HarnessPool` manages `TurnRunner` workers. Can different workers use different providers simultaneously, or must a deployment be homogeneous?

3. **Protocol abstraction**: `ClaudeCodeHarness` (788 LOC) mixes lifecycle management with protocol parsing. How should protocol logic be structured for extensibility?

### Design Principles Applied

- **Minimal attack surface** — single set of guard rules, not N copies per provider
- **Auditable** — architecture should be self-documenting; shared contracts over duplicated logic
- **Lean dependencies** — minimal new abstractions; leverage existing interfaces

### Decision Drivers

- Per-task provider override (F14) is a stated requirement — pool composition must support it
- PRD F03 already scopes protocol extraction — marginal cost of an interface is ~20 LOC
- Guard chain is the security boundary — tool name handling is security-critical
- Meta-principle: default to the same approach as Claude Code unless there's a clear reason to deviate

## Decision

### Part 1: Canonical Tool Taxonomy

**We will define a DartClaw-canonical set of tool categories with per-provider mapping.**

Guards evaluate canonical names, not provider-specific strings. Each protocol adapter maps provider-native tool names to canonical before guard chain evaluation.

Initial taxonomy:

| Canonical | Claude Code | Codex | Guard Consumers |
|-----------|-------------|-------|-----------------|
| `shell` | `Bash` | `command_execution` | CommandGuard, FileGuard, NetworkGuard |
| `file_read` | `Read` | (via `command_execution`) | FileGuard |
| `file_write` | `Write` | `file_change` (kind: create) | FileGuard |
| `file_edit` | `Edit` | `file_change` (kind: update) | FileGuard |
| `web_fetch` | `WebFetch` / DartClaw MCP `web_fetch` | DartClaw MCP `web_fetch` | NetworkGuard |
| `web_search` | `WebSearch` | `web_search` | ToolPolicyGuard |
| `memory_save` | DartClaw MCP `memory_save` | DartClaw MCP `memory_save` | ToolPolicyGuard |
| `mcp_call` | (via MCP) | `mcp_tool_call` | ToolPolicyGuard |

Amendment (2026-08-08): exact DartClaw MCP fetch, search, and memory-save tools map to their semantic canonicals on
Claude and Codex; unknown and third-party MCP tools remain `mcp_call`.

Unmapped tools pass through with `provider:name` prefix (e.g., `codex:reasoning`). Warning logged. `ToolPolicyGuard` can block unknown tools via configurable policy.

### Part 2: Heterogeneous HarnessPool

**We will allow mixed-provider workers in a single `HarnessPool`.**

This is the 0.13 baseline. Part 4 retains heterogeneous provider execution but supersedes runner-count capacity and direct pool-acquisition semantics.

`HarnessFactory` creates workers based on per-provider pool size config. Pool acquisition gains provider affinity (`tryAcquireForProvider()`). Primary worker always uses the default provider.

```yaml
providers:
  claude:
    pool_size: 2    # 2 worker executions; primary lane is separate
  codex:
    pool_size: 2    # 2 task workers
```

### Part 3: Abstract ProtocolAdapter Interface

**We will extract protocol logic into an abstract `ProtocolAdapter` interface with per-provider implementations.**

The adapter translates between provider-specific wire protocol and DartClaw's `BridgeEvent` / control model. Harnesses become thin lifecycle managers (spawn, restart, stop, I/O) that delegate protocol logic to the adapter.

```dart
abstract class ProtocolAdapter {
  ProtocolMessage? parseLine(String line);
  Map<String, dynamic> buildTurnRequest({...});
  Map<String, dynamic> buildApprovalResponse(String requestId, {required bool allow, ...});
  CanonicalTool? mapToolName(String providerToolName);
}
```

### Part 4: One Execution Authority, Capacity Leases, and Opportunistic Reuse

The heterogeneous pool decision is refined as follows. After global turn governance, one execution coordinator is the only authority that selects a lane, admits execution, issues capacity leases, reuses or creates harnesses, and releases or quarantines capacity.

There are three execution lanes:

| Lane | Surfaces | Capacity contract |
|---|---|---|
| Primary interactive | Main-agent user and channel turns | One fixed serialized lane on the configured primary provider; outside `pool_size` |
| Worker | Cron/system jobs, advisor turns, background tasks, logical-agent sessions | One lease from the selected provider's `pool_size`; reusable harness permitted |
| Capacity-only | Workflow one-shot provider invocations | One lease from the selected provider's `pool_size`; no reusable harness |

`providers.<id>.pool_size` is therefore a hard ceiling on concurrent worker and capacity-only executions for that provider, not a target number of live processes. Cached harnesses and long-lived profile containers do not consume capacity while idle. The global turn-governance limit remains an earlier admission boundary and does not replace provider capacity.

Reusable harnesses form a small opportunistic cache with no operator knobs. A worker request carries a canonical construction fingerprint consisting of the normalized provider, security profile, and canonical identity of all other construction-only configuration. Lookup order is:

1. a healthy cached worker for the exact session within the requested canonical construction fingerprint;
2. any healthy cached worker with a compatible canonical construction fingerprint;
3. a fresh worker.

Unknown compatibility or health means fresh creation, never speculative reuse. A released unhealthy worker is disposed. Before a worker is replaced, DartClaw must confirm termination of the managed root process. If confirmation is unavailable, the lease's capacity slot is quarantined and effective provider capacity decreases; no overlapping replacement is spawned.

Container amortization is independent. Profile containers may remain alive across process disposal and multiple leases, but they carry no session identity and do not alter capacity accounting.

The server derives runner activity and capacity observability from active leases rather than mutable idle/busy callbacks. This includes capacity-only workflow executions that have no reusable runner. Provider-specific branching is confined to protocol adapters and composition/wiring; coordinator clients use provider-neutral requests and leases.

SDK consumers that construct only one harness retain a compatibility exception: ordinary background tasks may serialize on that harness when no multi-worker coordinator exists. Server logical-agent execution never uses this exception.

## Consequences

### Positive

- **Security**: Single set of guard rules evaluated consistently across all providers. No risk of provider tool names slipping through unmapped.
- **Extensibility**: Adding a third provider (Pi, DirectApi, ACP) means implementing one `ProtocolAdapter` + one tool name mapping table. No guard changes, no pool changes.
- **Per-task flexibility**: Heterogeneous pool enables "Claude for chat, Codex for coding tasks" in a single deployment.
- **Bounded execution**: Per-provider leases bound all worker surfaces, including one-shots, independently from process reuse.
- **Safe reuse**: Canonical fingerprints and teardown confirmation prevent cross-session/configuration leakage and overlapping replacements.
- **SDK clarity**: Canonical tool names and `ProtocolAdapter` interface are clean SDK surface for consumers building custom harnesses.
- **Auditability**: Shared contracts (adapter interface, canonical taxonomy) make the multi-provider architecture self-documenting.

### Negative

- **Upfront taxonomy design**: Canonical tool categories must be defined before a third provider validates the taxonomy. Risk of premature abstraction mitigated by `unknown` fallback.
- **Coordinator lifecycle complexity**: one authority must couple admission ownership, leases, cache health, confirmed teardown, and quarantine without conflating those states.
- **Quarantine reduces availability**: An unconfirmed process teardown intentionally reduces effective capacity until operator recovery or restart.
- **Harness contract evolution**: Every `AgentHarness` implementation must explicitly report managed-root termination confirmation. Processless implementations return `true`; unknown ownership cannot fail open.
- **Interface evolution**: `ProtocolAdapter` may need breaking changes when a third provider reveals new interaction patterns. Acceptable: `dartclaw_core` is pre-1.0.

### Neutral

- `BridgeEvent` sealed class unchanged — protocol adapters emit the same event types
- Guard chain architecture unchanged — only the input (canonical vs raw names) changes
- Existing `ClaudeCodeHarness` tests continue to pass — extraction is refactoring, not behavior change

## Alternatives Considered

### D1: Provider-Prefixed Tool Names

Guards see `claude:Bash`, `codex:command_execution`. Rules target specific providers or use wildcards.

- **Pros**: Trivial implementation (string concatenation)
- **Cons**: Every guard rule must be duplicated or wildcarded per provider. Linear growth in guard rules. Risk of missed rules = security gap.
- **Rejected**: Maintainability (5/10) and security (6/10) scores too low for security-critical code. Guard misconfiguration when adding providers is unacceptable.

### D1: Pass-Through with Alias Table

Guards match provider-native names. Alias table maps equivalents (`Bash = command_execution`).

- **Pros**: Simple bidirectional map. Guards stay in native terminology.
- **Cons**: Alias table can have gaps (silent at runtime). Mixed terminology in guard rules confuses SDK consumers. Alias ambiguity if providers reuse names for different operations.
- **Rejected**: Weaker security guarantees (7/10 vs 9/10 for canonical). Alias table maintenance burden grows with provider count.

### D2: Homogeneous Pool

All workers use the same provider. Provider selected at deployment level.

- **Pros**: Zero pool changes. Simplest possible implementation.
- **Cons**: **Blocks per-task provider override (F14)** — a stated PRD requirement. Users must run separate deployments for different providers.
- **Rejected**: Dealbreaker — blocks a key requirement. Fundamentally limits the multi-provider value proposition.

### D2: Homogeneous + Lazy Switch

Pool defaults to one provider. Workers re-created with different provider on demand.

- **Pros**: Simpler startup than heterogeneous. Supports per-task override.
- **Cons**: 2-5s latency per switch (binary spawn + handshake). Credential cleanup on switch is security-critical. Race conditions during harness re-creation.
- **Rejected**: Latency and security risks outweigh simplicity advantage.

### D3: Protocol-in-Harness (No Shared Interface)

Each harness has its own protocol parsing. No shared `ProtocolAdapter` interface.

- **Pros**: No new abstractions. Simple for 2 providers.
- **Cons**: Lifecycle duplication (788 LOC patterns copied). Canonical tool name mapping done independently per harness — inconsistency risk. No template for third-party harness authors.
- **Rejected**: PRD F03 already scopes protocol extraction. Marginal cost of interface (~20 LOC) is justified by consistency and extensibility gains.

### D3: Event-Driven with Common Message Envelope

Common `ProtocolMessage` envelope wrapping raw JSON. Central dispatcher routes to type-specific handlers.

- **Pros**: Centralized dispatch point for logging/security.
- **Cons**: Over-engineered. Envelope is effectively `Map<String, dynamic>` — loses Dart's sealed class type safety. Indirection without benefit for 1-to-1 harness-to-binary communication.
- **Rejected**: Wrong abstraction level. DartClaw's case is 1-to-1 (harness↔binary), not N-to-N routing.

## Additional Decisions (from review remediation, 2026-03-22)

### Codex Thread/Session Lifecycle

One Codex thread per DartClaw session (or task). First turn creates the thread (`thread/start`); subsequent turns continue on it (`turn/start` on existing thread). After app-server crash, DartClaw restarts the process, creates a new thread, and replays message history from its NDJSON store — same crash recovery pattern as `ClaudeCodeHarness`. Codex runs in ephemeral mode; DartClaw owns all persistence.

### Authentication Model

0.13 supports OpenAI API-key auth only (`OPENAI_API_KEY` injected into Codex subprocess env). ChatGPT-based auth (interactive browser login) is incompatible with the subprocess model and is out of scope. Custom `model_providers` config (Ollama, Azure, OpenAI-compatible — requiring `base_url`, `env_key`, `requires_openai_auth`, `query_params`) deferred to subsequent milestone.

### Pool Worker Lifecycle

Superseded by Part 4. `pool_size` bounds leases, not pre-created workers. Harnesses are created lazily, reused only through canonical fingerprint matching, and never fall back to another provider or weaker profile. Admission may wait for ordinary worker surfaces; nested logical-agent acquisition is fail-fast to avoid waiting on capacity held by the caller.

### config.toml Scope

Generated `config.toml` contains only settings that require config-layer injection: `developer_instructions`, MCP server definitions, and static trust config. Dynamic per-turn/per-thread settings (model, cwd, sandbox, approval policy) are passed via app-server request fields where supported.

### Guard Chain Interception — Permission Model Asymmetry

Claude Code and Codex have fundamentally different tool interception architectures:

- **Claude Code** has two independent mechanisms: (1) permission system (`can_use_tool` control requests) and (2) hook callbacks (`PreToolUse`/`PostToolUse`). DartClaw's guard chain runs in hooks, not permissions. The permission handler is a no-op (`ToolApprovalPolicy.allowAll`). Therefore, `--dangerously-skip-permissions` eliminates one unnecessary IPC round-trip per tool call with no security loss — hooks still fire.

- **Codex app-server** has only one mechanism: approval requests (JSON-RPC from server→client). There is no separate hook system. This is the only point where DartClaw's guard chain can evaluate tool calls. Approval flow must remain active — `--yolo` must NOT be used for app-server mode.

- **Codex exec** (F11) has no interception mechanism at all. Relies entirely on container isolation and Codex's built-in sandbox.

### Canonical Tool Taxonomy — Inference Rules

Some mappings are not one-to-one and require semantic inference:
- Codex `file_change` maps to `file_write` or `file_edit` based on the `kind` field (create → `file_write`, update → `file_edit`)
- Codex `command_execution` may represent `shell`, `file_read`, or other operations — mapped as `shell` (the guard evaluates command content for file operations)
- Unmapped or ambiguous tools **fail closed** for security-sensitive guards (CommandGuard, FileGuard, NetworkGuard). `ToolPolicyGuard` uses configurable policy for unknown tools.

## Implementation Notes

- Canonical tool taxonomy: `../../packages/dartclaw_core/lib/src/harness/canonical_tool.dart`
- Protocol adapter boundary: `../../packages/dartclaw_core/lib/src/harness/protocol_adapter.dart`
- Claude adapter implementation: `../../packages/dartclaw_core/lib/src/harness/claude_protocol_adapter.dart`
- Codex app-server adapter: `../../packages/dartclaw_core/lib/src/harness/codex_protocol_adapter.dart`
- Codex exec adapter: `../../packages/dartclaw_core/lib/src/harness/codex_exec_protocol_adapter.dart` _(removed in 0.17 — `codex-exec` provider consolidated into `codex` app-server mode)_
- Codex config generation: `../../packages/dartclaw_core/lib/src/harness/codex_config_generator.dart` and `../../packages/dartclaw_core/lib/src/harness/codex_environment.dart`
- Harness factory and provider registration: `../../packages/dartclaw_core/lib/src/harness/harness_factory.dart`
- Post-governance execution authority and leases: `../../packages/dartclaw_server/lib/src/execution_coordinator.dart`
- Per-provider capacity gate: `../../packages/dartclaw_server/lib/src/worker_capacity_gate.dart`
- Credential resolution: `../../packages/dartclaw_core/lib/src/config/credential_registry.dart`
- Guard evaluation: update the canonical-name mapping used by `../../packages/dartclaw_core/lib/src/agents/tool_policy_cascade.dart`, `../../packages/dartclaw_core/lib/src/harness/claude_code_harness.dart`, and `../../packages/dartclaw_core/lib/src/harness/codex_harness.dart`
- Fallback: unmapped tools use `provider:name` prefix with `ToolPolicyGuard` evaluation

## Post-Implementation Validation (0.13 baseline)

All three decisions validated by the 0.13 implementation:

- **D1 (Canonical Taxonomy)**: `CanonicalTool` enum with 6 categories works cleanly for both Claude and Codex. The `unknown` fallback + provider-prefix pass-through was exercised for Codex's `reasoning` tool. No guard changes were needed to support the second provider — confirming the maintainability thesis.
- **D2 (Heterogeneous Pool)**: Mixed-provider `HarnessPool` works as designed. Per-task provider override (F14) ships as specced. Pool sizing via `providers.*.pool_size` config is intuitive.
- **D3 (ProtocolAdapter)**: Three concrete adapters (Claude JSONL, Codex JSON-RPC, Codex exec JSON) confirm the interface shape is viable. The `ProtocolMessage` sealed class hierarchy (`TextDelta`, `ToolUse`, `ToolResult`, `ControlRequest`, `TurnComplete`, `SystemInit`) covers all three protocols without leaky abstractions.

Part 4 was implemented in 0.24. Structural checks prove production execution surfaces use the post-governance coordinator and provider branching stays at adapter/wiring boundaries. Tests cover serialized primary execution; per-provider hard capacity and queue release; capacity-only one-shots; exact-session then compatible-fingerprint reuse; profile isolation; turn-local guard reset; unhealthy disposal, confirmed replacement, and quarantine; shutdown; SDK fallback; and lease-derived API/SSE/UI observability. Provider continuity suites retain Claude session/fingerprint restart behavior, Codex session-thread affinity, and ACP initialized-process reuse with fresh provider sessions.

**Lessons for next provider (Pi)**: The adapter interface held without modification across three implementations. Pi's JSONL RPC protocol (`--mode rpc`) maps even more naturally than Codex's JSON-RPC, since Pi uses the same spawn+NDJSON pattern as Claude. Main concern remains runtime dependency (Node.js/Bun) and bus factor (solo developer). See the research appendix.

## References

- [ADR-007: System Prompt Architecture](007-system-prompt-architecture.md) — `PromptStrategy`, `AgentHarness` design
- 0.13 PRD — full decision log and feature definitions
- Research sources are summarized in the linked research appendix.
