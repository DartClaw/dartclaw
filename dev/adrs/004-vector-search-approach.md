# ADR-004: Vector Search Approach for Hybrid Memory

**Status:** Accepted — fully implemented. Two-tier search: FTS5 built-in (default) + QMD outpost (opt-in via `search.backend: qmd`). `QmdManager`, `QmdSearchBackend`, and `SearchBackendFactory` in `dartclaw_core`.
**Date:** 2026-02-25 (accepted: 2026-02-27)
**Deciders:** DartClaw team

## Context

DartClaw 0.2 PRD (F26) requires hybrid memory search combining vector embeddings with the existing FTS5 BM25 keyword search. The MVP's FTS5 keyword search misses semantic matches — searching "authentication approach" won't find entries about "JWT tokens" or "OAuth flow."

The question: how should DartClaw generate embeddings and perform vector search?

### Current State

- `MemoryService` uses raw `sqlite3` (no ORM), FTS5 working (`memory_chunks_fts` virtual table)
- `searchVector()` stub exists (returns empty list) — natural integration point
- `MEMORY.md` is source of truth; `search.db` is a derived, rebuildable index (ADR-002)
- Single-user Mac Mini deployment, low query volume
- DartClaw's outpost pattern: purpose-built CLI tools in the best language for the job, invoked as subprocesses with structured JSON I/O

### Key Discoveries (from trade-off analysis)

1. **QMD (github.com/tobi/qmd) is a mature hybrid search engine** — BM25 + vector (embeddinggemma-300M) + LLM query expansion + LLM reranking (Qwen3). Runs fully local via node-llama-cpp with GGUF models. v1.1.0, actively maintained, 10.5k stars.

2. **QMD's search pipeline is significantly more sophisticated than what DartClaw would build from scratch** — RRF fusion with position-aware blending, top-rank bonuses, query expansion via fine-tuned LLM, cross-encoder reranking. Building custom RRF + cloud embeddings in DartClaw would reinvent a worse wheel.

3. **QMD fits the outpost pattern** — Node.js is QMD's runtime, not DartClaw's. Same relationship as Docker or Deno: externally installed, called via CLI or REST API, structured JSON I/O. No dependency contamination.

4. **QMD indexes markdown files** — DartClaw's memory IS markdown files (`MEMORY.md`, daily logs). The filesystem is the integration point. No "insert chunk" API needed.

5. **QMD's HTTP daemon solves cold-start** — `qmd mcp --http --daemon` keeps models loaded in VRAM. Warm search latency: 26ms (keyword), 117ms (vector), 5-8s (full hybrid with expansion + reranking). Models load lazily.

6. **sqlite-vec Dart bindings exist but are immature** — `sqlite_vector` (sqliteai) on pub.dev, or `sqlite-vec` via native asset build hooks. Both alpha-stage. Cloud embedding APIs (OpenAI) are trivially integrable but add cloud dependency for a system designed to run locally.


### Options Evaluated

| Option | Weighted Score | Verdict |
|---|---|---|
| QMD as outpost (opt-in) | Best fit | **Selected** — proven hybrid search, outpost pattern, fully local |
| Cloud embedding API (OpenAI) | 80% | Viable but reinvents fusion/ranking, adds cloud dependency |
| Local ONNX in Dart | 65% | Not viable — no production Dart FFI path |
| QMD sidecar (bundled) | 27% | Wrong framing — outpost is cleaner than bundled dependency |
| Deno worker embeddings | ~72% | Viable future option for embedding generation |

Research is summarized in the linked appendix.

## Decision

**Two-tier memory search: FTS5 built-in (default) + QMD as optional outpost (opt-in).**

### Tier 1: FTS5 (built-in, always available)

The existing `MemoryService` FTS5 search remains the default. Zero dependencies, zero configuration, works out of the box. This is the baseline that ships with DartClaw.

### Tier 2: QMD (opt-in, user-installed)

