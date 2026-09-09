# ADR-050: Native Hybrid Search (`dartclaw_search`) – In-Process Embeddings, Retiring the QMD Outpost

**Status:** Accepted – 2026-07-25; amended 2026-09-09 to restore agent-independent retrieval. Implemented in **0.26** after its Phase A storage seams. Supersedes [ADR-004](004-vector-search-approach.md); QMD is deprecated but still works in 0.26 and is removed in the following milestone. Validation spike passed 2026-07-25; final held-out and platform acceptance remain separate release gates.
**Deciders:** DartClaw team

**Related:** [ADR-004](004-vector-search-approach.md) (superseded – QMD outpost), [ADR-045](045-pluggable-database-backend.md) (`FullTextIndex`/`VectorIndex` seams; this ADR delivers its former Phase 3), [ADR-048](048-release-builds-dart-build-bundled-sqlite.md) (bundled-native-library shipping precedent), [ADR-034](034-enforced-package-dependency-direction.md) (dependency direction), [ADR-002](002-file-based-storage.md) (search index is derived/rebuildable)

---

## Context

ADR-004 (2026-02) chose the QMD outpost for semantic memory search because no in-process embedding path existed for pure-Dart AOT – every ONNX/llama.cpp binding was Flutter-bound. That premise is gone as of mid-2026: **`llamadart`** (pub.dev, pure Dart, no Flutter) binds llama.cpp via the now-stable Dart build-hooks mechanism; its hook downloads prebuilt llama.cpp bundles and declares them as `DynamicLoadingBundled` code assets, so `dart build cli` ships them in `lib/` beside the AOT binary – exactly how `libsqlite3` ships today (ADR-048).

Meanwhile ADR-045's 0.26 Phase A creates the retrieval seams (`FullTextIndex`; `tsvector` language-aware keyword search on PostgreSQL) and deferred `pgvector` (former Phase 3) solely on the missing embedding source. The remaining gap for built-in hybrid search is: embedding generation, ~50 lines of RRF fusion, and vector storage per backend.

The full landscape analysis (embedding sources, QMD v2.6.3 internals, hybrid-search architecture survey) is in the private research `dartclaw-private/docs/research/dart-native-hybrid-search/research.md`; a frozen public synthesis is in the [research appendix](research/050-native-hybrid-search.md).

**Validation spike (2026-07-25, passed; full record in the private research dir):**
- macOS arm64 `dart build cli`: 6 MB binary + 10 MB `libllamadart.dylib`, ADR-048 shape; max RSS ≈ 477 MB with embeddinggemma-300M resident; ~7 ms/doc embed.
- Linux (Docker `dart:stable`): works; needs `libgomp1` at runtime. The historical 0.8.17 native-library
  refusal motivated the lifecycle investigation; it is not evidence about the selected dependency.
- Parity: cosine 1.000000 vs llama.cpp's own `llama-server` on the same GGUF.
- Swedish/English retrieval fixture: unstemmed keyword-only 0.38 hit@1 (0.00 on Swedish inflection/compound/vocabulary-mismatch – the motivating gap); embeddinggemma-300M vector 1.00/1.00 incl. cross-lingual; hybrid RRF 0.94. Qwen3-Embedding-0.6B head-to-head: 0.94, missed the hardest Swedish semantic query, weaker cross-lingual, 2× size.

## Decision

**Build `dartclaw_search`: built-in hybrid memory search (keyword + vector + weighted RRF) composing the ADR-045 seams, with embedding generation behind an `EmbeddingProvider` seam. Retire QMD via a deprecation window.**

1. **New package `dartclaw_search`**: sits on T1 and depends only on `dartclaw_kernel`; concrete
   `FullTextIndex`/`VectorIndex` implementations are injected. The package isolates the llamadart native-asset dependency from
   the core graph, while core retains concrete database indexes and canonical corpus mapping.
