/// Configuration for the usage tracking subsystem.
class UsageConfig {
  final int? budgetWarningTokens;
  final int maxFileSizeBytes;

  const UsageConfig({
    this.budgetWarningTokens,
    this.maxFileSizeBytes = 10 * 1024 * 1024,
  });

  /// Default configuration.
  const UsageConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UsageConfig &&
          budgetWarningTokens == other.budgetWarningTokens &&
          maxFileSizeBytes == other.maxFileSizeBytes;

  @override
  int get hashCode => Object.hash(budgetWarningTokens, maxFileSizeBytes);
}