When the user explicitly enables QMD in config, DartClaw routes memory search through QMD's REST API, gaining hybrid vector + keyword search with LLM reranking.

```yaml
# config.yaml
search:
  backend: fts5    # default — built-in keyword search
  # backend: qmd   # opt-in — requires qmd installed separately
```

**Integration points:**

1. **Indexing** — DartClaw's memory files (`MEMORY.md`, `~/.dartclaw/memory/`) are added as a QMD collection. After memory writes, DartClaw triggers `qmd update && qmd embed` (incremental — only changed files re-embedded, sub-second with warm daemon).

2. **Search** — Dart host calls QMD's REST endpoint:
   ```
   POST http://localhost:8181/query
   {"searches": [{"type": "lex", "query": "..."}, {"type": "vec", "query": "..."}]}
   ```
   Returns scored results with snippets. DartClaw controls search depth per query: `lex` only (26ms), `lex`+`vec` (sub-200ms), or full `query` with expansion + reranking (5-8s on GPU).

3. **Daemon lifecycle** — DartClaw starts QMD daemon at boot (`qmd mcp --http --daemon`), stops on shutdown. Health check via `GET /health`.

4. **Fallback** — If QMD daemon is unreachable mid-session, DartClaw falls back to FTS5 silently (resilience, not a user-facing choice).

### What DartClaw does NOT build

