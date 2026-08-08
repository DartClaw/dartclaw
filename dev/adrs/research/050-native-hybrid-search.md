# ADR-050 Research Appendix: Native Hybrid Search

> Frozen synthesis supporting [ADR-050](../050-native-hybrid-search.md). Point-in-time as of 2026-07-25; not maintained as the design evolves.

## Question

What embedding source lets DartClaw provide built-in hybrid (keyword + vector) memory search from a pure-Dart AOT binary, replacing the QMD outpost?

## Options considered

- In-process llama.cpp via `llamadart` (build-hook-bundled native libs, GGUF models) – selected.
- OpenAI-compatible HTTP provider – local outposts (`llama-server`, Ollama) and opt-in cloud (Voyage/OpenAI/Gemini); selected as fallback/escape hatch.
- Keep QMD outpost – rejected (Node 22 + ~2 GB models; its own benchmark attributes the gain to hybrid fusion, which DartClaw now builds natively).
- ONNX in Dart – still Flutter-only mid-2026; rejected.
- Platform-native APIs (Apple NaturalLanguage, Windows AI) – macOS-only in practice, dated quality; rejected.
- Static embeddings (model2vec) – unverified quality, Rust toolchain cost; deferred.

## Trade-off summary

The decision preserves local-first defaults and the bundled-native-library shipping model (ADR-048) while removing the Node.js/npm dependency from the recommended semantic-search path. Cloud stays an explicit, documented opt-in.

## Deciding evidence

A 2026-07-25 validation spike: `dart build cli` produces the sqlite3-style bundle with llamadart's libs on macOS and Linux; embedding output matches llama.cpp's own server at cosine 1.000000; on a Swedish/English retrieval fixture, unstemmed keyword search scored 0.00 on all Swedish morphology/semantics categories while embeddinggemma-300M vector search scored 1.00 – with hybrid RRF at 0.94. Supply-chain review found tag-pinned but not checksum-verified llama.cpp bundles (mirroring required) and a `libgomp1` runtime dependency on Linux.

## Sources (private)

- `dartclaw-private/docs/research/dart-native-hybrid-search/research.md`
- `dartclaw-private/docs/research/dart-native-hybrid-search/spike-llamadart-embeddings.md`
