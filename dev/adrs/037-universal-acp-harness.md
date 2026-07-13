# ADR-037: Universal ACP Harness (AcpHarness)

## Status

Accepted – 2026-06-05; amended 2026-07-13

The amendment withdraws ACP terminal capability advertisement on every host until complete process-tree containment is
implemented. Guard mediation remains available for turn-scoped filesystem reverse-calls. The earlier terminal spike is
historical validation of ACP routing, not authorization for root-only host process ownership.

**Related:** [ADR-016](016-multi-provider-harness-architecture.md) (multi-provider harness — **this amends it**: ACP is one universal adapter, not another per-provider custom adapter), [ADR-035](035-cross-harness-task-capability-trust-mapping.md) (precedent for explicit per-harness security asymmetry), [ADR-007](007-system-prompt-architecture.md) (`AgentHarness` interface), [ADR-001](001-sdk-integration-and-security-architecture.md) (security-by-design).

## Context

DartClaw speaks to agents through provider-specific `ProtocolAdapter` implementations (ADR-016): Claude Code over JSONL, Codex over JSON-RPC. Each new provider costs a dedicated adapter (~500–800 LOC). Meanwhile 50+ agent runtimes now speak ACP (Agent Client Protocol — JSON-RPC 2.0 over stdio; v0.13.4 as of May 2026), a standardized agent↔client protocol. A single `AcpHarness` would connect DartClaw to the entire ACP ecosystem through one adapter.

Three decisions had to be resolved before building it, two of them load-bearing for security:

1. **Adapter shape** — extend ADR-016's per-provider pattern with an ACP adapter, or build a single *universal* adapter for all ACP agents?
2. **Client sourcing** — depend on a pub package, vendor/fork one, or implement the ACP client in-house? The load-bearing surface is the **client side**: advertising `fs`/`terminal` capabilities in `initialize` and serving the reverse-call handlers (`fs/read_text_file`, `fs/write_text_file`, `terminal/create`, `session/request_permission`) that route to `FileGuard`/`CommandGuard`.
3. **Security model** — ACP *inverts* the harness security model (the agent requests the host to perform I/O via reverse-calls, rather than executing directly and being intercepted by hooks). Does this give DartClaw guard-by-design, and for which agents/topologies?

The ACP spec **gates but does not mandate** reverse-calls: an agent MUST NOT call `fs/*`/`terminal/*` unless the client advertises the capability, but is not required to *use* reverse-calls when it does. So guard mediation is agent-dependent, not a protocol guarantee. A two-stage verification spike (A0, A0.1) ground-truthed this empirically against Goose.

## Decision

Build **`AcpHarness`** as a single universal ACP adapter implementing `AgentHarness`, with three sub-decisions:

### 1. One universal adapter (amends ADR-016)
`AcpHarness` is a *protocol* adapter, not a *provider* adapter: it speaks ACP over a stdio JSON-RPC subprocess and serves any ACP-compliant agent configured by binary + args. Adding an ACP agent is configuration, not code. This amends ADR-016's "one `ProtocolAdapter` per provider" assumption for the ACP family; the canonical tool taxonomy, `HarnessFactory`, and heterogeneous-pool model from ADR-016 still hold.

### 2. ACP client implemented from scratch on `json_rpc_2`
Implement the minimal ACP client subset (~350–450 LOC) in `dartclaw_core` on `json_rpc_2` (Dart-team, verified publisher, BSD-3, already in-workspace; `Peer` provides the required bidirectional dispatch). Use the abandoned `acp_dart` package's `ClientSideConnection`/`Client` pattern as a **reference only** — do not depend on or vendor it. `dart_acp` is eliminated (abandoned). Rationale: weighted trade-off analysis scored from-scratch 4.75/5 vs vendor 3.30 vs depend 2.15, dominating control, supply-chain safety, spec-drift agility, and dependency footprint — the decisive criteria for a security-critical path under DartClaw's minimal-attack-surface philosophy. The A0 spike validated the approach end-to-end.

### 3. Capability-gated, topology-scoped guard mediation
DartClaw advertises `fs.readTextFile`/`fs.writeTextFile` capabilities in `initialize` and implements the reverse-call handlers natively, routing through the existing `GuardChain` (`FileGuard`) and the tool-approval chain (`session/request_permission`). Each reverse-call is bound to the active host session and effective workspace. Calls outside an active turn fail closed. Terminal reverse-calls are not advertised and are rejected until complete descendant containment exists. Guard-by-design is **agent- and topology-dependent**, made explicit (per the ADR-035 precedent):

