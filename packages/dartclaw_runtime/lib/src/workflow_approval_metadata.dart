import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowRun, workflowContextValue;

Map<String, dynamic> workflowApprovalMetadata(WorkflowRun run, String stepId, Object? status) {
  final prefix = '$stepId.approval.';
  return {
    'status': status,
    'message': workflowContextValue(run, '${prefix}message'),
    'requestedAt': workflowContextValue(run, '${prefix}requested_at'),
    'resolvedAt': ?workflowContextValue(run, '${prefix}resolved_at'),
    'feedback': ?workflowContextValue(run, '${prefix}feedback'),
    'timeoutDeadline': ?workflowContextValue(run, '${prefix}timeout_deadline'),
    'cancelReason': ?workflowContextValue(run, '${prefix}cancel_reason'),
  };
}
