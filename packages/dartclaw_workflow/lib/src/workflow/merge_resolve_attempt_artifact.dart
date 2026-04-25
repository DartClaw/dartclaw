import 'dart:convert';

/// Structured artifact produced for each merge-resolution attempt (Decision 9, 9 v1 fields).
///
/// Persisted as JSON via `TaskRepository.insertArtifact` with
/// `name: merge_resolve_attempt_<n>.json` and `kind: ArtifactKind.data`.
final class MergeResolveAttemptArtifact {
  final int iterationIndex;
  final String storyId;
  final int attemptNumber;
  final String outcome;
  final List<String> conflictedFiles;
  final String resolutionSummary;
  final String? errorMessage;
  final String agentSessionId;
  final int tokensUsed;

  const MergeResolveAttemptArtifact({
    required this.iterationIndex,
    required this.storyId,
    required this.attemptNumber,
    required this.outcome,
    required this.conflictedFiles,
    required this.resolutionSummary,
    this.errorMessage,
    required this.agentSessionId,
    required this.tokensUsed,
  });

  Map<String, dynamic> toJson() => {
    'iteration_index': iterationIndex,
    'story_id': storyId,
    'attempt_number': attemptNumber,
    'outcome': outcome,
    'conflicted_files': conflictedFiles,
    'resolution_summary': resolutionSummary,
    'error_message': errorMessage,
    'agent_session_id': agentSessionId,
    'tokens_used': tokensUsed,
  };

  String toJsonString() => jsonEncode(toJson());

  factory MergeResolveAttemptArtifact.fromJson(Map<String, dynamic> json) =>
      MergeResolveAttemptArtifact(
        iterationIndex: json['iteration_index'] as int,
        storyId: json['story_id'] as String? ?? '',
        attemptNumber: json['attempt_number'] as int,
        outcome: json['outcome'] as String,
        conflictedFiles: (json['conflicted_files'] as List?)?.cast<String>() ?? const [],
        resolutionSummary: json['resolution_summary'] as String? ?? '',
        errorMessage: json['error_message'] as String?,
        agentSessionId: json['agent_session_id'] as String? ?? '',
        tokensUsed: json['tokens_used'] as int? ?? 0,
      );

  MergeResolveAttemptArtifact copyWith({
    String? outcome,
    String? errorMessage,
    bool clearErrorMessage = false,
  }) => MergeResolveAttemptArtifact(
    iterationIndex: iterationIndex,
    storyId: storyId,
    attemptNumber: attemptNumber,
    outcome: outcome ?? this.outcome,
    conflictedFiles: conflictedFiles,
    resolutionSummary: resolutionSummary,
    errorMessage: clearErrorMessage ? null : (errorMessage ?? this.errorMessage),
    agentSessionId: agentSessionId,
    tokensUsed: tokensUsed,
  );
}
