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

### Built-in Hybrid Search (Opt-in)

Built-in hybrid search combines the current full-text results with semantic matches for both memory and conversation
search. Enable it with the managed local provider:

```yaml
search:
  backend: hybrid
  embedding:
    provider: local
    model: embeddinggemma-300M-Q8_0.gguf
```

Hybrid search combines full-text and semantic candidates using weighted Reciprocal Rank Fusion (RRF). It returns
ranked, current passages from the requested corpus. Similarity and RRF scores indicate retrieval relevance; they do
not certify that a passage contains a complete answer. The caller uses the retrieved evidence to answer the question.

Search uses the configured embedding provider and creates no generative-agent turn. Local embeddings keep query
processing in the local runtime; an explicitly configured HTTP embedding provider receives its embedding inputs.
Missing embeddings or vector failures retain freshly verified full-text results with visible degradation diagnostics.
Deleted or changed source content cannot be returned from stale vector rows or an old fallback snapshot.

The local provider accepts only this model. DartClaw reads it from
`<data_dir>/models/embeddinggemma-300M-Q8_0.gguf`; the setting is a managed selector, not a path. Acquire it explicitly:

```bash
dartclaw search download-model
```

The command checks the exact size and checksum. It reuses matching bytes and otherwise downloads to a temporary file,
verifies it, and publishes it only after verification. Starting DartClaw never downloads a model automatically. The
command reports the Gemma licence that governs the model.

If the model is absent or corrupt, native loading fails, or embedding a query or document fails, lexical search remains
available and the affected result reports vector degradation. A native provider whose initialization times out is not
retried inside that server process; correct the model or native installation and restart DartClaw. There is no hidden
retry or automatic switch to HTTP.

#### Explicit HTTP Provider

To use a local HTTP outpost or cloud embedding service, select it explicitly and name its model and absolute endpoint.
The credential is an optional named generic API key:

```bash
dartclaw secrets set embeddings-service --type api-key
```

```yaml
search:
  backend: hybrid
  embedding:
    provider: http
    model: provider-model-name
    endpoint: https://embeddings.example/v1/embeddings
    credential: embeddings-service
```

The endpoint receives raw query and document text in the OpenAI-compatible `input` field, so that text leaves DartClaw
and enters the endpoint's trust boundary. The endpoint owns model-specific preprocessing. DartClaw does not add the
EmbeddingGemma query/document prefixes, infer behavior from the model name, or select HTTP automatically. It does not
log or serialize the resolved credential value. A credential requires HTTPS except for a literal loopback endpoint.

#### Inspection and Recovery

Inspect each corpus independently through the running server:

```bash
dartclaw search inspect --corpus memory --query "release policy" --limit 20
dartclaw search inspect --corpus conversation --query "release policy" --limit 20
```

The command reports the returned sources and scores, the full-text and vector ranks and contributions for considered
candidates, the selected corpus's unembedded count, and any degradation. Limits are bounded from 1 to 20. Use `--json`
for the same structured response.

`GET /api/memory/status` reports separate `memoryUnembeddedCount` and `conversationUnembeddedCount` values under
`index`. Zero means every current chunk has a usable vector for the selected provider; a positive value identifies work
still to reconcile; `null` means the count is unavailable or hybrid search is inactive.

Stop DartClaw and run `dartclaw rebuild-index` after enabling hybrid search, changing the HTTP provider identity,
repairing the local model, or recovering from vector degradation. The command rebuilds both lexical corpora, then
reconciles their vectors. Its human output reports both unembedded counts. JSON output uses
`memoryUnembeddedCount`, `conversationUnembeddedCount`, and `vectorDegradedCorpora` when recovery is incomplete.

