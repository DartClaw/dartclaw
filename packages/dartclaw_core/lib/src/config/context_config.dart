/// Configuration for the context subsystem.
class ContextConfig {
  final int reserveTokens;
  final int maxResultBytes;
  final int warningThreshold;
  final int explorationSummaryThreshold;
  final String? compactInstructions;

  /// Controls whether identifier preservation instructions are appended to
  /// compact instructions.
  ///
  /// - `'strict'` (default): appends standard identifier preservation text.
  /// - `'off'`: no identifier preservation instructions appended.
  /// - `'custom'`: appends [identifierInstructions] (treated as `'off'` when null).
  final String identifierPreservation;

  /// Custom identifier preservation text used when [identifierPreservation] is `'custom'`.
  final String? identifierInstructions;

  const ContextConfig({
    this.reserveTokens = 20000,
    this.maxResultBytes = 50 * 1024,
    this.warningThreshold = 80,
    this.explorationSummaryThreshold = 25000,
    this.compactInstructions,
    this.identifierPreservation = 'strict',
    this.identifierInstructions,
  });

  /// Default configuration.
  const ContextConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ContextConfig &&
          reserveTokens == other.reserveTokens &&
          maxResultBytes == other.maxResultBytes &&
          warningThreshold == other.warningThreshold &&
          explorationSummaryThreshold == other.explorationSummaryThreshold &&
          compactInstructions == other.compactInstructions &&
          identifierPreservation == other.identifierPreservation &&
          identifierInstructions == other.identifierInstructions;

  @override
  int get hashCode => Object.hash(
    reserveTokens,
    maxResultBytes,
    warningThreshold,
    explorationSummaryThreshold,
    compactInstructions,
    identifierPreservation,
    identifierInstructions,
  );
}
