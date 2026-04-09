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
  final List<Guard> guards;
  final List<String> warnings;

  GuardBuildSuccess({required this.guards, this.warnings = const []});
}

/// Guard list build failed due to invalid config.
///
/// [errors] describes what went wrong (bad regex, conflicting rules).
/// The caller must preserve the existing guard chain.
final class GuardBuildFailure extends GuardBuildResult {
  final List<String> errors;

  GuardBuildFailure({required this.errors});
}
