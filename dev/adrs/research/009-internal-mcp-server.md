# ADR-009 Research Appendix: Internal MCP Server as Primary Tool Extension Point

> Frozen synthesis supporting [ADR-009](../009-internal-mcp-server.md). Point-in-time as of 2026-03-02; not maintained as the design evolves.

## Question
Should DartClaw expose internal capabilities through an MCP server, and where should that server live?

## Options considered
- No MCP server — preserves minimal surface, but limits tool-mediated workflows.
- External MCP sidecar — decouples protocol code, but adds runtime and deployment complexity.
- Dart-native internal MCP server — keeps ownership and security checks in the host.

## Trade-off summary
A Dart-native server gives the host full control over authorization, observability, and lifecycle at the cost of implementing protocol details.

## Deciding evidence
The design matrix favored direct host ownership because MCP access needs the same policy and audit model as other DartClaw runtime actions.

## Sources (private)
- `docs/research/internal-mcp-server/recommendation.md`
- `docs/research/internal-mcp-server/research.md`
- `docs/research/internal-mcp-server/tradeoff-matrix.md`
