/// Configuration for conversation history replay on cold-process turns.
class HistoryConfig {
  /// Per-message character truncation limit.
  final int maxMessageChars;

  /// Total character budget for the replay history block.
  final int maxTotalChars;

  const HistoryConfig({
    this.maxMessageChars = 4000,
    this.maxTotalChars = 50000,
  });

  const HistoryConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HistoryConfig &&
          maxMessageChars == other.maxMessageChars &&
          maxTotalChars == other.maxTotalChars;

  @override
  int get hashCode => Object.hash(maxMessageChars, maxTotalChars);
}
