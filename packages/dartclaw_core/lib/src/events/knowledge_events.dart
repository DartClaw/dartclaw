part of 'dartclaw_event.dart';

/// Fired when `context_research` completes a synthesis attempt.
final class ContextResearchMetricsEvent extends DartclawEvent {
  /// Approximate tokens read by synthesis.
  final int inputTokens;

  /// Approximate tokens returned after degradation.
  final int outputTokens;

  /// Number of source candidates retrieved before synthesis.
  final int sourcesCount;

  /// Whether output was truncated to preserve the token budget.
  final bool truncated;

  /// True when the call bypassed any synthesized-packet cache.
  final bool cacheBypass;

  @override
  final DateTime timestamp;

  /// Creates a context research metrics event.
  ContextResearchMetricsEvent({
    required this.inputTokens,
    required this.outputTokens,
    required this.sourcesCount,
    required this.truncated,
    required this.cacheBypass,
    required this.timestamp,
  });

  @override
  String toString() =>
      'ContextResearchMetricsEvent(input: $inputTokens, output: $outputTokens, sources: $sourcesCount, '
      'truncated: $truncated, cacheBypass: $cacheBypass)';
}
