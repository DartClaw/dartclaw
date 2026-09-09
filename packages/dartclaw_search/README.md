# dartclaw_search

Hybrid retrieval composition, vector synchronization, and embedding providers for DartClaw.

The only workspace dependency is `dartclaw_kernel`; `crypto` supplies SHA-256 hashing and the pinned `llamadart` engine supplies local embeddings. Lexical and vector indexes are
injected, and canonical corpus mapping remains with the corpus owner. `HybridSearch` authenticates semantic hits against the current lexical corpus before
applying fixed weighted reciprocal-rank fusion. `VectorSynchronizer` reuses exact content/model matches and publishes
only vectors that still match the current source.
