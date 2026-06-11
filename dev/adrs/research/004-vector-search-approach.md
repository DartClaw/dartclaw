# ADR-004 Research Appendix: Vector Search Approach for Hybrid Memory

> Frozen synthesis supporting [ADR-004](../004-vector-search-approach.md). Point-in-time as of 2026-02-25 (accepted: 2026-02-27); not maintained as the design evolves.

## Question
Which vector search and embedding architecture should DartClaw use for early memory retrieval?

## Options considered
- SQLite FTS/BM25 first — simple local search with no embedding runtime.
- Remote embeddings plus vector index — stronger semantic recall, but adds provider and cost dependency.
- Local embeddings — desirable for privacy, but Dart-native ONNX was not viable at decision time.
- Hybrid lexical plus semantic retrieval — best long-term shape, staged behind simpler initial storage.

## Trade-off summary
The decision prioritized local operability, minimal dependencies, and predictable storage over early semantic sophistication.

## Deciding evidence
Dart ONNX packages were Flutter-oriented at the time; later local options such as Ollama HTTP and llama.cpp server improved the outlook but did not change the initial low-dependency path.

## Sources (private)
- `docs/research/vector-search-approach`
- `docs/research/vector-search-approach/local-embeddings-dart.md`
