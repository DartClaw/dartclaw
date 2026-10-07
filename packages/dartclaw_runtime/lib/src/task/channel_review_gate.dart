import 'package:dartclaw_core/dartclaw_core.dart' show ChannelReviewError, ChannelReviewHandler;
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show AuditEntry, GuardAuditLogger;
import 'package:logging/logging.dart';

final _log = Logger('ChannelReviewGate');

const _guardName = 'TaskReviewGate';
const _refusal = 'Only admin senders can accept or reject tasks';

/// Wraps [review] so a channel's Accept or Reject click reviews a task only for a sender in
/// `governance.admin_senders`, the rule run approvals use, and audits each decision.
///
/// The sender comes only from the adapter's parse of the click. A click naming no sender is an admin only where
/// every sender is. A null [auditLogger] writes nothing and still refuses; a failing write is logged and does not
/// change the answer.
ChannelReviewHandler adminGatedReviewHandler(
  ChannelReviewHandler review, {
  required bool Function(String senderId) isAdmin,
  GuardAuditLogger? auditLogger,
}) {
  return (taskId, action, {comment, channelType, senderId}) async {
    final admin = isAdmin(senderId ?? '');
    if (auditLogger != null) {
      try {
        await auditLogger.writeEntry(
          AuditEntry(
            timestamp: DateTime.now(),
            guard: _guardName,
            hook: 'button',
            verdict: admin ? 'pass' : 'block',
            reason: admin
                ? 'task $taskId'
                : '${senderId == null ? 'click carries no sender' : 'sender is not in governance.admin_senders'}'
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
    if (!admin) return const ChannelReviewError(_refusal);
    return review(taskId, action, comment: comment, channelType: channelType, senderId: senderId);
  };
}
