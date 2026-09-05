# ADR-050: Native Hybrid Search (`dartclaw_search`) – In-Process Embeddings, Retiring the QMD Outpost

**Status:** Accepted – 2026-07-25. Scheduled as **0.26 Phase B** (brief: private `dartclaw-private/docs/specs/0.26/hybrid-search-prd-brief.md`); implementation follows Phase A. Validation spike passed 2026-07-25. Supersedes [ADR-004](004-vector-search-approach.md); QMD remains the shipped opt-in path until Phase B GA (deprecate-then-remove).
**Deciders:** DartClaw team

**Related:** [ADR-004](004-vector-search-approach.md) (superseded – QMD outpost), [ADR-045](045-pluggable-database-backend.md) (`FullTextIndex`/`VectorIndex` seams; this ADR delivers its former Phase 3), [ADR-048](048-release-builds-dart-build-bundled-sqlite.md) (bundled-native-library shipping precedent), [ADR-034](034-enforced-package-dependency-direction.md) (dependency direction), [ADR-002](002-file-based-storage.md) (search index is derived/rebuildable)

---

## Context

ADR-004 (2026-02) chose the QMD outpost for semantic memory search because no in-process embedding path existed for pure-Dart AOT – every ONNX/llama.cpp binding was Flutter-bound. That premise is gone as of mid-2026: **`llamadart`** (pub.dev, pure Dart, no Flutter) binds llama.cpp via the now-stable Dart build-hooks mechanism; its hook downloads prebuilt llama.cpp bundles and declares them as `DynamicLoadingBundled` code assets, so `dart build cli` ships them in `lib/` beside the AOT binary – exactly how `libsqlite3` ships today (ADR-048).

Meanwhile ADR-045's 0.26 Phase A creates the retrieval seams (`FullTextIndex`; `tsvector` language-aware keyword search on PostgreSQL) and deferred `pgvector` (former Phase 3) solely on the missing embedding source. The remaining gap for built-in hybrid search is: embedding generation, ~50 lines of RRF fusion, and vector storage per backend.

The full landscape analysis (embedding sources, QMD v2.6.3 internals, hybrid-search architecture survey) is in the private research `dartclaw-private/docs/research/dart-native-hybrid-search/research.md`; a frozen public synthesis is in the [research appendix](research/050-native-hybrid-search.md).

**Validation spike (2026-07-25, passed; full record in the private research dir):**
- macOS arm64 `dart build cli`: 6 MB binary + 10 MB `libllamadart.dylib`, ADR-048 shape; max RSS ≈ 477 MB with embeddinggemma-300M resident; ~7 ms/doc embed.
- Linux (Docker `dart:stable`): works; needs `libgomp1` at runtime; llamadart hangs (no surfaced error) when the native lib fails to load – wrapper needs an init timeout.
- Parity: cosine 1.000000 vs llama.cpp's own `llama-server` on the same GGUF.
- Swedish/English retrieval fixture: unstemmed keyword-only 0.38 hit@1 (0.00 on Swedish inflection/compound/vocabulary-mismatch – the motivating gap); embeddinggemma-300M vector 1.00/1.00 incl. cross-lingual; hybrid RRF 0.94. Qwen3-Embedding-0.6B head-to-head: 0.94, missed the hardest Swedish semantic query, weaker cross-lingual, 2× size.

## Decision

**Build `dartclaw_search`: built-in hybrid memory search (keyword + vector + weighted RRF) composing the ADR-045 seams, with embedding generation behind an `EmbeddingProvider` seam. Retire QMD via a deprecation window.**

