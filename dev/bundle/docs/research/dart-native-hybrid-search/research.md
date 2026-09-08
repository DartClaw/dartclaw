# Dart-Native Hybrid Search – Feasibility & Design

**Date**: 2026-07-24
**Status**: Complete – owner decisions resolved 2026-07-25 (§8); **scheduled as 0.26 Phase B** ([brief](../../specs/0.26/hybrid-search-prd-brief.md)); validation spike **passed** 2026-07-25 ([record](spike-llamadart-embeddings.md)); decision recorded in public **ADR-050** (supersedes ADR-004). Both Phase B gates are satisfied – full PRD at planning time
**Scope**: Feasibility and design of DartClaw-native hybrid search (keyword + vector + RRF fusion), removing the QMD outpost dependency – likely as a new package (working name `dartclaw_search`). Answers ADR-045's explicit Phase-3 prerequisite: *"pgvector deferred pending an embedding-source decision."*
**Cross-references**: [ADR-004](../../../../dartclaw-public/dev/adrs/004-vector-search-approach.md) (QMD outpost decision, 2026-02), [ADR-045](../../../../dartclaw-public/dev/adrs/045-pluggable-database-backend.md) (Phase A `FullTextIndex`; Phase B adds `VectorIndex`), [ADR-048](../../../../dartclaw-public/dev/adrs/048-release-builds-dart-build-bundled-sqlite.md) (bundled-native-library precedent), [ADR-002](../../../../dartclaw-public/dev/adrs/002-file-based-storage.md) (search index derived/rebuildable), [ADR-034](../../../../dartclaw-public/dev/adrs/034-enforced-package-dependency-direction.md) (dependency direction), [vector-search-approach](../vector-search-approach/) (prior research; `local-embeddings-dart.md` 2026-03-08 is **superseded** by §2 here on the embedding-source question).

---

## Summary & Bottom Line

**The blocker that produced the QMD decision is gone.** ADR-004 (2026-02) chose the QMD outpost because there was no viable in-process embedding path for pure-Dart AOT. As of 2026-07 there is: **`llamadart`** (pub.dev, v0.8.17, 2026-07-21) provides llama.cpp bindings with **no Flutter dependency**, built on the now-stable Dart build-hooks mechanism – its hook downloads prebuilt llama.cpp bundles and declares them as `DynamicLoadingBundled` code assets, so `dart build cli` ships them in `lib/` beside the AOT binary **exactly like `libsqlite3` today (ADR-048)**. Embeddings are a first-class documented feature.

**Recommendation (detail in §7):** build `dartclaw_search` – a small package composing Phase A's `FullTextIndex` with Phase B's `VectorIndex` with an `EmbeddingProvider` seam and ~50 lines of weighted RRF.
- **Primary embedding source**: in-process GGUF inference via `llamadart`, default model **embeddinggemma-300M Q8_0** (768-dim, 100+ languages, ~300–620 MB – the same model QMD uses, so quality is a known quantity). Gated on a validation spike (§9).
- **Fallback / escape hatch**: an OpenAI-compatible HTTP `EmbeddingProvider` (~100 LOC) that covers local outposts (llama.cpp `llama-server`, Ollama) *and* opt-in cloud (Voyage/OpenAI/Gemini) with one client. If the spike fails, this becomes primary with `llama-server` as the documented default outpost.
- **Vector storage**: SQLite backend = float32 BLOBs + brute-force cosine in Dart (no sqlite-vec – defensible to ~low-100k vectors, far above memory-corpus scale); PostgreSQL backend = pgvector (this unblocks ADR-045 Phase 3).
- **v1 explicitly excludes** LLM query expansion and cross-encoder reranking. QMD's own benchmark justifies this: hybrid fusion alone reaches what its full pipeline reaches on keyword-friendly corpora; the two LLM stages exist for vocabulary-mismatch queries and cost two resident GGUF models. DartClaw's existing LLM harnesses can rerank on demand later.
- **QMD retires** via a deprecation window (§7.4). All three owner decisions resolved 2026-07-25 (§8).

---

## 1. Research Question

The scope is a hybrid retrieval pipeline. Phase A provides FTS5/tsvector keyword search through `FullTextIndex`; Phase B adds vector storage and `VectorIndex`. The remaining gap is:

1. **Embedding generation** – the decisive question (§2)
2. **RRF fusion orchestration** – small pure Dart (§3.5, §5.3)
3. **Optional expansion/reranking** – explicitly out of v1 scope (§5.9)

All web claims below were re-verified 2026-07-24 against primary sources (pub.dev API, GitHub repos/releases, vendor docs) by dedicated research agents; residual unverified items are flagged inline and collected in §9.

---

## 2. Embedding Sources (decisive track)

### 2.1 In-process: llamadart – the headline change