- **Direct-provider topology** (the ACP agent is the sole agent, honoring advertised capabilities – e.g. Goose with a direct model provider + the `developer` extension): filesystem operations arrive as reverse-calls and are mediated by the guard chain. **Guard-by-design holds.** A0.1 verified filesystem routing; host terminal execution is no longer part of this security claim.
- **Relay-provider topology** (the ACP agent routes its model through a *nested* agent over ACP — e.g. Goose with `claude-acp`/`codex-acp`): the nested agent performs I/O outside DartClaw's reach, so operations do **not** surface as reverse-calls and neither ACP mediation nor hook interception wraps them. **Container isolation is the only boundary.** Verified in A0.1: zero reverse-calls; `noAccess`/deny write and command landed out-of-band.
- **Default-deny posture:** an agent whose reverse-call behavior is unverified runs container-isolated; guard-by-design is claimed only where verified.

**Goose is the first target**, in the direct-provider topology.

## Consequences

### Positive
- One adapter connects DartClaw to the entire ACP ecosystem; new agents are config, not code.
- Guard-by-design (handler-layer, type-safe, unbypassable) for direct-provider ACP filesystem calls – a stronger model than hook interception, since the agent never has direct host filesystem access.
- No new third-party runtime dependency for the protocol client; the ACP surface is auditable and fits the context window.
- Spec-drift agility: DartClaw owns the ~400-LOC client and tracks the fast-moving ACP spec directly.

### Negative
- **Topology-dependent security**, like ADR-035's `allowedTools` asymmetry: the same agent yields a different effective posture depending on its model-provider topology. Operators and guard authors must understand that **relay-provider ACP agents are container-isolation-only** — this must be stated in security/guard docs, not assumed uniform.
- DartClaw owns the ACP DTOs and transport adapter; process-tree containment is required before terminal lifecycle support can return.
- Per-agent verification is required before claiming guard mediation for any new ACP agent.

## Alternatives Considered

1. **Per-provider custom ACP adapter (ADR-016 status quo extended)** — rejected: forfeits the universal-adapter payoff (one adapter for 50+ agents) and repeats ~500–800 LOC per agent.
2. **Depend on `acp_dart` v0.4.0** — rejected: unverified solo publisher, bus factor 1, ~3 months dormant, targets an older ACP surface; a live supply-chain dependency on a security-critical path is a dealbreaker.
3. **Vendor/fork `acp_dart`** — rejected: inherits ~3,500 LOC + a codegen step on a stale spec that must be updated anyway; nearly rebuilds the from-scratch client with more baggage.
4. **Drop guard-by-design; rely on container isolation for all ACP agents** — rejected: abandons the core value proposition that distinguishes `AcpHarness` from container-only integrations; A0.1 proved guard-by-design is achievable for direct-provider topologies.

## Implementation Notes

- Minimal client subset only: stdio NDJSON adapter, `initialize` with filesystem capability advertisement, `session/new`, `session/prompt`, `session/update`, filesystem reverse-call handlers, `session/request_permission`, and `session/cancel`. Terminal methods fail closed. Exclude unstable methods (`session/fork`, Elicitation, NES); `session/resume` is available but not built on in 0.18.
- Harness config must enforce the conditions guard mediation depends on (e.g. Goose's `developer` extension active + a direct provider) and flag relay-topology agents as container-isolation-only.
- **Pending confirmation:** the read-*blocking* re-test (a `noAccess` `fs/read_text_file` returning an error and withholding content) is gated on the separate `FileGuard` `file_read` fix (the guard chain currently has no `file_read` branch — a pre-existing harness-wide gap, tracked independently). Read *routing* through the handler is already verified (A0.1); write and shell *blocking* are verified. This ADR's security model does not change on that confirmation.
- Risk: ACP spec moves fast (3 minors in 7 weeks); pin to v0.13.4 semantics and tolerate minor drift.

## Project Compliance

- **Minimal attack surface / lean dependencies** — from-scratch client on an existing Dart-team package; no new third-party runtime dep; auditable.
- **Security in depth** – session-bound handler-layer guard mediation for direct topologies; terminal execution disabled without complete containment; container isolation retained as the boundary elsewhere; default-deny for unverified agents.
- **Multi-harness by design** — extends the heterogeneous harness model (ADR-016) rather than replacing it.

## References

- 0.18 PRD — carries the topology-scoped security claims. ACP planning chose Goose-first, stdio transport, agent-dependent mediation, a from-scratch client, and A0/A0.1 reverse-call verification with topology-scoped security claims.
- A0/A0.1 reverse-call verification spike — outcomes are summarized inline (§Decision part 3 and §Consequences) and in the PRD; the spike client + Goose integration test are preserved on the `spike/0.18-acp-reverse-call` branch in dartclaw-public.
- [ADR-016](016-multi-provider-harness-architecture.md) (amended), [ADR-035](035-cross-harness-task-capability-trust-mapping.md), [ADR-007](007-system-prompt-architecture.md)
- Research sources are summarized in the linked research appendix.
