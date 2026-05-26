import 'guard.dart';

/// Result of building a guard list from configuration.
///
/// Either [GuardBuildSuccess] (valid config, guards ready) or
/// [GuardBuildFailure] (invalid config, existing chain must be preserved).
sealed class GuardBuildResult {}

/// Guard list built successfully.
///
/// [warnings] contains informational messages (e.g., deduplicated rules).
final class GuardBuildSuccess extends GuardBuildResult {
  /// Guards produced from the configuration, ready for chain installation.
  final List<Guard> guards;

  /// Informational messages emitted during the build (e.g. deduplicated rules).
  final List<String> warnings;

  /// Creates a successful guard-build result.
  GuardBuildSuccess({required this.guards, this.warnings = const []});
}

/// Guard list build failed due to invalid config.
///
/// [errors] describes what went wrong (bad regex, conflicting rules).
/// The caller must preserve the existing guard chain.
final class GuardBuildFailure extends GuardBuildResult {
  /// Reasons the guard list could not be built (bad regex, conflicting rules, etc.).
  final List<String> errors;

  /// Creates a failed guard-build result.
  GuardBuildFailure({required this.errors});
}
