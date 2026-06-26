# ADR-039: Outbound MCP Trust Boundary and Transport

## Status

Accepted - 2026-06-12 (targets 0.19; fixes the FR1 outbound MCP client seam)

**Related:** [ADR-037](037-universal-acp-harness.md) (security-critical stdio JSON-RPC client sourcing precedent), [ADR-029](029-temporal-knowledge-graph-durable-knowledge-loop.md) (knowledge MCP tool boundary), [ADR-009](009-internal-mcp-server.md) (internal MCP server surface), [ADR-035](035-cross-harness-task-capability-trust-mapping.md) (explicit trust mapping).

## Context

DartClaw currently serves MCP tools to agents, but it does not consume external MCP servers. The 0.19 outbound pillar adds an MCP client that connects to external servers, performs `initialize`, `tools/list`, and `tools/call`, and pools long-lived connections with HarnessPool-style lifecycle management.

This is a new trust boundary. External MCP servers are outside DartClaw's control and may be stdio subprocesses or HTTP endpoints. Every outbound call must pass through the egress guard, produce audit evidence, and return structured failures without hanging the agent. The inbound MCP server does not provide a reusable stdio client seam: inbound is HTTP-only today, and stdio outbound transport is net-new.

The PRD left one implementation decision open: build a native JSON-RPC MCP client or add an `mcp_dart` dependency. The decision must respect DartClaw's minimal-deps / no-Node-npm ethos while still supporting the required MCP stdio and HTTP transports.

ADR-037 is the closest precedent. For ACP, DartClaw chose a from-scratch stdio JSON-RPC client on the existing `json_rpc_2` dependency rather than depending on or vendoring a larger client package, because the protocol client sat on a security-critical host boundary.

## Decision

Build the FR1 outbound MCP client as a **native Dart JSON-RPC client**, using existing Dart platform libraries and the existing `json_rpc_2` dependency where it fits the transport shape. Do not add `mcp_dart` for 0.19.

The fixed seam for FR1 is:

- a Dart-owned outbound MCP client facade for `initialize`, `tools/list`, `tools/call`, health checks, and structured shutdown;
- a stdio transport implemented as a net-new subprocess JSON-RPC transport;
- an HTTP transport implemented natively against Dart HTTP primitives for the required Streamable HTTP request/response surface;
- a guard/audit hook before every outbound `tools/call`, so S04 can enforce the egress boundary without depending on a third-party client's internals.

This aligns with ADR-037's from-scratch-client precedent, with a narrower scope: implement the subset DartClaw needs for connection lifecycle and tool calls, not the full MCP feature surface. The native seam keeps the trust boundary auditable, avoids a new runtime dependency in a security-sensitive path, and preserves the no-Node-npm chain.

## Consequences

### Positive

- The outbound trust boundary is Dart-owned and directly inspectable.
- No new runtime package is added for the MCP client; 0.19 reuses the existing JSON-RPC foundation where practical.
- S04 can place guard and audit mediation at a stable Dart seam before dispatching to stdio or HTTP.
- The implementation remains minimal: initialization, discovery, calls, lifecycle, timeouts, and structured errors only.

### Negative

- DartClaw owns protocol drift for the subset it implements. Future MCP features may require additional in-house work.
- `mcp_dart` already covers more of the MCP spec, including transports DartClaw could otherwise reuse; rejecting it trades feature breadth for auditability and dependency control.
- HTTP Streamable MCP must be tested carefully because there is no existing inbound-HTTP client seam to reuse.

## Alternatives Considered

1. **Depend on `mcp_dart`** - rejected for 0.19. It is the most complete Dart MCP client candidate and covers stdio plus Streamable HTTP, but it would add a new third-party runtime dependency at the outbound egress boundary. That boundary must enforce allowlists, secret handling, timeouts, audit, and fail-closed behavior, so DartClaw benefits more from owning the dispatch seam than from broad client feature coverage.
2. **Reuse the inbound MCP server implementation** - rejected. Inbound MCP is HTTP-only and server-oriented; outbound stdio is net-new and most ecosystem MCP servers use stdio. Treating inbound as reusable would under-size FR1.
3. **Use a Node/npm MCP client wrapper** - rejected. It violates the no-Node-npm deployment ethos and moves a security-sensitive boundary out of the AOT Dart runtime.
4. **Implement the full MCP spec natively up front** - rejected. 0.19 needs initialization, tool discovery, tool calls, lifecycle, timeouts, and guardable dispatch. Implementing prompts, resources, elicitation, or unrelated spec surface now would expand maintenance without serving the milestone.

## References

- 0.19 PRD - constraints, decisions log, FR1 outbound MCP client, and FR3 egress trust boundary.
- Research: `dev/bundle/docs/research/outpost-pattern-integration/research.md` - MCP stdio lifecycle and Dart client package survey.
- [ADR-037: Universal ACP Harness (AcpHarness)](037-universal-acp-harness.md)
- [ADR-029: Temporal Knowledge Graph and the Durable Knowledge Loop](029-temporal-knowledge-graph-durable-knowledge-loop.md)
- [ADR-009: Internal MCP Server as Primary Tool Extension Point](009-internal-mcp-server.md)