| Fact | Verified value |
|---|---|
| Package | [`llamadart`](https://pub.dev/packages/llamadart) v0.8.17, published 2026-07-21, verified publisher leehack.com, MIT |
| Signal | 160 pub points, 40 likes, ~7.25k weekly downloads, active 0.8.x cadence |
| Flutter dep | **None** – `environment: sdk ^3.10.7`; deps `ffi`, `code_assets ^1.0.0`, `hooks`, `archive`, `http`, `crypto` |
| Embeddings | First-class documented task (dedicated guide) – GGUF embedding models via llama.cpp |
| Native delivery | Build hook downloads **prebuilt llama.cpp bundles from GitHub releases** at build time, tag-pins them (the spike in §9 found that llama.cpp archives are not SHA-256 verified), and declares them as `CodeAsset(linkMode: DynamicLoadingBundled())` → `dart build cli` bundles `.so/.dylib/.dll` into `lib/` beside the binary. No C++ toolchain for consumers. The old libllama/libggml split pain is absorbed inside the bundles |
| Platforms | Linux, macOS 14+, Windows (+ mobile; irrelevant here) |

This is the **same shipping model as `package:sqlite3`** (ADR-048): one `dart build cli` per target, native libs as inspectable siblings in `lib/`. The Dart build-hooks mechanism itself is **stable since Dart 3.10**; static-linking issue [dart-lang/sdk#47718](https://github.com/dart-lang/sdk/issues/47718) remains open but is irrelevant (the whole ecosystem uses dynamic bundled assets).

**Honest risks**: young pre-1.0 package, single maintainer (pin version, treat as swappable behind the `EmbeddingProvider` seam); build hook needs **build-time network access to GitHub releases** (mirrors the existing `andthen.network` gating concern – pin/mirror bundles for reproducible release builds and supply-chain review); AOT `dart build cli` end-to-end with embeddings **not yet verified by us** → spike (§9). `dartantic_llamadart` (2026-07-22) exists as a higher-level pure-Dart wrapper over the same engine if the raw API is awkward.

Other llama.cpp bindings, for completeness: `llama_cpp_dart` (netdur) **still hard-depends on Flutter** (v0.2.2, 2026-01-02) – ADR-004's blocker stands for that package specifically; `llama_cpp` (lindeer) stale since 2025-02 on the pre-stable native-assets API.

### 2.2 ONNX: still no pure-Dart path

Every maintained ONNX runtime wrapper remains Flutter-bound (`flutter_onnxruntime` 1.8.3, `onnxruntime_plus`, `sherpa_onnx`); `fonnx` appears gone from pub.dev (API 404). Hand-rolled FFI against a self-shipped `libonnxruntime` is feasible but unowned by anyone. One notable change: the tokenizer gap is now closed – [`hf_tokenizers`](https://pub.dev/packages/hf_tokenizers) v0.5.1 (2026-07-23, pure Dart, no Flutter, FFI to the Rust HF tokenizers crate, byte-exact BPE/WordPiece/Unigram) – but with llamadart available (tokenizer embedded in GGUF), assembling an ONNX stack by hand is unjustified. **Not recommended.**

### 2.3 Static embeddings: model2vec

[`model2vec`](https://pub.dev/packages/model2vec) v2.0.0 (2026-07-07, no Flutter): static token-lookup + mean-pool (no transformer), microsecond embeds, ships `potion-multilingual-128M` (101 languages). Caveats: build hook **compiles the Rust core via rustup at `pub get`** (Rust toolchain in CI – heavier than llamadart's prebuilt download), and static-embedding quality is meaningfully below transformer models, with **no verified Swedish numbers**. Interesting fallback niche (zero-model-download, tiny RAM) but not the primary. The approach is also trivially reimplementable in pure Dart later if ever wanted.

### 2.4 Platform-native OS APIs: not a credible primary

- **macOS**: `NLContextualEmbedding` (macOS 14+) is the only OS-inbox raw-vector API – 512-dim **per-token** vectors (manual mean-pooling), Latin-script model covers ~20 languages (Swedish highly likely but not enumerated by Apple anywhere findable), one-time OS-managed asset download, 2023-era quality that local-embedding projects (VecturaKit, ModelPiper) actively bypass in favor of downloaded models. Apple's Foundation Models framework (verified against the WWDC26 session) exposes **no embedding API** – only generation + a Spotlight RAG tool.
- **Windows**: **no GA embedding API.** Windows AI "Semantic Search" has sat in private preview since Build 2025, Copilot+/NPU-gated; Phi Silica is mid-retirement (→ "Aion Instruct", Nov 2026). Real local embeddings on Windows mean a downloaded model anyway (Foundry Local).
- **Linux**: nothing, as expected.

Two of three platforms have nothing usable, so a portable primary path is mandatory regardless – and it then covers macOS too. Not worth even a macOS-only fast path given the 512-dim quality ceiling and shim cost. **Rejected.**

### 2.5 Cloud APIs (explicit opt-in) – landscape

Verified mid-2026 state:

| Provider | Model | Dims | $/M tok | Multilingual signal | Privacy posture |
|---|---|---|---|---|---|
| **Voyage AI** (MongoDB-owned since 2025-02) | voyage-4 family (2026-01-15); shared embedding space across -4/-4-lite/-4-large (no re-index on tier switch) | 1024 default, MRL 256–2048 | 0.02–0.12 | explicit multilingual focus; 32k ctx | per-org training opt-out (irreversible); 200M free tokens |
| **Google** | gemini-embedding-001 (+ embedding-2-preview, multimodal, 2026-03) | 3072, MRL 768/1536 | 0.15 | vendor-reported #1 MTEB(Multilingual) 68.32 | Vertex: no-training default, enterprise ZDR-equivalent |
| **OpenAI** | text-embedding-3-small/large (unchanged – no successor shipped) | 1536/3072, MRL | 0.02/0.13 | "improved multilingual", no published Swedish figure | ZDR exists but enterprise-sales-gated |
| **Cohere** | embed-v4.0 (2025-04) | 1536, MRL | 0.12 | 100+ languages claim | enterprise ZDR sales-gated |
| **Anthropic** | **none** – docs still say "Anthropic does not offer its own embedding model" and point to Voyage | – | – | – | – |

Cost is a non-factor at agent-memory scale: 50k chunks × 500 tok ≈ 25M tokens ≈ **$0.50–$3.75 one-time**; incremental embed-on-write rounds to **well under $1/month** on every provider. The real considerations are (a) memory content leaving the trust boundary on every write and (b) semantic indexing going down when offline. Note the posture shift since ADR-004: DartClaw already makes cloud LLM calls in DirectApiHarness contexts, so *opt-in* cloud embeddings are no longer categorically off-posture – **flagged as an owner decision (§8)**. No provider has a published isolated Swedish score; the SEB/MTEB(Scandinavian) leaderboard must be pulled before any cloud model is pinned.

### 2.6 Lighter outposts

If an external process is acceptable at all, both are far lighter than QMD (Node 22 + ~2 GB models + ~3 GB RAM warm):

- **llama.cpp `llama-server`** – best structural fit: single prebuilt binary per platform (macOS arm64 **with Metal**, Linux x64, Windows), `--embeddings` + OpenAI-compatible `/v1/embeddings`, no accounts/cloud coupling, continuous releases through mid-2026. Cost: manual GGUF download (acceptable for a pinned-model outpost).
- **Ollama** – easier model UX (`ollama pull embeddinggemma`), embeddinggemma/bge-m3/snowflake-arctic-embed2/qwen3-embedding all in the library; but embedding requests still appear serialized (issues #8778/#12591 open), and the company's accounts/cloud push is a direction risk (local API still unauthenticated; `OLLAMA_NO_CLOUD=1` exists).
- Not competitive: HF TEI (needs cargo build for macOS Metal), LM Studio (Electron; embedding-endpoint bug status unverified), llamafile (revived under mozilla.ai but no small prebuilt embedding llamafile).

The key architectural point: **one OpenAI-compatible HTTP embedder client covers llama-server, Ollama, LM Studio, and cloud providers** – a single ~100-LOC fallback implementation buys the entire non-in-process space.

### 2.7 Model choice (independent of transport)

| Model | Size (quant) | Dims | Ctx | Multilingual/Swedish signal |
|---|---|---|---|---|
| **embeddinggemma-300M** (default candidate) | ~300–620 MB Q4/Q8 | 768 (MRL) | short/medium | 100+ languages; dedicated Scandinavian finetune exists (`emillykkejensen/EmbeddingGemma-Scandi-300m`, DDSC Nordic data); **QMD's own default → known quality baseline** |
| qwen3-embedding-0.6B | ~600 MB+ | 32–1024 (MRL) | 32k | best sub-1GB MTEB-multilingual found (64.33) |
| bge-m3 | larger | 1024 | 8k | strong multilingual, battle-tested |
| multilingual-e5-small | ~130 MB | 384 | 512 | 512-token ctx too short for 900-token chunks |

Swedish-specific SEB numbers were not retrievable via search; **pull the live MTEB Scandinavian leaderboard during the spike** before pinning the default.

---

## 3. Architecture Survey

### 3.1 QMD v2.6.3 internals – and what replacing it loses

QMD has evolved massively since the v1.1.0 that ADR-004 evaluated: now v2.6.3 (2026-06-24), Node ≥ 22 (Bun alternate), high release velocity, PRs into the #700s. Verified from source:

- **Chunking**: 900 tokens, 15% overlap, heading-scored break points (H1=100 … newline=1, codeblock=80) searched back over a 200-token window with squared-distance decay `score × (1 − (d/w)² × 0.7)`; never splits inside code fences; optional tree-sitter AST break points for code files.
- **Storage**: content-addressable (`content(hash)` dedup) + `content_vectors` metadata + sqlite-vec `vec0` float32 768-dim cosine (no quantization). **Re-embedding is content-hash + fingerprint driven**: a 6-hex fingerprint over `{model, prompt formats, chunk params}` – changing model *or* chunking invalidates vectors and only the delta re-embeds.
- **Keyword**: FTS5 `porter unicode61`, `bm25(fts, 1.5, 4.0, 1.0)` (title 4× body), CTE-first to dodge a query-planner cliff, hand-rolled query sanitizer (prefix quoting, hyphen/dot handling, CJK), monotonic normalization `|bm25|/(1+|bm25|)`.
- **Fusion**: weighted RRF `weight/(k + rank + 1)`, k=60, **weights by query origin** (original query 2×, expansion-derived 1× – a real bug fix, #591), top-rank bonus (+0.05 rank-1, +0.02 ranks 2–3).
- **Expansion**: custom SFT Qwen3-1.7B (author-finetuned, Q4_K_M) emitting GBNF-constrained `lex:/vec:/hyde:` lines; **skipped entirely when BM25 signal is strong** (top ≥ 0.85 and gap ≥ 0.15).
- **Rerank**: Qwen3-Reranker-0.6B Q8_0 cross-encoder via node-llama-cpp `rankAll`, top-40 candidates, **single best chunk per doc** (never full bodies), then position-aware blending (RRF weight 0.75 at ranks ≤ 3, 0.60 ≤ 10, 0.40 below – protects high-confidence retrieval from reranker disagreement).
- **Depth tiers**: lex / vec / hybrid-no-rerank / full – with a bench harness reporting per-tier precision/recall/MRR.

**What a minimal replacement loses – per QMD's own benchmark**: bm25 ≈ 0.50, vector ≈ 0.70, **hybrid (RRF, no rerank) ≈ 1.00, full ≈ 1.00** on its example fixture. The hybrid fusion step – which DartClaw keeps – carries essentially all the measured gain; expansion exists for vocabulary-mismatch/nuanced queries the fixture doesn't test, and reranking improves top-3 ordering on ambiguous sets. Those two stages cost two resident GGUF LLMs, VRAM management, and 5–8 s full-pipeline latency. This is the empirical core of the retire-QMD case.

**Design ideas worth stealing** (all model-free, all portable to Dart): the weighted-RRF formula + monotonic score normalization; the heading-scored code-fence-safe chunker; content-hash + fingerprint incremental re-embedding; best-chunk-per-doc snippet selection; typed `{lex|vec}` sub-query lists + strong-signal bypass as the future extensibility seam.

### 3.2 In-database hybrid on PostgreSQL

The canonical pattern (verified against Supabase docs and Jonathan Katz's post, independently identical math): two ranked subqueries (tsvector/`ts_rank` + pgvector KNN, each with its own inner `LIMIT`), joined (FULL OUTER or UNION ALL + GROUP BY), scored by `coalesce(w/(k + rank), 0)` per side. Katz packages it as a tiny `rrf_score(rank, k)` IMMUTABLE SQL function – portable near-verbatim. **Fusion can run entirely in-database in one statement, zero Dart orchestration.** pgvector is at 0.8.x (0.8.2, 2026-02, CVE fix); HNSW is the standard choice; iterative index scans (0.8.0) fix the ANN+filter under-fetch problem; `halfvec` halves storage if ever needed. No extension ships a one-call RRF primitive (ParadeDB/VectorChord document recipes, not built-ins) – hand-written SQL remains the norm.

### 3.3 SQLite vector story

- **sqlite-vec** (asg017): still pre-v1 (0.1.9, 2026-03-31) with a documented 2025 dormancy period before a 2026 revival; Dart PR #119 still unmerged. Consistent with ADR-045 R4: do not productionize.
- **sqlite_vector** (sqliteai): real Dart package (0.9.85, Dart 3.10+), brute-force-first design – the practical choice *if* an extension were ever needed.
- **Brute force in Dart**: practitioner consensus puts flat float32 scanning as fine up to roughly the low hundreds of thousands of vectors. DartClaw's memory corpus is 10³–10⁴ chunks – **two to three orders of magnitude below the ceiling**. A 10k × 768-dim float32 scan is ~30 MB and single-digit milliseconds. → v1 needs **no SQLite vector extension at all**: store float32 BLOBs, scan in Dart behind `VectorIndex`. This also keeps ADR-045's "SQLite backend has no in-database vector path" statement true.

### 3.4 Other systems – takeaways only

- **Meilisearch**: embedder config as named entries with `source:` (openai/ollama/rest/userProvided) – good config-shape prior art; their tracker shows embedder failure handling is easy to get wrong → make embed failures loud in logs even when degrading gracefully.
- **Khoj**: standard bi-encoder recall + cross-encoder precision split – confirms rerank is a separable, later-stage concern.
- **Letta/MemGPT**: retrieval-as-tool-call (agent decides when to search) – matches DartClaw's existing `memory_search` MCP tool model; no change needed.
- **tantivy/lnx**: healthy Rust FTS library, but embedding a search library duplicates what the DBs already provide – evidence *for* the compose-DB-primitives approach.

### 3.5 RRF parameter lore

k=60 originates in Cormack, Clarke & Büttcher (SIGIR 2009); vendors drift to k=50 (Supabase/Katz). Weighted-RRF (per-source multiplier) is the well-attested extension. Bruch et al. (arXiv:2210.11934) show tuned convex combination beats RRF *once labeled tuning data exists* – ship RRF first (zero tuning, no score normalization needed), record convex combination as the informed upgrade. Keep k and weights identical across backends so ranking differences come only from the underlying rank functions (ADR-045 already pins cross-backend parity to set-membership, not order).

---

## 4. Historical DartClaw Seams (verified in-repo, 2026-07-24)

Historical scan of `dartclaw-public@main`. The package names, per-edge allowlist and filename-based corpus below predate 0.25. The [refreshed Phase B brief](../../specs/0.26/hybrid-search-prd-brief.md) and ADR-056 govern execution; do not restore these retired surfaces.

- `SearchBackend` contract lives in **`dartclaw_config`** (`lib/src/search_backend.dart`): `search(query, {limit, userId})` + `indexAfterWrite()`; re-exported via `dartclaw_core`. (ADR-004's header saying the QMD classes live in `dartclaw_core` is stale – implementations are in **`dartclaw_storage/lib/src/search/`**: `Fts5SearchBackend`, `QmdSearchBackend`, `QmdManager`, `SearchBackendFactory`.)
- `MemoryService` FTS5: default `unicode61` tokenizer (not even porter), external-content table + sync triggers, `rank` ordering, `user_id` equality filter. `searchVector()` stub still present and dead.
- Chunking today is inconsistent: live writes split at **500 chars** by paragraph (`MemoryFileService.splitParagraphs` via `memory_handlers.onSave`); `rebuild-index` re-indexes **whole MEMORY.md entries** unchunked, and only from `MEMORY.md`.
- **No embedding, vector, cosine, or RRF code exists anywhere** in the workspace; no sqlite-vec/sqlite_vector dependency.
- Consumers of `SearchBackend`: memory MCP tools (`memory_search` etc. via `createMemoryHandlers`), `ContextResearchTool`, all wired once in `StorageWiring`. No public REST search endpoint.
- ADR-034 dependency-direction is CI-enforced via an explicit edge allowlist – a new package requires new allowlist rows with rationale.

---

## 5. Design Sketch: `dartclaw_search`

This is the pre-ADR sketch. Its package graph and open build-flavor question are superseded by ADR-050's one-binary decision, ADR-056's package tiers and the current Phase B brief. Interface sketches are inputs to specification against the landed Phase A seams, not implementation contracts.

### 5.1 Package placement

A separate package is justified by one hard reason: **isolating the llamadart native-asset dependency** so core/storage consumers don't fetch/bundle llama.cpp unless search is wanted (parallel to ADR-045's open question on excluding `postgres` from solo binaries; same build-flavor question applies and should be decided together).

Dependency direction (ADR-034): `dartclaw_search` depends on contracts only (`dartclaw_config` for `SearchBackend`, `dartclaw_models`; plus wherever 0.25 lands `FullTextIndex`/`VectorIndex` – to be confirmed at 0.25 spec time). Concrete index implementations are **injected** – `dartclaw_search` never imports `dartclaw_storage`. New allowlist edges: `dartclaw_storage -> dartclaw_search` (or wiring-level composition in `dartclaw_cli`), each with rationale.

### 5.2 Interfaces (sketch)

```dart
abstract interface class EmbeddingProvider {
  /// Returns null on failure – caller degrades to keyword-only.
  Future<List<Float32List>?> embed(List<String> texts, {required EmbedInput kind});
  int get dimensions;
  String get fingerprint; // model id + params hash – invalidation key (QMD pattern)
}

class HybridSearchBackend implements SearchBackend {
  // Composes: FullTextIndex (0.25) + VectorIndex (0.25) + EmbeddingProvider + RrfFusion.
  // search(): run keyword + vector queries, fuse with weighted RRF, map to MemorySearchResult.
  // Degrades to FullTextIndex-only when embedder or vectors unavailable (ADR-004 fallback precedent, but logged loudly – Meilisearch lesson).
}
```

Two v1 `EmbeddingProvider` implementations: `LlamaEmbeddingProvider` (in-process llamadart, GGUF model) and `OpenAiCompatibleEmbeddingProvider` (HTTP; base URL + optional API key – covers llama-server, Ollama, LM Studio, and cloud endpoints).

### 5.3 Fusion strategy

**v1: Dart-side weighted RRF on both backends** (`score = Σ w/(k + rank + 1)`, k=60 default, identical constants across backends) – one code path, trivially contract-testable, two queries per search is negligible at memory scale. The in-database single-statement PG fusion (§3.2) is recorded as a later optimization – it would need a third seam (hybrid query pushdown) and is not worth it until latency data says so. Set-membership remains the only cross-backend parity contract (ADR-045 #8b).

### 5.4 Embed-on-write & failure posture

- `insertChunk` path: store chunk (FTS indexes it immediately) → async embed → store vector on success. Embedder failure = chunk simply has no vector; **search silently degrades to keyword-only for those chunks** (per ADR-004's fallback precedent), with a loud log + a visible "N chunks unembedded" counter (status surface), never a hard error.
- Circuit breaker after consecutive failures; backfill of missing vectors on `indexAfterWrite` and rebuild.
- Vectors keyed by content hash + embedder fingerprint (QMD pattern): model or chunk-param change ⇒ affected vectors invalid ⇒ incremental re-embed of the delta only.

### 5.5 Chunking

Adopt QMD's heading-scored, code-fence-safe break-point chunker (~150 LOC, model-free, §3.1) with token-budget targets, replacing the current inconsistent 500-char/whole-entry split (§4) – `dartclaw_search` becomes the single owner of chunking for indexed memory content. Defaults: ~800–900 tokens, ~15% overlap (validate in spike against embeddinggemma's effective context).

### 5.6 Per-language behavior

Embeddings sidestep stemming entirely: Swedish semantic recall works identically on both backends, including the SQLite default where FTS5 `unicode61` does no stemming. Keyword-side language awareness remains backend-specific (tsvector `swedish` config on PG per ADR-045; none on SQLite) – hybrid search therefore narrows, but does not close, the SQLite↔PG multilingual keyword gap. State this plainly in user docs.

### 5.7 Rebuild / migration

Search index stays derived + rebuildable (ADR-002). `rebuild-index` gains re-embedding; the content-hash cache means unchanged chunks are not re-embedded on rebuild. Full re-embed of a 50k-chunk corpus is bounded and offline-safe locally (~10–50 ms/chunk in-process ⇒ minutes, not hours); dimension/model changes are just a fingerprint-invalidation + rebuild, no schema migration.

### 5.8 Config sketch

```yaml
search:
  backend: fts5          # default (unchanged) | hybrid | qmd (deprecated)
  embedding:
    provider: local       # local (llamadart) | http (OpenAI-compatible) | none
    model: embeddinggemma-300m   # resolved to pinned GGUF + checksum
    endpoint: http://...  # http provider only
    api_key: ${VAR}       # http provider only; credential-reference model per ADR-045
  rrf_k: 60
```

`backend: hybrid` with no model present prompts a one-time model download (pinned URL + checksum, honoring the existing network-gating posture; same UX shape as `qmd pull` / Ollama).

### 5.9 v1 exclusions (recorded deliberately)

- **Query expansion** – requires a resident generative LLM; QMD's own bench shows no gain on keyword-friendly corpora. The typed sub-query fusion seam (§3.1) keeps the door open.
- **Cross-encoder reranking** – same cost logic. DartClaw's existing LLM harnesses can rerank top-K on demand (an agent-visible "deep search" affordance later) without any resident model.
- **SQLite vector extension** – brute force suffices at corpus scale (§3.3); revisit only if a corpus approaches ~10⁵ vectors.
- **Convex-combination scoring** – upgrade path once relevance-judgment data exists (§3.5).

### 5.10 Scope (package, not stories)

~1–1.5k production LOC: `EmbeddingProvider` seam + llamadart impl (~250) + HTTP impl (~100), chunker (~150), RRF fusion (~50), `HybridSearchBackend` + degradation logic (~200), hash/fingerprint embed pipeline (~200), model download/verify (~150), plus contract tests reusing the `searchBackendContractTests` pattern and a small QMD-style 4-tier bench fixture (bm25/vec/hybrid) to prove the quality claim on DartClaw's own corpus shape.

---

## 6. Trade-off Analysis

Embedding-source options scored against the binding Core Philosophy (dependency minimalism, AOT single-binary story, local-first, approachable), multilingual/Swedish quality, and the 0.25 seams:

| Option | Local-first | Packaging/AOT | Dep risk | Multilingual quality | Ops burden | Verdict |
|---|---|---|---|---|---|---|
| **A. In-process llamadart + GGUF** | ✅ fully | ✅ = sqlite3 precedent (libs in `lib/`); model = one-time pinned download | ⚠ pre-1.0 single maintainer, behind a seam | ✅ model-dependent (embeddinggemma/qwen3) | Low (no external process) | **Primary (spike-gated)** |
| **B. Outpost llama-server (HTTP)** | ✅ | binary external – user installs | Low (llama.cpp itself) | same models | Medium (install + lifecycle) | **Fallback default** |
| C. Cloud API opt-in (Voyage/Gemini/OpenAI) | ❌ writes leave boundary | ✅ trivial (~100 LOC shared with B) | Low | ✅ best-in-class | Lowest | Opt-in tier only – owner call (§8) |
| D. Keep QMD | ✅ | ❌ Node 22 + ~2 GB models | Medium (fast-moving external app) | ✅ (same embedder!) | High | Retire (§7.4) |
| E. model2vec static | ✅ | ⚠ Rust toolchain in CI | Medium | ⚠ unverified, structurally lower | Low | Not now |
| F. Platform-native (NLContextualEmbedding …) | ✅ | macOS-only | – | ⚠ 512-d, dated | – | Rejected |

A + B share the `EmbeddingProvider` seam and the same GGUF models – B is both the fallback if the llamadart spike fails *and* the permanent escape hatch if llamadart's maintenance falters. C rides B's HTTP client for near-zero extra code.

---

## 7. Recommendation (ADR seed)

### 7.1 Decision shape

**Build `dartclaw_search`: keyword + vector + weighted-RRF hybrid search composed from Phase A's `FullTextIndex` and Phase B's new `VectorIndex`, with embedding generation behind an `EmbeddingProvider` seam. Primary provider: in-process llamadart with embeddinggemma-300M Q8_0 (768-dim). Fallback provider: OpenAI-compatible HTTP (local outposts; cloud endpoints as documented explicit opt-in, decided §8). SQLite vectors: float32 BLOB + Dart brute-force cosine. PostgreSQL vectors: pgvector – this decision supplies the embedding source ADR-045 Phase 3 was deferred on.**

### 7.2 Why this wins

1. **The 2026-02 blocker is empirically gone** – llamadart ships llama.cpp exactly the way DartClaw already ships SQLite (ADR-048), on a now-stable SDK mechanism.
2. **QMD's own benchmark says the fusion core is where the quality lives** – the two stages DartClaw won't build (expansion, rerank) are the expensive ones with fixture-invisible gains.
3. **Model continuity de-risks quality** – same embedder QMD uses today; Swedish story strengthened by MRL 768-dim multilingual training + an existing Scandinavian finetune, pending SEB verification.
4. **Philosophy fit** – removes Node 22 + npm from the recommended path (minimal attack surface), ~1–1.5k auditable LOC, no speculative stages, graceful keyword-only degradation preserved.

### 7.3 Gates before the ADR is written

A short validation spike must confirm: (1) `dart build cli` end-to-end with llamadart on macOS arm64 + Linux x64 (bundle layout, binary size delta, RAM with model resident – expect ~0.5 GB); (2) embedding API correctness (parity vs reference embeddinggemma output); (3) a small Swedish/English retrieval eval (SEB leaderboard pull + ~50-query fixture on real memory data, 4-tier bench per §5.10); (4) supply-chain review of llamadart's prebuilt bundles + a pin/mirror plan. If (1) or (2) fails → fallback becomes primary: same package, HTTP provider, `llama-server` as documented default outpost; the design is otherwise unchanged.

### 7.4 What retires QMD

`QmdManager`, `QmdSearchBackend`, the `backend: qmd` factory branch, daemon lifecycle wiring, and the QMD sections of the user guide. Sequence: ship `dartclaw_search` hybrid → mark `backend: qmd` deprecated (config warning) in the same release → remove one milestone later. Rationale: with hybrid built-in, QMD's residual edge (expansion + rerank) no longer justifies Node 22 + two resident LLMs as a *recommended* integration; the isolated `SearchBackend` seam makes keeping it cheap during the window and makes the removal surgical. (If the owner prefers, QMD can survive indefinitely as an unadvertised power tier at near-zero code cost – but the recommendation is removal: bloat is expensive to remove, and the deep-search niche is better served later by on-demand harness reranking.)

---

## 8. Owner Decisions (resolved 2026-07-25)

All three decided by owner, 2026-07-25 – binding on the future ADR:

1. **Cloud embeddings as a documented opt-in provider tier – ACCEPTED.** `provider: http` may point at cloud endpoints (Voyage/OpenAI/Gemini); user docs carry the data-leaves-trust-boundary caveat. Default stays local. (Context: ADR-004 rejected cloud on local-first grounds; DirectApiHarness has since normalized opt-in cloud LLM calls; same HTTP client as local outposts, zero extra code.)
2. **QMD: deprecate then remove.** Mark `backend: qmd` deprecated (config warning) at `dartclaw_search` hybrid GA; remove `QmdManager`/`QmdSearchBackend`/factory branch + docs one milestone later (§7.4).
3. **Build flavor: one binary, all-in.** `dartclaw_search`'s native assets ship in the default solo binary; no slim flavor. This also closes ADR-045's Open Question 3 the same way: the `postgres` package compile-in cost is accepted, no conditional-import flavor. Revisit only if the validation spike shows an unacceptable size delta.

## 9. Unverified Items — spike resolution (2026-07-25)

The validation spike (§7.3) ran 2026-07-25 and **passed** – full record in [spike-llamadart-embeddings.md](spike-llamadart-embeddings.md); summary in [hybrid-search-prd-brief.md §Gates](../../specs/0.26/hybrid-search-prd-brief.md).

- ~~llamadart AOT end-to-end~~ **Verified**: macOS arm64 (16 MB bundle, RSS ≈ 477 MB, ~7 ms/doc) and Linux arm64 (Docker; needs `libgomp1`; llamadart hangs instead of erroring on lib-load failure – upstream bug, wrapper needs init timeout). Parity vs llama-server: cosine 1.000000. Linux x64/Windows pending at CI time.
- ~~Swedish retrieval quality~~ **Board pulled + fixture run**: MTEB(Scandinavian) – qwen3-embedding-0.6B #21 (ret 61.85), gemma Scandi finetune #51 (ret 54.52), base gemma only partially evaluated. But on the spike's own sv/en fixture embeddinggemma-300M beat qwen3 (1.00 vs 0.94 hit@1, stronger cross-lingual) at half the size – default stays embeddinggemma-300M; re-eval with a larger fixture at spec time.
- ~~Bundle provenance~~ **Verified**: tag-pinned GitHub releases (leehack/llamadart-native); working user-define overrides for tag/repo/local-path and runtime selection (llama.cpp-only trims Linux lib/ 194→98 MB); **llama.cpp archives not sha256-verified by the hook** – mirror or local-path override for release builds.
- Still open: Ollama embedding-serialization fix status (only if outpost path exercised); Cohere embed-v4 max input tokens; vendor-reported MTEB numbers for cloud APIs.

---

## Sources

Consolidated from seven research passes (2026-07-24); full per-claim URLs retained in the sections above. Primary anchors:

- pub.dev: [llamadart](https://pub.dev/packages/llamadart) · [dartantic_llamadart](https://pub.dev/packages/dartantic_llamadart) · [hf_tokenizers](https://pub.dev/packages/hf_tokenizers) · [model2vec](https://pub.dev/packages/model2vec) · [sqlite_vector](https://pub.dev/packages/sqlite_vector) · [llama_cpp_dart](https://pub.dev/packages/llama_cpp_dart)
- GitHub: [leehack/llamadart](https://github.com/leehack/llamadart) (incl. `hook/build.dart`) · [tobi/qmd](https://github.com/tobi/qmd) @ v2.6.3 (source-level: `src/store.ts`, `src/llm.ts`, `src/mcp/server.ts`, `src/ast.ts`) · [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp/releases) · [asg017/sqlite-vec](https://github.com/asg017/sqlite-vec) (releases, PR #119, #226) · [dart-lang/sdk#47718](https://github.com/dart-lang/sdk/issues/47718)
- Hybrid patterns: [Supabase hybrid search](https://supabase.com/docs/guides/ai/hybrid-search) · [J. Katz – hybrid search with pgvector](https://jkatz05.com/post/postgres/hybrid-search-postgres-pgvector/) · [pgvector 0.8.0/0.8.2 announcements](https://www.postgresql.org/about/news/pgvector-080-released-2952) · [ParadeDB hybrid manual](https://www.paradedb.com/blog/hybrid-search-in-postgresql-the-missing-manual) · [VectorChord hybrid docs](https://docs.vectorchord.ai/vectorchord/use-case/hybrid-search.html)
- RRF: Cormack, Clarke & Büttcher, SIGIR 2009 (DOI 10.1145/1571941.1572114) · [Bruch et al., arXiv:2210.11934](https://arxiv.org/abs/2210.11934)
- Platform: [NLContextualEmbedding](https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding) · [WWDC26 Foundation Models session](https://developer.apple.com/videos/play/wwdc2026/241/) · [Windows AI APIs (2026-07-15)](https://learn.microsoft.com/en-us/windows/ai/apis/)
- Cloud: [Anthropic embeddings guide (recommends Voyage)](https://platform.claude.com/docs/en/build-with-claude/embeddings) · [Voyage pricing/docs](https://docs.voyageai.com/docs/pricing) · provider pages per §2.5
- Models: [google/embeddinggemma-300m](https://huggingface.co/google/embeddinggemma-300m) · [EmbeddingGemma-Scandi-300m](https://huggingface.co/emillykkejensen/EmbeddingGemma-Scandi-300m) · [ggml-org/embeddinggemma-300M-GGUF](https://huggingface.co/ggml-org/embeddinggemma-300M-GGUF) · [Qwen3-Embedding-0.6B-GGUF](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF) · [SEB](https://kennethenevoldsen.com/scandinavian-embedding-benchmark/) ([paper](https://arxiv.org/abs/2406.02396))
- Dart toolchain: [Dart 3.10 announcement (build hooks stable)](https://blog.dart.dev/announcing-dart-3-10-ea8b952b6088) · [dart.dev/tools/hooks](https://dart.dev/tools/hooks)
- In-repo: `dartclaw-public` scan 2026-07-24 (`packages/dartclaw_storage/lib/src/search/*`, `packages/dartclaw_config/lib/src/search_backend.dart`, `packages/dartclaw_storage/lib/src/storage/memory_service.dart`, `apps/dartclaw_cli/lib/src/commands/wiring/storage_wiring.dart`, `packages/dartclaw_testing/test/fitness/dependency_direction_test.dart`)
