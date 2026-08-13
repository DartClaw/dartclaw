/// Configuration for conversation history replay on cold-process turns.
class HistoryConfig {
  /// Per-message character truncation limit.
  final int maxMessageChars;

  /// Total character budget for the replay history block.
  final int maxTotalChars;

  /// const HistoryConfig({this.maxMessageChars = 4000, this.maxTo.
  const new({this.maxMessageChars = 4000, this.maxTotalChars = 50000});

  /// Creates a [HistoryConfig.defaults] value.
  const new defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HistoryConfig && maxMessageChars == other.maxMessageChars && maxTotalChars == other.maxTotalChars;

  @override
  int get hashCode => Object.hash(maxMessageChars, maxTotalChars);
}
