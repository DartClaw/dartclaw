# ADR-029: Temporal Knowledge Graph and the Durable Knowledge Loop

## Status

Accepted — 2026-05-30 (implemented in 0.17 / S03; recorded retroactively during the S11 milestone-documentation pass)

**Related:** First ADR to decide the *knowledge* layer (temporal facts, ingestion, wiki synthesis), but it builds on two prior decisions: [ADR-004](004-vector-search-approach.md) (two-tier FTS5 + QMD memory-search architecture — the ranking below layers on top of it) and [ADR-009](009-internal-mcp-server.md) (the `server.registerTool(McpTool)` boundary the `kg_*` tools instantiate). No prior ADR or `dev/architecture/` doc decided the temporal fact model, ingestion pipeline, or the wiki-vs-memory ranking.

## Context

Before 0.17, dropped-in files were passive: an operator could place material in the workspace, but the agent re-derived context every turn rather than accumulating durable, queryable knowledge. There was no synthesis layer over raw memory, no time-awareness for facts (no way to ask "what did we believe as of date X", no contradiction handling, no invalidation without losing history), and no provenance linking a fact back to its source.

S03 introduced a full **durable knowledge loop** — inbox ingestion → wiki synthesis → temporal knowledge graph — as a net-new subsystem. Several decisions in it are non-obvious and durable enough to warrant a record: the temporal fact model, the MCP tool boundary that exposes it to agents, and the search-ranking policy that decides synthesized knowledge outranks raw memory.

## Decision

**Build a durable knowledge loop with a bitemporal-style fact store exposed to agents as MCP tools, and rank synthesized wiki knowledge above raw memory in search.**

1. **Temporal knowledge graph** (`temporal_knowledge_graph_service.dart` in `dartclaw_storage`): source-linked facts with validity over time. Facts can be added, queried `as_of` a timestamp, invalidated **without deleting history**, and listed as a per-entity timeline; contradictions are detectable rather than silently overwriting.
2. **Agent-facing MCP boundary** (`kg_tools.dart` in `dartclaw_server`): five tools — `kg_add`, `kg_query` (entity/predicate + optional `as_of`), `kg_timeline`, `kg_invalidate`, `kg_contradictions`. The graph is reached by agents only through these tools; the storage service is not a direct dependency of agent code.
3. **Inbox ingestion** (`knowledge_inbox_service.dart`): a job processes stable (size-settled) supported files into durable memory + wiki updates, honoring `USER.md` relevance context. Files are **never silently dropped** — unsupported/oversized files are skipped with an explicit reason, and files that fail repeatedly move to **quarantine** with error metadata after the retry budget is exhausted. Success/failure summaries are surfaced to the operator.
4. **Wiki synthesis + search ranking** (`wiki_search_source.dart`): on top of the ADR-004 two-tier search backend, `memory_search` ranks wiki-derived synthesis **above** raw memory for the same topic and labels it as synthesized knowledge — independent of which backend (FTS5 or QMD hybrid) is active. Wiki pages carry provenance back to source material; wiki lint categories enforce discoverability.

## Consequences

### Positive

- The agent reasons from durable, synthesized, time-aware memory instead of re-deriving context each turn.
- Facts are auditable: every fact traces to its source, and history is preserved across invalidation (no destructive overwrite).
- `as_of` queries and timelines make "what did we know, and when" answerable — the basis for contradiction handling.
- The MCP boundary keeps agent code decoupled from the storage implementation; the graph can evolve behind a stable tool contract.
- No-silent-drop ingestion gives operators an actionable trail (skip reason or quarantine + error context).

### Negative

- A new subsystem spanning `dartclaw_storage` (graph + wiki search), `dartclaw_server` (inbox job + MCP tools), and `dartclaw_config` (`knowledge_config.dart`) — more surface to maintain and test.
- The "wiki synthesis outranks raw memory" ranking is a deliberate bias: if synthesis is stale or wrong, it is now surfaced *above* the raw source. Provenance + lint mitigate but do not eliminate the risk of authoritative-looking stale synthesis.
- Temporal/bitemporal semantics (validity time + invalidation history + contradiction detection) are inherently more complex than a flat key-value memory; correctness depends on disciplined `as_of` handling.
- Ingestion is a background job with a retry/quarantine budget — operators must monitor the quarantine and summaries, or failed material accumulates unprocessed.

## Alternatives Considered

1. **Extend flat memory with tags instead of a temporal graph** — rejected: cannot answer `as_of` / timeline / contradiction questions; invalidation would destroy history. The time dimension is the core requirement, not a tag.
2. **Expose the graph via REST/internal API instead of MCP tools** — rejected: agents already consume capabilities through MCP; an MCP boundary keeps the agent-facing contract uniform and the storage service undepended-upon by agent code.
3. **Rank raw memory and wiki synthesis equally (or raw above synthesis)** — rejected: defeats the purpose of synthesis; the loop exists so the agent prefers compounded, deduplicated knowledge over scattered raw fragments. The risk of stale synthesis is handled by provenance + lint, not by demoting synthesis.
4. **Ingest immediately on file drop (no stability/size-settle gate)** — rejected: would process partially-written files; the size-settled gate plus retry/quarantine is the no-silent-drop guarantee.

## Implementation Notes

- FIS provenance: 0.17 PRD, story S03.
- Storage: `dartclaw_storage/lib/src/knowledge/temporal_knowledge_graph_service.dart`, `dartclaw_storage/lib/src/search/wiki_search_source.dart`.
- Server: `dartclaw_server/lib/src/knowledge/knowledge_inbox_service.dart`, `dartclaw_server/lib/src/mcp/kg_tools.dart` (`KgAddTool`, `KgQueryTool`, `KgTimelineTool`, `KgInvalidateTool`, `KgContradictionsTool`), surfaced via `mcp_exports.dart` and registered through `McpServer.registerTool`.
- Config: `dartclaw_config/lib/src/knowledge_config.dart`.
- A dedicated `dev/architecture/knowledge-architecture.md` should follow to document the data model and the ingestion/synthesis pipeline in reference form (this ADR records the decisions, not the full mechanics).

## Project Compliance

- Files-as-source-of-truth + SQLite-index storage model is preserved: the graph and wiki sit in `dartclaw_storage` alongside the existing search indexes.
- MCP tool boundary follows the [ADR-009](009-internal-mcp-server.md) `registerTool(McpTool)` pattern; no agent-code coupling to storage internals.
- The search ranking extends [ADR-004](004-vector-search-approach.md)'s memory-search decision rather than replacing it — the backend choice (FTS5 / QMD) is unchanged; only the wiki-vs-raw precedence is added.
- "Fail loud, not silent": ingestion never silently drops files — explicit skip reasons and quarantine with error context.

## References

- [ADR-004: Vector Search Approach](004-vector-search-approach.md) (memory-search backend the ranking layers on)
- [ADR-009: Internal MCP Server](009-internal-mcp-server.md) (`registerTool` boundary for the `kg_*` tools)
- FIS provenance: 0.17 PRD, story S03.
- [Data model](../architecture/data-model.md)
- [System architecture](../architecture/system-architecture.md)
- Public guide knowledge/memory user references, 0.17 PRD story S11 doc sync.
