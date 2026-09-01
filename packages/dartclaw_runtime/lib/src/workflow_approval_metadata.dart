Map<String, dynamic> workflowApprovalMetadata(Map<String, dynamic> context, String stepId, Object? status) {
  final prefix = '$stepId.approval.';
  return {
    'status': status,
    'message': context['${prefix}message'],
    'requestedAt': context['${prefix}requested_at'],
    if (context['${prefix}resolved_at'] != null) 'resolvedAt': context['${prefix}resolved_at'],
    if (context['${prefix}feedback'] != null) 'feedback': context['${prefix}feedback'],
    if (context['${prefix}timeout_deadline'] != null) 'timeoutDeadline': context['${prefix}timeout_deadline'],
    if (context['${prefix}cancel_reason'] != null) 'cancelReason': context['${prefix}cancel_reason'],
  };
}
