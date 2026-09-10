# Package Rules – `dartclaw_search`

**Role**: Hybrid retrieval composition, vector synchronization, and native/HTTP embedding providers. The public barrel is
`lib/dartclaw_search.dart`.

## Boundaries

- `dartclaw_kernel` is the only DartClaw package dependency. Search and vector contracts come from the kernel; concrete
  storage, corpus ownership, HTTP routes, configuration parsing, and runtime wiring stay in their owning packages.
- `HybridSearch` combines injected lexical and vector indexes. It authenticates semantic matches against the current
  lexical corpus before ranking and authenticates returned source content again before release.
- `VectorSynchronizer` treats vector data as a derived projection. It publishes vectors only while the current lexical
  source still matches and keeps synchronization counts distinct from query diagnostics.
- Corpus-specific mapping stays with the corpus owner. This package returns `SearchResult` values and does not interpret
  memory or conversation metadata.

## Providers

- Native embeddings use the pinned `llamadart` runtime and the EmbeddingGemma query/document input convention. Model
  acquisition is explicit and verifies downloaded bytes before publication.
- HTTP embeddings use the OpenAI-compatible raw-input shape. Endpoint and credential-transport policy comes from the
  exported kernel predicates; the provider owns URI normalization, non-empty credential checks, request/response bounds,
  result validation, and redaction.
- Native initialization is lazy and shared. An ordinary load failure may recover on a later call, a load timeout poisons
  that provider instance, and disposal is terminal; HTTP provider disposal is also terminal.
- Providers fail explicitly. Hybrid retrieval converts provider and vector-index failures into structured degradation
  evidence while preserving valid lexical results.

## Testing

- Tests are flat under `test/`; shared search fakes live in `test/search_test_support.dart`.
- Provider tests cover timeouts, bounded responses, malformed payloads, redaction, and lifecycle. Hybrid tests cover
  owner isolation, source authentication, ranking evidence, and lexical fallback.
- Run `dart test --reporter=failures-only packages/dartclaw_search` for package changes.

## Key files

- `lib/src/hybrid_search.dart` – authenticated hybrid composition and reciprocal-rank fusion.
- `lib/src/current_corpus_inventory.dart` – current lexical/vector corpus comparison.
- `lib/src/vector_synchronizer.dart` – derived vector reconciliation.
- `lib/src/embedding_providers.dart` and its part files – shared provider validation and concrete providers.
- `lib/src/default_embedding_model_acquirer.dart` – explicit native model acquisition and verified publication.
