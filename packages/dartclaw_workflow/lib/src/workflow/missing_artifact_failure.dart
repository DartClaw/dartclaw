/// Thrown when an agent claims a produced artifact path that is absent.
final class MissingArtifactFailure implements Exception {
  /// Paths claimed by the agent or workflow output.
  final List<String> claimedPaths;

  /// Claimed paths that were not found in the authoritative artifact source.
  final List<String> missingPaths;

  /// Task worktree used as the filesystem source of truth.
  final String worktreePath;

  /// Output field whose artifact check failed.
  final String fieldName;

  /// Stable human-readable reason for the failure.
  final String reason;

  const MissingArtifactFailure({
    required this.claimedPaths,
    required this.missingPaths,
    required this.worktreePath,
    required this.fieldName,
    required this.reason,
  });

  @override
  String toString() {
    return 'MissingArtifactFailure(field: $fieldName, missing: $missingPaths, worktree: $worktreePath, reason: $reason)';
  }
}
