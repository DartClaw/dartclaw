/// Aggregate summary of turn traces for a task or query result.
class TurnTraceSummary {
  final int totalInputTokens;
  final int totalOutputTokens;
  final int totalCacheReadTokens;
  final int totalCacheWriteTokens;
  final int totalDurationMs;
  final int totalToolCalls;
  final int traceCount;

  const TurnTraceSummary({
    this.totalInputTokens = 0,
    this.totalOutputTokens = 0,
    this.totalCacheReadTokens = 0,
    this.totalCacheWriteTokens = 0,
    this.totalDurationMs = 0,
    this.totalToolCalls = 0,
    this.traceCount = 0,
  });

  int get totalTokens => totalInputTokens + totalOutputTokens;

  Map<String, dynamic> toJson() => {
    'totalInputTokens': totalInputTokens,
    'totalOutputTokens': totalOutputTokens,
    'totalCacheReadTokens': totalCacheReadTokens,
    'totalCacheWriteTokens': totalCacheWriteTokens,
    'totalTokens': totalTokens,
    'totalDurationMs': totalDurationMs,
    'totalToolCalls': totalToolCalls,
    'traceCount': traceCount,
  };

  factory TurnTraceSummary.fromJson(Map<String, dynamic> json) => TurnTraceSummary(
    totalInputTokens: json['totalInputTokens'] as int? ?? 0,
    totalOutputTokens: json['totalOutputTokens'] as int? ?? 0,
    totalCacheReadTokens: json['totalCacheReadTokens'] as int? ?? 0,
    totalCacheWriteTokens: json['totalCacheWriteTokens'] as int? ?? 0,
    totalDurationMs: json['totalDurationMs'] as int? ?? 0,
    totalToolCalls: json['totalToolCalls'] as int? ?? 0,
    traceCount: json['traceCount'] as int? ?? 0,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TurnTraceSummary &&
          other.totalInputTokens == totalInputTokens &&
          other.totalOutputTokens == totalOutputTokens &&
          other.totalCacheReadTokens == totalCacheReadTokens &&
          other.totalCacheWriteTokens == totalCacheWriteTokens &&
          other.totalDurationMs == totalDurationMs &&
          other.totalToolCalls == totalToolCalls &&
          other.traceCount == traceCount;

  @override
  int get hashCode => Object.hash(
    totalInputTokens,
    totalOutputTokens,
    totalCacheReadTokens,
    totalCacheWriteTokens,
    totalDurationMs,
    totalToolCalls,
    traceCount,
  );

  @override
  String toString() =>
      'TurnTraceSummary(traceCount: $traceCount, totalTokens: $totalTokens, '
      'totalDurationMs: $totalDurationMs)';
}