On SQLite, `search.db` is the replaceable lexical projection and `vectors.db` is the separate retained vector store.
On PostgreSQL, `memory_vectors` and `conversation_vectors` hold the two corpus-specific vector projections. PostgreSQL
hybrid search requires administrator-provisioned pgvector; see [PostgreSQL](postgresql.md#provisioning). These stores are
derived and can be rebuilt from canonical memory and session NDJSON.

SQLite full-text search matches `unicode61` tokens without stemming. PostgreSQL full-text search applies the configured
Snowball stemming. Semantic matches come from embeddings and can match related wording that shares no lexical token.
Hybrid search combines the lexical and semantic rankings while preserving each corpus's canonical result identity.

### QMD Hybrid Search (Deprecated)

QMD is deprecated in 0.26 but remains working during this milestone; the following milestone removes it. Existing QMD
deployments can continue to use its vector search for semantic matching. DartClaw manages the daemon lifecycle and
supports stable QMD 2.5.3 or later 2.x releases. Startup uses QMD's explicit global `index`, verifies
`collection show memory` maps to the exact workspace with the recursive `**/*.md` mask, then completes both the initial
update and embedding pass. Queries use QMD's structured REST contract; daemon binding is restricted to literal loopback
hosts (`localhost`, `127.x.x.x`, or `::1`), and shutdown uses `qmd mcp stop`.

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

### PostgreSQL Language-Aware Search (Opt-in)

With the [PostgreSQL backend](postgresql.md), one deployment-level `database.fts_language` setting drives memory,
conversation, and knowledge-graph fact search. Changing it requires a restart followed by `dartclaw rebuild-index`
for the stored memory and conversation search projections. Knowledge-graph facts use the new language on their next
query after restart. The wiki stays file-backed and is searched live, and tasks are never indexed.

PostgreSQL uses Snowball stemming for regular inflections. For example, Swedish `springa` can match `springer`, but
the irregular English `sprang` does not match `springa`. Mixed-language content can be mis-stemmed because every
document uses the configured deployment language. PostgreSQL does not fold diacritics where FTS5 does, and a query
made only of stopwords returns no matches. Quoted phrases and `-word` negation use PostgreSQL web-search query syntax.
FTS-only operation uses core PostgreSQL and requires no extension; built-in hybrid search also requires pgvector.

SQLite keeps its existing FTS5 behavior unchanged, including `unicode61` tokenization without stemming.

### Memory Curation

Curated personal memory changes through one path. `memory_apply` accepts one closed add/revise/merge/remove change set against the current collection revision; invalid or stale sets leave canonical memory and the derived index unchanged. The opt-in `memory-curation` job (`memory.curation.enabled`) is a scheduled caller of that same path, bounded to the entries its own run snapshot showed it. `memory_observe` records journal observations and bounded learnings without granting authority to rewrite curated personal memory.

## Conversation Search

DartClaw indexes user and assistant message text from user, main and channel sessions separately from memory.
System messages, attachments, and task, cron, logical-agent and archived sessions are excluded. Session NDJSON remains
the source of truth. Indexing failures are logged without interrupting message persistence.

Deleting or clearing a session removes its indexed messages. Archiving removes them from search while retaining the
files; resuming a chat-facing session restores them. Dart integrations use `ConversationSearchService`, and operators
can inspect the corpus with `dartclaw search inspect --corpus conversation`, including message/session IDs, role,
timestamp, text, score and hybrid ranking evidence.

SQLite matches sanitized exact terms with `unicode61`, without stemming or prefix queries. PostgreSQL uses
`database.fts_language` for stemming, shared with memory and knowledge-graph search. After changing that language,
rebuild to update stored conversation and memory text vectors.

Stop DartClaw, then run `dartclaw rebuild-index` to rebuild both memory and conversation indexes. Its existing memory
summary is followed by `Rebuilt conversation index: N messages from M sessions`; `--json` adds `conversationMessages`
and `conversationSessions`. No chat-facing sessions means an empty conversation index, clearing any stale rows.
A memory-index rebuild also restores conversation rows from NDJSON when it replaces the SQLite search file.