2. **Primary embedding source: in-process llamadart** (pinned exact version), default model **embeddinggemma-300M Q8_0** (768-dim, multilingual; QMD's own default – known quality baseline; fixture-validated for Swedish). Model is a one-time pinned-URL + checksum download, honoring the network-gating posture.
3. **Fallback + escape hatch: OpenAI-compatible HTTP provider** (~100 LOC; base URL + optional API key) covering local outposts (llama.cpp `llama-server`, Ollama, LM Studio) and – as **documented, explicit opt-in** (owner-accepted 2026-07-25) – cloud endpoints (Voyage/OpenAI/Gemini). Default remains local; user docs carry the data-leaves-trust-boundary caveat.
4. **Vector storage:** SQLite backend = float32 BLOB column + brute-force cosine in Dart (no vector extension; defensible far beyond memory-corpus scale; preserves ADR-045's "no in-database vector path on SQLite"). PostgreSQL backend = **`pgvector`** – delivering ADR-045's former Phase 3 now that the embedding source exists.
5. **Fusion:** Dart-side weighted RRF with frozen constants: `k=60`, keyword weight `0.25`, vector weight `0.75`, vector cutoff `0.20`, and at most 20 candidates from each constituent. Deterministic ties use keyword rank, vector rank, document ID and chunk ordinal. The constants are not configuration; set membership remains the cross-backend parity contract.
6. **Pipeline:** embed-on-write with graceful keyword-only degradation when the embedder is unavailable (loud log + visible unembedded counter, never a hard error); content-hash + embedder-fingerprint incremental re-embedding; heading-scored code-fence-safe chunker as the single chunking owner. Index stays derived + rebuildable (ADR-002).
7. **v1 exclusions (deliberate):** LLM query expansion and cross-encoder reranking. Retrieval is independent of generative agents; answer sufficiency belongs to the caller.
8. **QMD retirement:** `search.backend: qmd` emits a deprecation warning in 0.26; `QmdManager`, `QmdSearchBackend`, the factory branch and docs are removed one milestone later.

The schedule is exact: 0.24 keeps QMD fully supported and assigns it no canonical-memory authority; 0.26 Phase B emits
the deprecation warning; the following milestone removes the implementation.
9. **Packaging (owner-accepted 2026-07-25):** one default binary, all-in – no build flavor for the search native assets (jointly resolved with ADR-045 Open Questions #3 for `postgres`).

## Consequences

### Positive

- **Semantic + hybrid search becomes built-in** on both database backends. Native embedding generation needs no Node.js or outpost; retrieval creates no generative model turn.
- **Swedish/multilingual semantic recall independent of keyword stemming** – embeddings sidestep morphology; the spike fixture shows exactly the FTS5-`unicode61` failure categories going from 0.00 to 1.00.
- **Proven shipping model** – native libs ride the ADR-048 `dart build cli` bundle; one per-target build, inspectable `lib/` siblings.
- **Storage stays injected** – the search package composes the lexical/vector seams that 0.26 Phase A already builds.
- **pgvector unblocked** – ADR-045 Phase 3 ships instead of staying parked on the embedding-source question.

### Negative / accepted

- **llamadart is pre-1.0, single-maintainer** – pinned exactly at 0.8.22; the `EmbeddingProvider` seam keeps it
  swappable (the HTTP fallback is the standing escape hatch). Its worker startup has a dependency-owned 30-second
  handshake that observes error/exit and kills the worker on failure or timeout. Model-load and dispose requests remain
  separately bounded by DartClaw at the provider edge; final platform process probes decide acceptance.
- **Bundle supply chain is owned by release preparation** – the upstream-party hook does not authenticate its download, so release tooling verifies pinned archive size/SHA-256 before creating an operation-unique local hook stage. The hook cannot fall through to an unchecked download.
- **Linux runtime dependency** – bundles link OpenMP; release runners install and record `libgomp1` resolution.
- **~0.5 GB RAM while the embedder is resident**, and a one-time ~320 MB model download on enabling hybrid search.
- **Native payload increases release size** – the verified hook stage limits runtimes to `llama_cpp`, while both shipped binaries retain the same complete target library set.
- **Frozen fusion can underperform one constituent on a query** – the 0.26 constants are fixed and evaluated as one release contract rather than tuned after held-out results.

### Neutral

- SEB/MTEB(Scandinavian) tension remains recorded: the board favors qwen3-embedding-0.6B among small models, while the spike fixture favored embeddinggemma-300M. Local mode accepts only the verified EmbeddingGemma artifact; an explicit HTTP provider selects its own model and rebuilds derived vectors under a different fingerprint.
- FTS5 keyword search remains the zero-config default; hybrid activates only when a model is present.

## Amendment (0.26): retrieval and answer sufficiency

The answer-relevance amendment was superseded by the owner's explicit correction on 2026-09-09. Its premise
conflated missing answer evidence with an empty retrieval ranking. The bounded generative judge and its routing
configuration are removed; keyword/vector retrieval and weighted RRF remain the production mechanism.

Search returns useful authorized, current passages. A passage can provide useful context without independently
answering the question. The answering caller decides whether the evidence supports an answer. Reranking remains
out of scope until measured retrieval benefit justifies its latency and resource cost.

[The corrective contract](../bundle/docs/specs/0.26/search-contract-correction.md) defines prospective protocol 2
passage judgments, explicit bounded no-match probes and unchanged positive-ranking/isolation gates. Original
frozen assets and failed protocol-1 results remain historical evidence. Revised exposed regression results are
not unseen acceptance. PostgreSQL uses exact pgvector cosine over a filtered subset, not HNSW; that choice remains
proportional to the personal corpus and can be revisited with measured query-plan and corpus-growth evidence.

## Alternatives Considered

1. **Keep QMD as the semantic tier** – rejected: Node 22 + ~2 GB models + ~3 GB RAM for a pipeline whose own benchmark attributes the gain to the fusion stage DartClaw now builds natively; fast-moving upstream (v1→v2 broke the integration surface once already).
2. **Cloud embeddings as primary** – rejected for the default (local-first posture); accepted as documented opt-in via the same HTTP provider.
3. **`llama-server`/Ollama outpost as primary** – viable and lighter than QMD, but keeps an external-install step for a core capability; retained as the fallback/escape hatch instead.
4. **ONNX runtime in Dart** – still no maintained non-Flutter path (re-verified 2026-07); assembling one by hand is unowned engineering for no advantage over llamadart.
5. **Platform-native APIs** (Apple `NLContextualEmbedding`, Windows AI) – macOS-only in practice, 512-dim 2023-era quality, Windows API still private-preview; not a cross-platform primary.
6. **Static embeddings (model2vec)** – eliminates native libs but unverified quality and a Rust toolchain in CI; not now.
7. **sqlite-vec/sqlite_vector extension on SQLite** – unnecessary at memory-corpus scale; brute-force cosine behind `VectorIndex` is simpler and keeps the dependency count down.

## Implementation Notes

Explicit model acquisition follows at most three redirects manually because the pinned immutable Hugging Face source
redirects to a signed CDN URL. Each target must use HTTPS with a non-empty host and no userinfo or fragment, and passes
the existing network policy before I/O. Signed CDN query strings remain private to the request. Automatic redirects
remain disabled; missing/unsafe targets and exhausted redirects fail closed. Exact size and SHA-256 still authenticate
bytes before atomic publication. HTTP embedding requests continue to refuse every redirect.

- `FullTextIndex`, `VectorIndex` and `EmbeddingProvider` live in `dartclaw_kernel`; core owns canonical corpus mapping and both database implementations, `dartclaw_search` owns providers, synchronization and fusion, and runtime owns composition.
- PostgreSQL uses an administrator-installed extension in `public`; the runtime role performs read-only preflight and never installs it. SQLite vectors remain in separate `vectors.db` with direct Dart cosine scans.
- Release packaging stages exact native archives for five shipped targets and retains the same complete native-library set in both binaries. Four native embedding runner legs and the sealed retrieval evaluation remain final acceptance evidence, not claims made by this ADR.

## References

- Private research (canonical): `dartclaw-private/docs/research/dart-native-hybrid-search/research.md` (landscape + design + trade-offs), `spike-llamadart-embeddings.md` (spike record), `dartclaw-private/docs/specs/0.26/hybrid-search-prd-brief.md` (Phase B brief)
- Public frozen synthesis: [research appendix](research/050-native-hybrid-search.md)
- llamadart: https://pub.dev/packages/llamadart · https://github.com/leehack/llamadart
- Model: https://huggingface.co/ggml-org/embeddinggemma-300M-GGUF
- QMD (superseded integration): https://github.com/tobi/qmd
- RRF: Cormack, Clarke & Büttcher, SIGIR 2009 (DOI 10.1145/1571941.1572114)
