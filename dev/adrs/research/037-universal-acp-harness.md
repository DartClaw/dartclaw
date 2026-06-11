# ADR-037 Research Appendix: Universal ACP Harness (AcpHarness)

> Frozen synthesis supporting [ADR-037](../037-universal-acp-harness.md). Point-in-time as of the decision date; not maintained as the design evolves.

## Question
How should DartClaw support ACP-compatible agents while preserving host security and harness boundaries?

## Options considered
- Per-provider ACP adapters — familiar from ADR-016, but repeats adapter code for every ACP agent.
- One universal ACP adapter — configuration adds ACP agents without new protocol code.
- Reuse a third-party ACP client library — faster if mature, but would outsource a security-sensitive boundary.
- Treat ACP agents like trusted peers — simpler, but ignores reverse-call and mediation risk.

## Trade-off summary
The universal adapter gives broad compatibility while keeping reverse-call mediation and capability policy in DartClaw.

## Deciding evidence
ACP protocol research and the reverse-call spike showed the protocol is common enough for one adapter, while security behavior remains topology-scoped and host-mediated.

## Sources (private)
- `docs/research/acp-agent-client-protocol`
- `docs/research/acp-client-library/trade-off-analysis.md`
- `docs/research/alternative-agent-harnesses`
