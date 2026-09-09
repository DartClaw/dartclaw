# Validation Spike Record – llamadart In-Process Embeddings

**Date**: 2026-07-25 · **Verdict**: PASSED – in-process-primary design validated
**Question**: Can llamadart produce correct embeddinggemma-300M embeddings inside a pure-Dart AOT `dart build cli` binary, shipped like bundled sqlite3, with credible Swedish/English retrieval quality?
**Gates**: [hybrid-search-prd-brief.md](../../specs/0.25/hybrid-search-prd-brief.md) §Gates · seeds ADR-050 (public repo)
**Code**: throwaway per spike discipline – retained locally outside version control; everything needed to reproduce is recorded here.

## Environment

Dart 3.12.1 stable, macOS arm64 (Apple Silicon); Docker 29.4.2 (`dart:stable` image, linux/arm64); `llamadart: 0.8.17` (pinned exact); model `ggml-org/embeddinggemma-300M-GGUF` `embeddinggemma-300M-Q8_0.gguf` (318 MB, 768-dim); head-to-head model `Qwen/Qwen3-Embedding-0.6B-GGUF` Q8_0 (610 MB); reference tool `llama.cpp` release b10107 prebuilt macOS arm64 (`llama-server --embeddings`).

## Setup (reproduction)

Minimal Dart CLI project: `pubspec.yaml` with `llamadart: 0.8.17` and (for the Linux trim experiment) `hooks.user_defines.llamadart.llamadart_native_runtimes: [llama_cpp]`. Driver (~250 LOC): `LlamaEngine(LlamaBackend())`, `loadModel(path, modelParams: ModelParams(contextSize: 2048, numberOfThreads: 4))`, `embedBatch(texts)` (L2-normalized mean-pooled output, default). Prompt formats: embeddinggemma docs `title: none | text: {t}` / queries `task: search result | query: {q}`; qwen3 queries `Instruct: Given a web search query, retrieve relevant passages that answer the query\nQuery: {q}`, docs raw. Commands: `dart run bin/spike.dart parity|bench|compare`, `dart build cli -o build/spike-aot`.

## Results

### 1. Packaging / AOT

| Leg | Result | Numbers |
|---|---|---|
| macOS arm64 `dart build cli` | **PASS** | Bundle: `bin/spike` 6 MB + `lib/libllamadart.dylib` 10 MB (single dylib; ADR-048 sibling-lib shape). Max RSS 500,678,656 B ≈ 477 MB with model resident. Model load 7.4 s (Metal warmup); 24 docs embedded in 168 ms (~7 ms/doc); 16 queries in 90 ms |
| Linux arm64 (Docker `dart:stable`) | **PASS** (2 findings) | Build works; hook fetched linux bundles. Model load 166 ms; 24 docs in 734 ms (~31 ms/doc CPU); results equivalent (one borderline rank flip vs Metal: vector hit@1 0.94, hit@3 1.00) |
| Linux x64 / Windows | pending | CI-time; no blocker expected |

**Linux findings**: (a) the llama.cpp Linux bundle links OpenMP – `libgomp1` must be present (slim `dart:stable` lacks it); document/bundle in release packaging. (b) **llamadart hangs indefinitely** (worker-isolate exception never surfaces; engine call never completes) when the native lib fails to load – manifested as silent >10-min stalls until diagnosed via an inner `timeout`. Report upstream; DartClaw's wrapper needs an init timeout regardless.

### 2. Correctness / parity

Cosine(llamadart, `llama-server /v1/embeddings`) on the same GGUF, 4 texts (en+sv, raw strings): **1.000000, 1.000000, 1.000000, 1.000000**. Structural sanity (embeddinggemma, doc-prefixed): paraphrase-EN 0.9203, cross-lingual sv/en 0.7954, unrelated 0.1774.

### 3. Retrieval fixture (24 docs, 16 queries, sv+en, memory-note style)

hit@1 / hit@3; keyword scorer = unstemmed exact-token match (mimics FTS5 `unicode61` + DartClaw's quoted-token sanitizer); hybrid = RRF k=60 over keyword+vector rank lists.

| Category (n) | keyword | embeddinggemma vector | gemma hybrid | qwen3 vector | qwen3 hybrid |
|---|---|---|---|---|---|
| **OVERALL (16)** | 0.38 / 0.38 | **1.00 / 1.00** | 0.94 / 0.94 | 0.94 / 0.94 | 0.88 / 0.88 |
| sv-inflection (2) | 0.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| sv-compound (1) | 0.00 | 1.00 | 1.00 | 1.00 | 1.00 |
| sv-vocab-mismatch (1) | 0.00 | 1.00 | 1.00 | **0.00** | 0.00 |
| en-vocab-mismatch (2) | 0.50 | 1.00 | 1.00 | 1.00 | 1.00 |
| cross-lingual (6) | 0.17 | 1.00 | 0.83 | 1.00 | 0.83 |
| keyword-controls (4) | 1.00 | 1.00 | 1.00 | 1.00 | 1.00 |

Reading: keyword-only scores 0.00 on every Swedish morphology/semantics category – the motivating gap. embeddinggemma solves all of it; qwen3 missed the hardest Swedish vocabulary-mismatch query (`löpträning` → doc about morning runs) and has weaker cross-lingual alignment (sanity cosine 0.6194 vs 0.7954). One hybrid miss (both models): a query whose noisy keyword matches dragged RRF below pure vector – fusion weight tuning is spec-time work.

### 4. SEB / MTEB(Scandinavian, v1) board (pulled live 2026-07-25)

qwen3-embedding-0.6B: rank #21/236, retrieval-subset mean 61.85 (fully evaluated). Base embeddinggemma-300m: only partially evaluated (~9/28 tasks; rank not comparable). Community finetune EmbeddingGemma-Scandi-300m: #51, retrieval 54.52. Cloud reference points: gemini-embedding-001 retrieval 77.20, text-embedding-3-large 73.38, voyage-3.5 74.13. Per-language columns are labeled "simulated" by MTEB – treated as approximate.

**Tension recorded**: the board favors qwen3; our fixture favors embeddinggemma (perfect score, better cross-lingual, half the size, QMD continuity). Fixture is small (16 queries) – **default stays embeddinggemma-300M**, re-evaluate with a larger fixture at spec time.

### 5. Supply chain

- Bundles: GitHub releases of `leehack/llamadart-native`, tag hardcoded in the package's `hook/build.dart` (0.8.17 → `b10075`); cached under `.dart_tool/`.
- Working overrides (`pubspec.yaml` → `hooks.user_defines.llamadart`): `llamadart_native_tag`, `llamadart_native_repository`, `llamadart_native_path` (local/mirror), `llamadart_native_runtimes`. Restricting to `[llama_cpp]` trimmed the Linux `lib/` from 194 MB (default also ships the LiteRT-LM/WebGPU stack) to 98 MB; a further backend trim of the 40 MB Vulkan lib exists (`llamadart_native_backends`) – untested.
- **The llama.cpp archives are not sha256-verified by the hook** (only the LiteRT archives carry pins). Release builds must mirror the bundles or use the local-path override; tag-pinning alone trusts GitHub release immutability.
- macOS default bundle is a single 10 MB `libllamadart.dylib` – no trim needed.

## Caveats

Fixture is directional, not statistical (24 docs / 16 queries). Hybrid RRF weights untuned. Linux x64 and Windows unexercised. macOS numbers are with the default (Metal) backend; the qwen3 run was JIT-only. `llama-server` as parity reference shares llama.cpp lineage with llamadart – it validates the binding/pooling/normalization chain, not the model itself (the model's quality is what the fixture + SEB measure).