1. **New package `dartclaw_search`** (~1–1.5k LOC): depends on contract packages only (ADR-034 allowlist edges added with rationale); concrete `FullTextIndex`/`VectorIndex` implementations are injected. The package isolates the llamadart native-asset dependency from the core graph.
2. **Primary embedding source: in-process llamadart** (pinned exact version), default model **embeddinggemma-300M Q8_0** (768-dim, multilingual; QMD's own default – known quality baseline; fixture-validated for Swedish). Model is a one-time pinned-URL + checksum download, honoring the network-gating posture.
3. **Fallback + escape hatch: OpenAI-compatible HTTP provider** (~100 LOC; base URL + optional API key) covering local outposts (llama.cpp `llama-server`, Ollama, LM Studio) and – as **documented, explicit opt-in** (owner-accepted 2026-07-25) – cloud endpoints (Voyage/OpenAI/Gemini). Default remains local; user docs carry the data-leaves-trust-boundary caveat.
4. **Vector storage:** SQLite backend = float32 BLOB column + brute-force cosine in Dart (no vector extension; defensible far beyond memory-corpus scale; preserves ADR-045's "no in-database vector path on SQLite"). PostgreSQL backend = **`pgvector`** – delivering ADR-045's former Phase 3 now that the embedding source exists.
5. **Fusion:** Dart-side weighted RRF (k=60, identical constants on both backends; set-membership remains the only cross-backend parity contract). In-database PG fusion recorded as a later optimization.
6. **Pipeline:** embed-on-write with graceful keyword-only degradation when the embedder is unavailable (loud log + visible unembedded counter, never a hard error); content-hash + embedder-fingerprint incremental re-embedding; heading-scored code-fence-safe chunker as the single chunking owner. Index stays derived + rebuildable (ADR-002).
7. **v1 exclusions (deliberate):** LLM query expansion and cross-encoder reranking – QMD's own benchmark shows plain hybrid fusion carries the measurable gain on keyword-friendly corpora; the excluded stages cost two resident GGUF models. The typed sub-query fusion seam keeps the door open; the future path is on-demand reranking via DartClaw's existing LLM harnesses.
8. **QMD retirement:** `search.backend: qmd` gets a deprecation warning at Phase B GA; `QmdManager`/`QmdSearchBackend`/factory branch and docs are removed one milestone later.

The schedule is exact: 0.24 keeps QMD fully supported and assigns it no canonical-memory authority; 0.26 Phase B emits
the deprecation warning; the following milestone removes the implementation.
9. **Packaging (owner-accepted 2026-07-25):** one default binary, all-in – no build flavor for the search native assets (jointly resolved with ADR-045 Open Questions #3 for `postgres`).

## Consequences

### Positive

- **Semantic + hybrid search becomes built-in** on both database backends – no Node.js, no npm, no external process in the recommended path (minimal-attack-surface philosophy).
- **Swedish/multilingual semantic recall independent of keyword stemming** – embeddings sidestep morphology; the spike fixture shows exactly the FTS5-`unicode61` failure categories going from 0.00 to 1.00.
- **Proven shipping model** – native libs ride the ADR-048 `dart build cli` bundle; one per-target build, inspectable `lib/` siblings.
- **Small and auditable** – the whole package is ~1–1.5k LOC composing seams that 0.26 Phase A already builds.
- **pgvector unblocked** – ADR-045 Phase 3 ships instead of staying parked on the embedding-source question.

### Negative / accepted

- **llamadart is pre-1.0, single-maintainer** – pinned exact; the `EmbeddingProvider` seam keeps it swappable (the HTTP fallback is the standing escape hatch). Known bug: engine hangs instead of erroring on native-lib load failure – wrapper wraps init in a timeout; report upstream.
- **Bundle supply chain needs hardening by us** – the hook tag-pins but does **not** sha256-verify the llama.cpp archives; release builds mirror the bundles or use the local-path user-define. Build-time network access is required unless mirrored.
- **Linux runtime dependency** – bundles link OpenMP; `libgomp1` must be documented/bundled in release packaging.
- **~0.5 GB RAM while the embedder is resident**, and a one-time ~320 MB model download on enabling hybrid search.
- **Default Linux bundle needs trimming** – without the runtimes user-define it ships an unused LiteRT-LM/WebGPU stack (194 MB → 98 MB with `llamadart_native_runtimes: [llama_cpp]`; Vulkan trim available).
- **Fusion quality tuning is real work** – the spike showed one query where noisy keyword rankings dragged RRF below pure vector; weights/thresholds are spec-time scope.

### Neutral

- SEB/MTEB(Scandinavian) tension recorded: the board favors qwen3-embedding-0.6B among small models, our fixture favors embeddinggemma-300M; default stays embeddinggemma, re-evaluated with a larger fixture at spec time. Model choice is config, and the index is rebuildable – switching later is cheap.
- FTS5 keyword search remains the zero-config default; hybrid activates only when a model is present.

## Alternatives Considered

1. **Keep QMD as the semantic tier** – rejected: Node 22 + ~2 GB models + ~3 GB RAM for a pipeline whose own benchmark attributes the gain to the fusion stage DartClaw now builds natively; fast-moving upstream (v1→v2 broke the integration surface once already).
2. **Cloud embeddings as primary** – rejected for the default (local-first posture); accepted as documented opt-in via the same HTTP provider.
3. **`llama-server`/Ollama outpost as primary** – viable and lighter than QMD, but keeps an external-install step for a core capability; retained as the fallback/escape hatch instead.
4. **ONNX runtime in Dart** – still no maintained non-Flutter path (re-verified 2026-07); assembling one by hand is unowned engineering for no advantage over llamadart.
5. **Platform-native APIs** (Apple `NLContextualEmbedding`, Windows AI) – macOS-only in practice, 512-dim 2023-era quality, Windows API still private-preview; not a cross-platform primary.
6. **Static embeddings (model2vec)** – eliminates native libs but unverified quality and a Rust toolchain in CI; not now.
7. **sqlite-vec/sqlite_vector extension on SQLite** – unnecessary at memory-corpus scale; brute-force cosine behind `VectorIndex` is simpler and keeps the dependency count down.

## Implementation Notes

- Binding spec-time items: `FullTextIndex`/`VectorIndex` contract placement decided during Phase A **with this package in view** (it must reach the contracts without depending on `dartclaw_storage`); engine-init timeout; RRF weight tuning + larger Swedish eval fixture; parity fixtures stay set-membership-only across backends; `CREATE EXTENSION IF NOT EXISTS vector` handling per ADR-045 FR2's extension rule.
- Release packaging: mirror/pin llamadart native bundles; add `libgomp1` to Linux packaging docs; apply the runtimes trim user-define.
- Remaining platform legs (Linux x64, Windows) ride the existing CI release matrix (ADR-048 native runners).

## References

- Private research (canonical): `dartclaw-private/docs/research/dart-native-hybrid-search/research.md` (landscape + design + trade-offs), `spike-llamadart-embeddings.md` (spike record), `dartclaw-private/docs/specs/0.26/hybrid-search-prd-brief.md` (Phase B brief)
- Public frozen synthesis: [research appendix](research/050-native-hybrid-search.md)
- llamadart: https://pub.dev/packages/llamadart · https://github.com/leehack/llamadart
- Model: https://huggingface.co/ggml-org/embeddinggemma-300M-GGUF
- QMD (superseded integration): https://github.com/tobi/qmd
- RRF: Cormack, Clarke & Büttcher, SIGIR 2009 (DOI 10.1145/1571941.1572114)
