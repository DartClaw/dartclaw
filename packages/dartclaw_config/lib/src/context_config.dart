import 'identifier_preservation_mode.dart';

/// Configuration for the context subsystem.
class ContextConfig {
  /// reserveTokens.
  final int reserveTokens;

  /// maxResultBytes.
  final int maxResultBytes;

  /// warningThreshold.
  final int warningThreshold;

  /// explorationSummaryThreshold.
  final int explorationSummaryThreshold;

  /// compactInstructions.
  final String? compactInstructions;

  /// Controls whether identifier preservation instructions are appended to
  /// compact instructions.
  ///
  /// - [IdentifierPreservationMode.strict] (default): appends standard text.
  /// - [IdentifierPreservationMode.off]: no identifier preservation text.
  /// - [IdentifierPreservationMode.custom]: appends [identifierInstructions].
  final IdentifierPreservationMode identifierPreservation;

  /// Custom identifier preservation text used with [IdentifierPreservationMode.custom].
  final String? identifierInstructions;

  /// Creates a [ContextConfig] value.
  const ContextConfig({
    this.reserveTokens = 20000,
    this.maxResultBytes = 50 * 1024,
    this.warningThreshold = 80,
    this.explorationSummaryThreshold = 25000,
    this.compactInstructions,
    this.identifierPreservation = IdentifierPreservationMode.strict,
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
