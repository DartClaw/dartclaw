import 'package:dartclaw_core/dartclaw_core.dart' show Task, TaskOrigin, TurnProvenance;
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show ChannelType;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowRunOrigin, WorkflowRunRepository;

/// The provenance a task or workflow-step turn carries: the identity of the chat requester it was delegated by.
///
/// Both origins are host-captured from the requester's own turn, so the turn context can name the requester
/// without a model supplying it. The turn is marked [TurnProvenance.delegated]: a gate may let it write as its
/// requester, but one that needs a human present (run approvals) refuses it. A run or task that did not start in a
/// chat channel yields null, a non-channel turn. Throws [ArgumentError] when a stored channel type names no
/// [ChannelType], so a delegated turn fails rather than running unattributed.
Future<TurnProvenance?> delegatedTurnProvenance(Task task, WorkflowRunRepository? runs) async {
  final runId = task.workflowRunId;
  if (runId != null) {
    final run = await runs?.getById(runId);
    return run == null ? null : runOriginProvenance(run.origin);
  }
  final origin = TaskOrigin.fromConfigJson(task.configJson);
  return origin == null ? null : taskOriginProvenance(origin);
}

/// Provenance for a turn delegated by the chat turn [origin] was captured from.
///
/// [includeSender] is false where the stored sender is not the one acting, as for a push-back, which the review
/// seam cannot attribute to whoever pushed.
TurnProvenance taskOriginProvenance(TaskOrigin origin, {bool includeSender = true}) => TurnProvenance.channel(
  channelType: ChannelType.values.byName(origin.channelType),
  recipientId: origin.recipientId,
  sessionKey: origin.sessionKey,
  senderId: includeSender ? origin.senderId : null,
  delegated: true,
);

/// Provenance for a turn a run started from a chat channel drives, or null for any other origin.
TurnProvenance? runOriginProvenance(WorkflowRunOrigin origin) {
  final channelType = origin.channelType;
  if (channelType == null) return null;
  return TurnProvenance.channel(
    channelType: ChannelType.values.byName(channelType),
    recipientId: origin.recipientId,
    threadId: origin.threadId,
    sessionKey: origin.sessionKey,
    senderId: origin.senderId,
    delegated: true,
  );
}
