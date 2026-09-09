/// Hybrid retrieval composition and embedding providers for DartClaw.
///
/// Concrete lexical and vector indexes are injected through contracts owned by
/// `dartclaw_kernel`; this package owns no authoritative corpus or database.
library;

export 'package:dartclaw_kernel/dartclaw_kernel.dart'
    show
        EmbeddingProvider,
        SearchDiagnostics,
        SearchDiagnosticsSink,
        SearchRankEvidence,
        VectorIdentity,
        VectorIndex,
        VectorMatch,
        VectorRecord;
