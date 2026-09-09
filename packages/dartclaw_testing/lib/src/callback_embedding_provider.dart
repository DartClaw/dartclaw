import 'package:dartclaw_kernel/dartclaw_kernel.dart';

/// Embedding provider test double with optional behavior callbacks.
final class CallbackEmbeddingProvider implements EmbeddingProvider {
  /// Creates a provider whose default vectors are deterministic and two-dimensional.
  const new({
    this.modelFingerprint = 'test-model',
    Future<List<double>> Function(String)? embedQuery,
    Future<List<List<double>>> Function(List<String>)? embedDocuments,
    Future<void> Function()? dispose,
  }) : _embedQuery = embedQuery,
       _embedDocuments = embedDocuments,
       _dispose = dispose;

  @override
  final String modelFingerprint;

  final Future<List<double>> Function(String)? _embedQuery;
  final Future<List<List<double>>> Function(List<String>)? _embedDocuments;
  final Future<void> Function()? _dispose;

  @override
  Future<List<double>> embedQuery(String query) async => await _embedQuery?.call(query) ?? const [1, 0];

  @override
  Future<List<List<double>>> embedDocuments(List<String> documents) async =>
      await _embedDocuments?.call(documents) ??
      [
        for (final _ in documents) const [1, 0],
      ];

  @override
  Future<void> dispose() async => await _dispose?.call();
}
