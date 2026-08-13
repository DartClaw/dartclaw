# ADR-052: Native Provider Web Tools Denied for All Container Profiles

**Status:** Accepted – 2026-08-13 (proposed 2026-08-12, 0.24 execution-isolation correction)
**Deciders:** DartClaw team (operator-ratified 2026-08-13)

**Related:** [ADR-012](012-per-type-container-isolation.md) (per-type container isolation and profiles), [ADR-015](015-container-isolation-strategy.md) (hardened Docker `network:none` boundary), [ADR-035](035-cross-harness-task-capability-trust-mapping.md) (cross-harness tool trust mapping), [ADR-039](039-outbound-mcp-trust-boundary-and-transport.md) (host-mediated MCP egress boundary). Reverses the S03 FIS decision note `scoped-mcp-applies-to-workspace-profile` and its OC03/TI05 `[x]` criteria (`dev/bundle/docs/specs/0.24-execution-isolation/s03-claude-and-codex-container-parity.md`).

---

## Context

A containerized execution runs with Docker `network:none`. Its only path off the container is the per-authority framed `docker exec` pipe served by the host gateway; there is no socket mount, published port, or network attachment. This is the boundary the 0.24 execution-isolation work exists to enforce.

Provider-native web tools – Claude `WebSearch`/`WebFetch`, Codex `web_search` – are **not** executed inside the container. They execute server-side at the model provider, on traffic that rides the host-owned credential gateway. The container never opens the socket; the provider does, outside any boundary the container's `network:none` can reach.

The 0.24 design originally distinguished the two container profiles on this axis: the `restricted` profile denied provider-native web (research had to flow through the scoped MCP bridge so the profile's content and network guards applied to what came back), while the default `workspace` profile *retained* provider-native web. That split is recorded in the S03 FIS as an operator-ratified decision note (`scoped-mcp-applies-to-workspace-profile`) and as `[x]`-checked OC03 and TI05 acceptance criteria asserting "workspace-profile containers retain provider-native web".

During 0.24 code review the split was found to be unenforceable. Because native web executes at the provider rather than in the container, retaining it for the `workspace` profile does not keep the traffic inside `network:none` – it merely relocates the failure: the host provider adapter (the credential gateway) is the only place the request can be intercepted, and there it is refused with a gateway 403. A "retained" native-web capability for workspace containers is therefore a capability the operator believes exists but that the enforcement boundary rejects on every call. The shipped code consequently denies native `WebSearch`/`WebFetch` for **every** container profile, including the default `workspace` primary.

### Decision drivers

- **Containment must be real, not nominal** – a capability advertised as available on the workspace profile but 403'd at the gateway is a false operator-facing security claim.
- **`network:none` cannot bound provider-side execution** – the container never carries the web traffic; denying at the client is defense-in-depth, and the host provider adapter is the true enforcement point.
- **One enforcement rule across profiles** – profiles differ in filesystem/capability templates (ADR-012), not in whether provider-native web can be contained; it cannot, for either.
- **Baseline integrity** – shipped behavior reverses a ratified decision and `[x]` criteria; the reversal must be recorded, not left as silent drift.

## Decision

**Provider-native web tools (`WebSearch`/`WebFetch`, `web_search`) are denied for all containerized executions, on every container profile – `restricted` and `workspace` alike.** Approved web research inside a container reaches the network only through the guarded, execution-scoped MCP bridge (search/fetch tools running host-side through the existing MCP router, guard, SSRF/content, and audit boundaries). Host-mode executions are unaffected: their native web behavior is unchanged.

This reverses the `workspace`-retains-native-web half of the S03 decision note `scoped-mcp-applies-to-workspace-profile` and updates the OC03 / TI05 acceptance criteria to match shipped behavior. It does not change the scoped-MCP-for-all-profiles half of that note, which stands.

## Consequences

**Positive**
- Operators are no longer told a containerized workspace agent has provider-native web when the gateway refuses it – the security claim matches enforcement.
- One uniform rule: containerized native web is denied everywhere, so there is no profile-dependent gap to reason about or mis-configure.
- Every containerized research turn flows through the guarded MCP bridge, so content/network/SSRF guards apply to what the agent receives regardless of profile.

**Negative / accepted**
- A workspace-profile container loses provider-native web relative to the pre-0.24 intent. This is a capability reduction the design cannot honestly offer under `network:none`; the substitute is the scoped MCP search/fetch path.
- Operators who want provider-native web for an agent must run it on the host (`execution: host`), where the provider's web traffic is not subject to a container boundary in the first place.

## Alternatives Considered

1. **Keep native web for the `workspace` profile (the original design)** – rejected. It executes at the provider, so the traffic never enters the container's `network:none`; the only interception point is the host gateway, which 403s it. The capability would appear available and fail on every call – the exact "advertised but unenforceable" trap the isolation work exists to remove.
2. **Allow native web through the gateway for workspace containers (open the egress at the provider adapter)** – rejected. It reintroduces an unguarded provider-side egress that bypasses the scoped MCP router, SSRF/content, and audit boundaries, contradicting ADR-039 and the FR4 no-native-fallback constraint.
3. **Revert the code to the profile split** – rejected. Reverting reintroduces a contradiction the gateway refuses on every turn; the engineering is correct and the paperwork is what is missing.

## Project Compliance

Smallest change that solves the real problem (deny a capability that cannot be contained rather than build machinery to fake it), root cause over workaround (removes the false capability instead of papering over the gateway 403), approachable over clever (one uniform denial across profiles), and "security-conscious" framing preserved (the enforcement point is the host provider adapter, stated as such, not claimed as container containment).

## Implementation Notes

- Enforcement point is S02's provider adapter (the credential gateway), which rejects containerized executions' requests that declare provider-native web tools; client-side config disabling (`workerDisallowedTools` derived from the granted bridged tool set) is defense in depth, not the boundary. See the S03 FIS decision note `native-web-denial-enforcement-point`.
- The shipped behavior and this reversal are reconciled in the S03 FIS OC03 and its `[x]` structural criterion (one-line pointer to this ADR); the `scoped-mcp-applies-to-workspace-profile` note's scoped-MCP-for-all-profiles half is unchanged.
