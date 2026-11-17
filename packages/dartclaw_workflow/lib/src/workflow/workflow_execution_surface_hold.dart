import 'workflow_context.dart';
import 'workflow_output_contract.dart';

class WorkflowExecutionSurfaceHold {
  final String branch;
  final List<String> paths;
  final bool publish;

  const new({required this.branch, required this.paths, this.publish = false});

  String get message =>
      'Execution surface changes require a person to review ${paths.join(', ')}. '
      'Resume this run in the web UI or through the API after reviewing the changes; an agent tool cannot approve it.';

  Map<String, dynamic> toJson() => {'branch': branch, 'paths': paths, 'publish': publish};

  static WorkflowExecutionSurfaceHold? read(WorkflowContext context) {
    final raw = context[workflowExecutionSurfaceHoldKey];
    if (raw == null) return null;
    if (raw is! Map || raw['branch'] is! String || raw['paths'] is! List || raw['publish'] is! bool) {
      throw const FormatException('Invalid execution-surface hold');
    }
    return WorkflowExecutionSurfaceHold(
      branch: raw['branch'] as String,
      paths: (raw['paths'] as List).cast<String>(),
      publish: raw['publish'] as bool,
    );
  }
}

/// Whether exact host context data approves [branch]. Variables and nested
/// aliases do not grant approval. Throws [FormatException] for malformed data.
bool workflowBranchIsApproved(Map<String, dynamic> contextJson, String branch) {
  final data = contextJson['data'];
  if (data is! Map) return false;
  final approved = data[workflowApprovedBranchesKey];
  if (approved == null) return false;
  if (approved is! List || approved.any((value) => value is! String)) {
    throw const FormatException('Invalid approved workflow branches');
  }
  return approved.contains(branch);
}
