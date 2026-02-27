# Search Agent + Memory

DartClaw includes a dedicated search agent for safe web access and a two-tier memory search system.

## Search Agent

The search agent has restricted tools -- only `WebSearch` and `WebFetch`. No filesystem, exec, or browser tools. It runs in a separate session store (`agents/search/sessions/`).

### How It Works

1. Main agent calls `sessions_send` with a query
2. DartClaw spawns a search agent turn in an isolated session
3. Search agent uses `WebSearch`/`WebFetch` to find information
4. Content-guard scans the result at the agent boundary
5. Result returned to main agent (or blocked if unsafe)

### Tool Policy Cascade

3-layer policy evaluator (most restrictive wins):
1. **Global deny** -- always blocked regardless of agent
2. **Agent deny** -- blocked for this specific agent
3. **Sandbox allow** -- only explicitly listed tools permitted (closed set)

### Configuration

```yaml
agent:
  agents:
    search:
      tools: [WebSearch, WebFetch]
      max_spawn_depth: 0        # cannot spawn sub-agents
      max_concurrent: 2
      max_response_bytes: 5242880  # 5MB cap
```

### Subagent Limits

| Limit | Default | Purpose |
|-------|---------|---------|
| `maxConcurrent` | 2 | Max parallel search agents |
| `maxSpawnDepth` | 0 | Search agent cannot spawn sub-agents |
| `maxChildrenPerAgent` | 2 | Max children per parent |

## Content Guard

Content-guard scans search results at the `sessions_send` boundary using Haiku classification:

| Classification | Action |
|---------------|--------|
| `safe` | Pass through to main agent |
| `prompt_injection` | Block with warning |
| `harmful_content` | Block with warning |
| `exfiltration_attempt` | Block with warning |
| API error/timeout | Block (fail-closed) |

Cloudflare challenge pages are detected and skipped (not classified).

Content is truncated to 50KB before classification.

## Memory Search

### FTS5 (Default)

Built-in full-text search using SQLite FTS5 with BM25 ranking. Zero external dependencies. Handles indexing automatically via database triggers.

### QMD Hybrid Search (Opt-in)

QMD adds vector search for semantic matching. DartClaw manages the QMD daemon lifecycle.

```yaml
search:
  backend: qmd              # fts5 (default) | qmd
  qmd:
    host: 127.0.0.1
    port: 8181
  default_depth: standard   # fast | standard | deep
```

| Depth | Method | Speed |
|-------|--------|-------|
| `fast` | Lexical only | ~26ms |
| `standard` | Lexical + vector | ~200ms |
| `deep` | Full query + reranking | 5-8s |

If QMD becomes unreachable, DartClaw falls back to FTS5 silently.

### Memory Consolidation

During heartbeat, if MEMORY.md exceeds 32KB, the agent runs a consolidation turn to deduplicate and reorganize entries.