- Embedding generation (QMD handles via embeddinggemma-300M)
- Vector storage (QMD handles via sqlite-vec)
- RRF fusion, reranking, query expansion (QMD's pipeline)
- sqlite-vec Dart FFI bindings (not needed)
- Cloud embedding API client (not needed)

## Consequences

### Positive

- **No wheel reinvention** — QMD's search pipeline (RRF + reranking + query expansion) is more sophisticated than what DartClaw would build. Leveraging it avoids months of ML/search engineering.
- **Fully local** — All models run on-device. No cloud API dependency, no per-call cost, no data leaving the machine. Aligns with DartClaw's security model.
- **Clean integration** — Outpost pattern: filesystem for indexing, REST for search. No shared runtime, no dependency contamination. QMD's Node.js is invisible to DartClaw.
- **Graceful degradation** — FTS5 always available. QMD is an enhancement, not a requirement. DartClaw works without it.
- **Explicit user choice** — `backend: qmd` in config. No magic detection, predictable behavior.
- **Zero changes to existing code** — FTS5 path stays as-is. QMD integration is additive.

### Negative

- **~2GB model download** — One-time setup via `qmd pull`. Acceptable for a tool explicitly opted into.
- **~2.7-3.5GB RAM when warm** — All three models loaded. Lazy loading helps (lex-only search loads nothing). Requires 16GB+ Mac Mini for comfortable use.
- **GPU soft-requirement for full hybrid** — `lex`+`vec` works fine on CPU. Full `query` with reranking needs GPU (60x slower on CPU for non-English). Apple Silicon M-series has GPU.
- **External dependency** — QMD must be installed separately (`npm install -g @tobilu/qmd`). Requires Node.js 22+. Same as Docker/Deno being prerequisites.
- **QMD maintenance risk** — If QMD becomes unmaintained, DartClaw falls back to FTS5. The outpost pattern means no code entanglement.

### Neutral

- FTS5 `MemoryService` code stays unchanged — the `searchVector()` stub remains for potential future use but is not wired to QMD. QMD integration is a separate search path at a higher level.
- QMD's collection/context model maps naturally to DartClaw's memory file structure.

## Alternatives Considered

### Cloud Embedding API (OpenAI text-embedding-3-small) + sqlite-vec in Dart

Dart host calls OpenAI API for embeddings, stores vectors in sqlite-vec via `sqlite_vector` pub.dev package, implements RRF fusion in Dart.

- **Pros**: Low integration complexity, negligible cost (~$0.02/year), embed-on-write means search is local
- **Cons**: Cloud dependency for writes (violates local-first principle), sends memory content to external API, builds inferior fusion/ranking compared to QMD, sqlite-vec Dart bindings are alpha
- **Rejected because**: Reinvents a worse search pipeline than QMD provides, adds cloud dependency for a system designed to run locally

### Local ONNX in Dart (all-MiniLM-L6-v2)

Bundle ONNX Runtime, run embeddings natively in the Dart process.

- **Pros**: Fully self-contained, zero external deps at runtime, fast inference on Apple Silicon
- **Cons**: No production-ready Dart FFI path (all ONNX packages are Flutter-only), requires building ~500-1000 lines of C-interop code, FFI bugs crash entire Dart process, tokenizer validation needed
- **Rejected because**: Engineering cost disproportionate to benefit. No working reference implementation exists for non-Flutter Dart ONNX inference.

> - **Ollama HTTP** (`llm_ollama` package) — outpost pattern via REST API, `nomic-embed-text` (274MB, 15-50ms latency). Lighter than QMD
> - **llama.cpp server HTTP** (`llamacpp_rpc_client`) — similar pattern, pre-built binaries available
> - **llama_cpp_dart FFI** — in-process embedding via GGUF models, but has Flutter dep issue and build complexity
> - **sqlite_vector** (sqliteai.com) — vector search extension for sqlite3, actively developed, pure Dart compatible. Natural complement to existing FTS5
> - **Cloud embedding APIs** (OpenAI, Voyage, Cohere) — trivially callable from Dart via `dart:io` HttpClient. Appropriate for DirectApiHarness contexts where cloud LLM calls are already being made
>
> The QMD decision remains sound — it provides the most capable search pipeline (RRF + reranking + query expansion). But **Ollama + sqlite_vector** is now a viable lighter alternative for users who don't need LLM reranking.

### Deno Worker Embeddings (@xenova/transformers)

Extend existing NDJSON bridge with `embeddings.generate` method. Deno worker runs all-MiniLM-L6-v2 via ONNX.

- **Pros**: Reuses existing subprocess, fully offline, ~90MB model (vs QMD's ~2GB)
- **Cons**: Only provides embeddings — DartClaw still needs to build vector storage, fusion, ranking. Bridge protocol extension complexity.
- **Rejected because**: Solves only the embedding problem, not the search pipeline. Would still need sqlite-vec + RRF + ranking in Dart.

### QMD Bundled as Sidecar (not outpost)

Bundle QMD inside DartClaw's deployment, manage as internal subprocess.

- **Pros**: Single deployment artifact
- **Cons**: Drags Node.js into DartClaw's runtime boundary, violates outpost pattern, complicates Docker image, version coupling
- **Rejected because**: Outpost pattern is cleaner — QMD is an external tool the user installs and DartClaw calls.

## Implementation Notes

- QMD collection setup can be automated on first `backend: qmd` activation: `qmd collection add ~/.dartclaw/ --name memory --mask "MEMORY.md"` etc.
- `qmd pull` should be recommended in setup docs to pre-download models before first use.
- Search depth (lex-only vs lex+vec vs full query) should be controllable — not every memory lookup needs 5-8s of reranking. Default to `lex`+`vec` for agent memory search, with full `query` available on demand.
- QMD's context feature (`qmd context add`) should be used to describe memory collections, improving search quality.

## References

- QMD repository: https://github.com/tobi/qmd
- QMD v1.1.0 changelog (query document format, REST API)
- Issue #149: HTTP daemon benchmarks (26ms BM25, 117ms vector warm)
- Issue #239: CPU reranker latency (1.2s English, 72s non-English)
- Research sources are summarized in the linked research appendix.
- PRD F26: Hybrid Memory Search requirements
- ADR-002: File-based storage (search.db is derived/rebuildable)
- Research sources are summarized in the linked research appendix.
