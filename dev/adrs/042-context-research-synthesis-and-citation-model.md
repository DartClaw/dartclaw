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

Synthesis runs through an injected background-turn seam. Production wiring dispatches through the logical-agent session path; tests can inject a deterministic synthesizer. If synthesis output is malformed, packet assembly falls back to citation-preserving candidate snippets rather than fabricating uncited claims.

## Consequences

## Amendment (2026-08-12) – converged search and locator contract

`context_research`, the Knowledge Hub, MCP memory search, and direct search share one request-level composition owner.
Callers pass trimmed natural language; the FTS5 adapter owns MATCH encoding. Personal-memory citations use stable entry
UUID locators and revisions, while wiki/KG retain native locators and provenance. Native wiki wins over a duplicate QMD
copy, and failure of one layer is reported without discarding healthy results.

## Amendment (2026-09-22) – caller-private memory and explicit publication

The research tool remains the one synthesis and citation authority, but its source set is resolved from the authenticated
caller. Owner conversations retrieve owner personal memory; a named agent retrieves only its own personal memory when
its tool policy grants `context_research`; named MCP clients receive no personal-memory source. Every caller may receive
the shared wiki and temporal KG. The knowledge inbox and every other principal's memory are excluded.

Publication is explicit rather than inferred from a managed workspace. Separately authorized wiki/KG writes and the
validated knowledge-inbox pipeline put accepted outputs onto the shared surface. Direct KG reads and citation labels
describe published facts without exposing their stored private source field. The named-client profile is therefore
exactly `context_research`, `kg_query`, and `kg_timeline`; it no longer exposes personal-memory search or reads.

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
