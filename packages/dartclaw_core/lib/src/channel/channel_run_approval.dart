/// Action ID of the Approve button on an approval post.
const runApproveActionId = 'run_approve';

/// Action ID of the Reject button on an approval post.
const runRejectActionId = 'run_reject';

/// Action ID of the Request changes button on an approval post.
const runRequestChangesActionId = 'run_request_changes';

/// Action ID of the request-changes form's submission.
const runRequestChangesSubmitActionId = 'run_request_changes_submit';

/// Data key carrying the run ID on every run action.
const runActionRunIdKey = 'runId';

/// Data key carrying the approval step ID on every run action.
const runActionStepIdKey = 'stepId';

/// Data key carrying the single-use nonce on every run action.
const runActionNonceKey = 'nonce';

/// What a click on an approval post asks for.
enum ChannelRunApprovalAction {
  /// Resume the run past the approval.
  approve(runApproveActionId, 'Approve'),

  /// Cancel the run at the approval.
  reject(runRejectActionId, 'Reject'),

  /// The click on Request changes. Resolves nothing: it asks whether the
  /// clicker may request changes at a live gate before a form opens.
  checkRequestChanges(runRequestChangesActionId, 'Request changes'),

  /// The form's submission: send the run back to the gate's revise step with
  /// the request's feedback.
  requestChanges(runRequestChangesSubmitActionId, 'Request changes');

  /// The action ID a channel renders for this action and reads back from a click.
  final String actionId;

  /// The button text, the same on every channel.
  final String label;

  new(this.actionId, this.label);

  /// The action named by [actionId], or `null` when it is not a run action.
  static ChannelRunApprovalAction? fromActionId(String? actionId) =>
      values.where((action) => action.actionId == actionId).firstOrNull;
}

/// A click on an approval post, as a channel adapter read it.
class ChannelRunApprovalRequest {
  /// What was clicked.
  final ChannelRunApprovalAction action;

  /// The run the post belongs to, as carried by the click.
  final String runId;

  /// The approval step the post belongs to, as carried by the click.
  final String stepId;

  /// The single-use nonce carried by the click.
  final String nonce;

  /// The clicker, in the exact form the inbound path uses for a sender.
  final String senderId;

  /// The clicker's display name, when the platform supplied one.
  final String? senderDisplayName;

  /// The channel type name the click arrived on.
  final String channelType;

  /// Identity of the message the click landed on.
  final String postMessageId;

  /// What the sender typed, for [ChannelRunApprovalAction.requestChanges].
  final String? feedback;

  /// Creates a click request.
  const new({
    required this.action,
    required this.runId,
    required this.stepId,
    required this.nonce,
    required this.senderId,
    this.senderDisplayName,
    required this.channelType,
    required this.postMessageId,
    this.feedback,
  });
}

/// Why a click on an approval post was refused.
enum ChannelRunApprovalRefusal {
  /// The clicker is not an admin sender.
  notAdmin,

  /// The click does not match a live approval post.
  invalid,

  /// The approval was already resolved.
  alreadyResolved,

  /// The run is not waiting at that approval.
  notPending,

  /// The gate names no revise step, so it offers no request changes.
  changesNotOffered,

  /// The gate already went through its bound of request-changes rounds.
  limitReached,

  /// A request to change needs feedback and carried none.
  feedbackRequired,
}

/// What a click on an approval post came to.
sealed class ChannelRunApprovalResult {
  const new();
}

/// The approval was resolved by the click.
final class ChannelRunApprovalResolved extends ChannelRunApprovalResult {
  const new();
}

/// The clicker may request changes at a live gate; nothing changed.
final class ChannelRunApprovalPermitted extends ChannelRunApprovalResult {
  const new();
}

/// The click was refused and changed nothing.
final class ChannelRunApprovalRefused extends ChannelRunApprovalResult {
  /// Why it was refused.
  final ChannelRunApprovalRefusal reason;

  /// Text to answer the clicker with.
  final String message;

  const new(this.reason, this.message);
}

/// Resolving the approval failed and left it pending, so the clicker may retry.
final class ChannelRunApprovalFailed extends ChannelRunApprovalResult {
  /// Text to answer the clicker with.
  final String message;

  const new(this.message);
}

/// Handles a click on an approval post. A channel adapter parses the click,
/// calls this, and answers only the clicker with what it returns.
typedef ChannelRunApprovalHandler = Future<ChannelRunApprovalResult> Function(ChannelRunApprovalRequest request);
