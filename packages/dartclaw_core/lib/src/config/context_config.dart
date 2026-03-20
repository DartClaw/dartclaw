/// Configuration for the context subsystem.
class ContextConfig {
  final int reserveTokens;
  final int maxResultBytes;
  final int warningThreshold;
  final int explorationSummaryThreshold;
  final String? compactInstructions;

  const ContextConfig({
    this.reserveTokens = 20000,
    this.maxResultBytes = 50 * 1024,
    this.warningThreshold = 80,
    this.explorationSummaryThreshold = 25000,
    this.compactInstructions,
  });

  /// Default configuration.
  const ContextConfig.defaults() : this();
}
