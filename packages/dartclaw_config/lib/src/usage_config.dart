/// Configuration for the usage tracking subsystem.
class UsageConfig {
  /// budgetWarningTokens.
  final int? budgetWarningTokens;

  /// maxFileSizeBytes.
  final int maxFileSizeBytes;

  /// const UsageConfig({this.budgetWarningTokens, this.maxFileSiz.
  const new({this.budgetWarningTokens, this.maxFileSizeBytes = 10 * 1024 * 1024});

  /// Default configuration.
  const new defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UsageConfig &&
          budgetWarningTokens == other.budgetWarningTokens &&
          maxFileSizeBytes == other.maxFileSizeBytes;

  @override
  int get hashCode => Object.hash(budgetWarningTokens, maxFileSizeBytes);
}
