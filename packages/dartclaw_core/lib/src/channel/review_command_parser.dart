/// Parsed review command from a channel message.
class ReviewCommand {
  /// The review action: `accept` or `reject`.
  final String action;

  /// Optional task ID prefix supplied by the user.
  final String? taskId;

  const ReviewCommand({required this.action, this.taskId});
}

/// Channel-facing result for a review action.
sealed class ChannelReviewResult {
  const ChannelReviewResult();
}

/// Review action succeeded.
final class ChannelReviewSuccess extends ChannelReviewResult {
  final String taskTitle;
  final String action;

  const ChannelReviewSuccess({required this.taskTitle, required this.action});
}

/// Review action failed because the task has merge conflicts.
final class ChannelReviewMergeConflict extends ChannelReviewResult {
  final String taskTitle;

  const ChannelReviewMergeConflict({required this.taskTitle});
}

/// Review action failed.
final class ChannelReviewError extends ChannelReviewResult {
  final String message;

  const ChannelReviewError(this.message);
}

/// Callback used by [ChannelManager] to execute a review action.
typedef ChannelReviewHandler = Future<ChannelReviewResult> Function(String taskId, String action);

/// Stateless parser for exact-match review commands.
class ReviewCommandParser {
  const ReviewCommandParser();

  /// Returns a [ReviewCommand] when [message] is exactly `accept`, `reject`,
  /// `accept <id>`, or `reject <id>` after trimming whitespace.
  ReviewCommand? parse(String message) {
    final trimmed = message.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    final parts = trimmed.split(RegExp(r'\s+'));
    if (parts.length > 2) {
      return null;
    }

    final action = parts.first.toLowerCase();
    if (action != 'accept' && action != 'reject') {
      return null;
    }

    final taskId = parts.length == 2 ? parts[1].toLowerCase() : null;
    return ReviewCommand(action: action, taskId: taskId);
  }
}
