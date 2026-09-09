/// Hybrid retrieval composition and embedding providers for DartClaw.
///
/// Concrete lexical and vector indexes are injected through contracts owned by
/// `dartclaw_kernel`; this package owns no authoritative corpus or database.
library;

export 'src/default_embedding_model_acquirer.dart'
    show DefaultEmbeddingModel, DefaultEmbeddingModelAcquirer, ModelAcquisitionResult, ModelAcquisitionStatus;
export 'src/embedding_providers.dart' show HttpEmbeddingProvider, NativeEmbeddingProvider, NetworkAccessCheck;
export 'src/hybrid_search.dart' show HybridSearch, VectorSynchronizationResult, VectorSynchronizer;
export 'src/hybrid_search_backend.dart' show HybridSearchBackend;
export 'src/search_relevance_filter.dart' show SearchRelevanceFilter, SearchRelevanceTurn;

export 'package:dartclaw_kernel/dartclaw_kernel.dart'
    show
        EmbeddingProvider,
        FullTextIndex,
        MemorySearchDegradation,
        MemorySearchOutcome,
        MemorySearchResult,
        SearchBackend,
        SearchDiagnostics,
        SearchDiagnosticsSink,
        SearchRankEvidence,
        SearchDocument,
        SearchResult,
        SearchResultLayer,
        VectorIdentity,
        VectorIndex,
        VectorMatch,
        VectorRecord;
