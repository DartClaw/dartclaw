import 'workflow_output_contract.dart';
import 'workflow_turn_adapter.dart' show WorkflowGitPromotionHeld;

/// The Git operation waiting for a person to review its candidate.
class WorkflowExecutionSurfaceHold {
  final String branch;
  final List<String> paths;
  final bool publish;
  final String candidate;
  final String? destination;
  final String? worktreePath;
  final String? destinationWorktreePath;

  new({
    required this.branch,
    required this.paths,
    required this.candidate,
    this.publish = false,
    this.destination,
    this.worktreePath,
    this.destinationWorktreePath,
  }) {
    if (candidate.isEmpty) throw const FormatException('Missing execution-surface candidate');
  }

  factory fromPromotion(String branch, WorkflowGitPromotionHeld hold) => WorkflowExecutionSurfaceHold(
    branch: branch,
    paths: hold.paths,
    candidate: hold.candidate,
    destination: hold.destination,
    worktreePath: hold.worktreePath,
    destinationWorktreePath: hold.destinationWorktreePath,
  );

  String get message => [
    'Execution surface changes require review before ${publish ? 'publishing' : 'promoting'} $branch'
        '${destination == null ? '' : ' to $destination'}.',
    if (worktreePath case final source?) 'Source worktree $source.',
    if (destinationWorktreePath case final target? when target != worktreePath) 'Destination worktree $target.',
    'Affected paths: ${paths.join(', ')}.',
  ].join(' ');

  Map<String, dynamic> toJson() => {
    'branch': branch,
    'paths': paths,
    'publish': publish,
    'candidate': candidate,
    'destination': ?destination,
    'worktreePath': ?worktreePath,
    'destinationWorktreePath': ?destinationWorktreePath,
  };

  /// Reads the pending hold from the host portion of a persisted run context.
  static WorkflowExecutionSurfaceHold? read(Map<String, dynamic> contextJson) {
    final raw = contextJson[workflowExecutionSurfaceHoldKey];
    if (raw == null) return null;
    if (raw is! Map ||
        raw['branch'] is! String ||
        raw['paths'] is! List ||
        raw['publish'] is! bool ||
        raw['candidate'] is! String) {
      throw const FormatException('Invalid execution-surface hold');
    }
    return WorkflowExecutionSurfaceHold(
      branch: raw['branch'] as String,
      paths: (raw['paths'] as List).cast<String>(),
      publish: raw['publish'] as bool,
      candidate: raw['candidate'] as String,
      destination: raw['destination'] as String?,
      worktreePath: raw['worktreePath'] as String?,
      destinationWorktreePath: raw['destinationWorktreePath'] as String?,
    );
  }
}

/// Returns the candidate approved by a person from host-owned run state.
String? workflowApprovedCandidate(Map<String, dynamic> contextJson) {
  final candidate = contextJson[workflowApprovedCandidateKey];
  return candidate is String && candidate.isNotEmpty ? candidate : null;
}
