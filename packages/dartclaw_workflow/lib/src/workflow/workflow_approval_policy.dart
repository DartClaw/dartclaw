import 'package:dartclaw_config/dartclaw_config.dart' show WorkflowApprovalPolicy;

import 'workflow_run.dart' show WorkflowRun;

const workflowApprovalsContextKey = '_workflow.approvals';
const approvalAutoResolvedPrefix = '_approval.auto_resolved.';

WorkflowApprovalPolicy workflowApprovalPolicyFromRun(WorkflowRun run) {
  final raw = run.contextJson[workflowApprovalsContextKey];
  if (raw is String) {
    return WorkflowApprovalPolicy.fromYaml(raw) ?? WorkflowApprovalPolicy.manual;
  }
  final data = run.contextJson['data'];
  if (data is Map) {
    final nested = data[workflowApprovalsContextKey];
    if (nested is String) {
      return WorkflowApprovalPolicy.fromYaml(nested) ?? WorkflowApprovalPolicy.manual;
    }
  }
  return WorkflowApprovalPolicy.manual;
}

Map<String, dynamic> approvalAutoResolvedValue({
  required WorkflowApprovalPolicy policy,
  required String reason,
  required String source,
}) {
  return {
    'policy': policy.yamlValue,
    'reason': reason,
    'source': source,
    'resolved_at': DateTime.now().toIso8601String(),
  };
}
