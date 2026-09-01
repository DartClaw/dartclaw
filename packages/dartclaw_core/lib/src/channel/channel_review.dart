/// Channel-facing result for a review action.
sealed class ChannelReviewResult {
  const new();
}

/// Review action succeeded.
final class ChannelReviewSuccess extends ChannelReviewResult {
  final String taskTitle;
  final String action;

  const new({required this.taskTitle, required this.action});
}

/// Review action failed because the task has merge conflicts.
final class ChannelReviewMergeConflict extends ChannelReviewResult {
  final String taskTitle;

  const new({required this.taskTitle});
}

/// Review action failed.
final class ChannelReviewError extends ChannelReviewResult {
  final String message;

  const new(this.message);
}

/// Callback for executing a channel-originated review action.
typedef ChannelReviewHandler = Future<ChannelReviewResult> Function(String taskId, String action, {String? comment});
