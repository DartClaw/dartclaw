# Search Agent + Memory

DartClaw includes a dedicated search agent for safe web access and a two-tier memory search system.

The search agent is a built-in logical agent. For the broader picture – how logical-agent sessions differ from background tasks, how to define custom agents, and when to use which – see [Agents](agents.md).

## Search Agent

The search agent's canonical default allowlist is `{web_search, web_fetch}`. No filesystem, exec, or browser tools are allowed on host-guarded logical-agent turns. Its hidden session is retained for diagnostics and normal maintenance.

### How It Works

1. Main agent calls `sessions_spawn` with the `search` agent and a query
2. DartClaw acquires provider worker capacity, lazily creating or compatibly reusing a worker, and starts a hidden logical-agent session
3. Search agent uses mapped search/fetch tools to find information
4. Content-guard scans the result at the agent boundary
5. Result returned to main agent (or blocked if unsafe)

### Tool Policy Cascade

3-layer policy evaluator (most restrictive wins):
1. **Global deny** – always blocked regardless of agent
2. **Agent deny** – blocked for this specific agent
3. **Sandbox allow** – a non-empty list permits only explicitly listed tools (closed set)

The active logical-agent identity reaches `ToolPolicyGuard` on provider interception. DartClaw maps provider-native `WebSearch`/`WebFetch` and exact own-MCP search/fetch tool identities to `web_search`/`web_fetch`; unknown provider tools keep an auditable provider-prefixed fallback. Codex requires approval requests for host enforcement, while ACP enforcement is limited to its reverse-call and permission surfaces.

### Configuration

```yaml
agent:
  agents:
    search:
      tools: [web_search, web_fetch]
      max_response_bytes: 5242880  # 5MB cap
```

With no explicit `model` or `effort`, search inherits the selected provider's defaults. Set either in the agent entry when the search profile needs a fixed override. Search sessions require a provider worker lease; exhausted capacity returns an inline configuration error instead of using the caller's primary lane.

Execution capacity comes from the selected provider's `pool_size` lease limit. See [Agents](agents.md#capacity-boundary).

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

Content is truncated to 50KB before classification.

## Memory Search

Memory search combines the rebuildable full-text projection of canonical topic, archive, observation, and learning roles with a separately merged
file lookup over synthesized `wiki/` pages. For when those stores actually get written – and why a fresh instance returns
no results – see [How the Knowledge Layer Fills](workspace.md#how-the-knowledge-layer-fills).

One wiki request reads at most 1,000 regular files and 64 MiB of admitted body bytes. Each source is accepted through
64 MiB. Search ranks every admitted candidate before returning the best 50; an exhausted scan or bad wiki file is
reported as wiki-layer degradation without discarding healthy memory results.
Search responses include structured `degradations` with the reason, affected locator when known, observed and limit
values, and omitted count.

### FTS5 (Default)

Built-in full-text search using SQLite FTS5 with BM25 ranking. Zero external dependencies. Handles indexing automatically via database triggers.

### QMD Hybrid Search (Opt-in)

QMD adds vector search for semantic matching. DartClaw manages the QMD daemon lifecycle and supports stable QMD 2.5.3
or later 2.x releases. Startup uses QMD's explicit global `index`, verifies `collection show memory` maps to the exact workspace
with the recursive `**/*.md` mask, then completes both the initial update and embedding pass. Queries use QMD's structured
REST contract; daemon binding is restricted to literal loopback hosts (`localhost`, `127.x.x.x`, or `::1`), and shutdown
uses `qmd mcp stop`.

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

If QMD becomes unreachable or a query fails, DartClaw falls back to FTS5 and reports `qmd` in the degraded layers.

If startup reports that the existing `memory` collection uses the legacy `*.md` mask, run
`qmd --index index collection remove memory`, then restart DartClaw. Startup recreates the collection with `**/*.md`.

### Memory Curation

Curated personal memory changes through one path. `memory_apply` accepts one closed add/revise/merge/remove change set against the current collection revision; invalid or stale sets leave canonical memory and the derived index unchanged. The opt-in `memory-curation` job (`memory.curation.enabled`) is a scheduled caller of that same path, bounded to the entries its own run snapshot showed it. `memory_observe` records journal observations and bounded learnings without granting authority to rewrite curated personal memory.

## Conversation Search

DartClaw indexes user and assistant message text from user, main and channel sessions separately from memory.
System messages, attachments, and task, cron, logical-agent and archived sessions are excluded. Session NDJSON remains
the source of truth. Indexing failures are logged without interrupting message persistence.

Deleting or clearing a session removes its indexed messages. Archiving removes them from search while retaining the
files; resuming a chat-facing session restores them. This release exposes the query interface to Dart integrations
through `ConversationSearchService`, with message/session IDs, role, timestamp, text and score.

SQLite matches sanitized exact terms with `unicode61`, without stemming or prefix queries. PostgreSQL uses
`database.fts_language` for stemming, shared with memory and knowledge-graph search. After changing that language,
rebuild to update stored conversation and memory text vectors.

Stop DartClaw, then run `dartclaw rebuild-index` to rebuild both memory and conversation indexes. Its existing memory
summary is followed by `Rebuilt conversation index: N messages from M sessions`; `--json` adds `conversationMessages`
and `conversationSessions`. No chat-facing sessions means an empty conversation index, clearing any stale rows.
A memory-index rebuild also restores conversation rows from NDJSON when it replaces the SQLite search file.
