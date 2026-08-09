# Search Agent + Memory

DartClaw includes a dedicated search agent for safe web access and a two-tier memory search system.

The search agent is one of DartClaw's two agent execution models. For the broader picture – how subagents differ from task runners, how to define custom agents, and when to use which – see [Agents](agents.md).

## Search Agent

The search agent's canonical default allowlist is `{web_search, web_fetch}`. No filesystem, exec, or browser tools are allowed on host-guarded delegated turns. Its hidden delegated session is retained for diagnostics and normal maintenance.

### How It Works

1. Main agent calls `sessions_spawn` with the `search` agent and a query
2. DartClaw acquires or spawns a provider-matched task-pool worker and starts a hidden delegated session
3. Search agent uses mapped search/fetch tools to find information
4. Content-guard scans the result at the agent boundary
5. Result returned to main agent (or blocked if unsafe)

### Tool Policy Cascade

3-layer policy evaluator (most restrictive wins):
1. **Global deny** – always blocked regardless of agent
2. **Agent deny** – blocked for this specific agent
3. **Sandbox allow** – a non-empty list permits only explicitly listed tools (closed set)

The active delegated-agent identity reaches `ToolPolicyGuard` on provider interception. DartClaw maps provider-native `WebSearch`/`WebFetch` and exact own-MCP search/fetch tool identities to `web_search`/`web_fetch`; unknown provider tools keep an auditable provider-prefixed fallback. Codex requires approval requests for host enforcement, while ACP enforcement is limited to its reverse-call and permission surfaces.

### Configuration

```yaml
agent:
  agents:
    search:
      tools: [web_search, web_fetch]
      max_concurrent: 2
      max_response_bytes: 5242880  # 5MB cap
```

With no explicit `model`, search uses `sonnet` on Claude and `gpt-5.6-luna` on Codex. Set `model` or `effort` in the agent entry to override those provider defaults. Delegation requires task-pool capacity; an unavailable pool returns an inline configuration error instead of using the caller's primary harness.

### Subagent Limits

Configured `max_concurrent` values are summed into the global delegation cap; they are not currently enforced per agent. Subagents cannot spawn subagents. See [Agents](agents.md#subagent-limits).

Provider-native config spellings remain compatible through startup normalization. For portable policies, prefer canonical names. `web_search` and `web_fetch` are separate grants, so older task or step policies naming only `web_fetch` must add `web_search` if search is intended.

## Content Guard

Content-guard scans search results at the `sessions_spawn` and `sessions_send` boundaries using Haiku classification:

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

Memory search reads the FTS5 index over `MEMORY.md` plus synthesized `wiki/` pages. For when those stores actually get written -- and why a fresh instance returns no results -- see [How the Knowledge Layer Fills](workspace.md#how-the-knowledge-layer-fills).

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

Memory journaling fills MEMORY.md from daily turn logs; consolidation deduplicates it after it exceeds the size cap.
