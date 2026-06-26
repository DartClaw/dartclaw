# ADR-042: Context Research Synthesis and Citation Model

## Status

Accepted - 2026-06-24

**Related:** [ADR-029](029-temporal-knowledge-graph-durable-knowledge-loop.md), [ADR-009](009-internal-mcp-server.md)

## Context

DartClaw has three internal knowledge layers: wiki synthesis, temporal KG facts, and FTS5/QMD memory search. Agents can already query those layers separately, but answering "why did we decide X" requires stitching raw rows across multiple MCP calls. That creates satisfaction-of-search risk: an agent may stop after one partial layer, or emit uncited synthesis.

FR5 requires a single `context_research` MCP call that fans out across all layers, synthesizes a compact packet, and preserves resolvable citations for every emitted statement. Freshness is more important than latency, so synthesized answers must never be cached.

## Decision

Build `context_research` as one MCP tool in `dartclaw_server` that performs parallel retrieval over memory, temporal KG, and wiki sources, then assembles a compact citation-backed packet.

The citation contract is:

```json
{
  "sourceRef": {
    "layer": "wiki|kg|memory",
    "locator": "<wiki page id / kg fact id / memory entry id>",
    "label": "human-readable source label"
  },
  "packet": {
    "statements": [
      {"text": "claim text", "sourceRefs": []}
    ],
    "sourceList": [],
    "degradedLayers": [],
    "noSourcesFound": false
  }
}
```

The Dart value types are `CitationLayer`, `SourceRef`, `CitationStatement`, and `CitationPacket`. The shared resolver contract is `CitationSourceResolver`, with the tool applying it at packet assembly so unresolved references mark statements `unattributed` rather than authoritative.

Synthesis runs through an injected background-turn seam. Production wiring dispatches through the existing session delegation path; tests can inject a deterministic synthesizer. If synthesis output is malformed, packet assembly falls back to citation-preserving candidate snippets rather than fabricating uncited claims.

## Consequences

### Positive

- Agents get one compact MCP result instead of coordinating multiple raw retrieval tools.
- FR8/S09/S10 can reuse one citation shape and resolver contract rather than re-mapping locators per UI view.
- No answer cache exists; every call reruns retrieval and synthesis.
- Failed retrieval layers are explicit `degradedLayers`, not silent omissions.

### Negative

- KG broad retrieval is bounded by query-derived entity candidates until a fuller KG search index exists.
- Citation resolvability proves a locator exists; it does not prove semantic support.
- Background synthesis can return malformed output, so the tool needs a deterministic citation-preserving fallback path.

## Alternatives Considered

1. **Return raw rows only** - rejected: preserves the current satisfaction-of-search problem.
2. **Cache synthesized packets by query** - rejected: violates the explicit freshness requirement.
3. **Per-UI citation models** - rejected: duplicates security-sensitive locator mapping and risks drift between packet, hub, and timeline surfaces.

## Implementation Notes

- Tool registration follows ADR-009 through `server.registerTool(ContextResearchTool(...))`.
- The packet type and resolver live in the MCP sub-barrel exported by `dartclaw_server`.
- Metrics are emitted through an injected sink carrying token estimates, source counts, truncation, and an explicit cache-bypass marker.

## Project Compliance

- No new persisted table, store, or keyed packet map is introduced.
- The temporal KG remains the durable fact substrate from ADR-029.
- Tool errors are application-level `ToolResult.error` values, matching MCP behavior elsewhere in DartClaw.
