import 'package:dartclaw_core/dartclaw_core.dart' show ChannelReviewError, ChannelReviewHandler;
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show AuditEntry, GuardAuditLogger;
import 'package:logging/logging.dart';

final _log = Logger('ChannelReviewGate');

/// Guard name on the entries a task review writes.
const taskReviewGuard = 'TaskReviewGate';
const _refusal = 'Only admin senders can accept or reject tasks';

/// Decides whether a chat sender may review [taskId], and audits the decision: the one admin rule and the one
/// `TaskReviewGate` audit writer, shared by a channel's review button and the `task_review` tool.
///
/// [hook] names the surface asking (`button` or `tool`). A caller naming no sender is an admin only where every
/// sender is. A null [auditLogger] writes nothing and still refuses; a failing write is logged and does not
/// change the answer.
Future<bool> admitTaskReview(
  String taskId,
  String action, {
  required bool Function(String senderId) isAdmin,
  GuardAuditLogger? auditLogger,
  String hook = 'button',
  String? channelType,
  String? senderId,
}) async {
  final admin = isAdmin(senderId ?? '');
  if (auditLogger != null) {
    try {
      await auditLogger.writeEntry(
        AuditEntry(
          timestamp: DateTime.now(),
          guard: taskReviewGuard,
          hook: hook,
          verdict: admin ? 'pass' : 'block',
          reason: admin
              ? 'task $taskId'
              : '${senderId == null ? 'caller carries no sender' : 'sender is not in governance.admin_senders'}'
                    ' (task $taskId)',
          channel: channelType,
          peerId: senderId,
          tool: 'task_$action',
          decision: admin ? 'allow' : 'deny',
          principal: senderId,
        ),
      );
    } catch (error, stackTrace) {
      _log.severe('Failed to audit task review for $taskId', error, stackTrace);
    }
  }
  return admin;
}

/// Wraps [review] so a channel's Accept or Reject click reviews a task only for a sender in
/// `governance.admin_senders`, the rule run approvals use, and audits each decision through [admitTaskReview].
///
/// The sender comes only from the adapter's parse of the click.
ChannelReviewHandler adminGatedReviewHandler(
  ChannelReviewHandler review, {
  required bool Function(String senderId) isAdmin,
  GuardAuditLogger? auditLogger,
}) {
  return (taskId, action, {comment, channelType, senderId}) async {
    final admitted = await admitTaskReview(
      taskId,
      action,
      isAdmin: isAdmin,
      auditLogger: auditLogger,
      channelType: channelType,
      senderId: senderId,
    );
    if (!admitted) return const ChannelReviewError(_refusal);
    return review(taskId, action, comment: comment, channelType: channelType, senderId: senderId);
  };
}
