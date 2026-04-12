/// Parsed review command from a channel message.
class ReviewCommand {
  /// The review action: `accept`, `reject`, or `push_back`.
  final String action;

  /// Optional task ID prefix supplied by the user.
  final String? taskId;

  /// Optional feedback text for push_back commands.
  final String? comment;

  const ReviewCommand({required this.action, this.taskId, this.comment});
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
typedef ChannelReviewHandler = Future<ChannelReviewResult> Function(String taskId, String action, {String? comment});

/// Stateless parser for review commands.
///
/// Recognized patterns:
/// - `accept` / `accept <id>`
/// - `reject` / `reject <id>`
/// - `push back: <feedback>` / `push back <id>: <feedback>`
class ReviewCommandParser {
  const ReviewCommandParser();

  /// Returns a [ReviewCommand] when [message] is a recognized review command,
  /// otherwise `null`.
  ReviewCommand? parse(String message) {
    final trimmed = message.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    // Check for "push back" prefix first (two-word command, must come before
    // the single-word accept/reject check to avoid misclassification).
    if (trimmed.toLowerCase().startsWith('push back')) {
      return _parsePushBack(trimmed);
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

  /// Parses `push back: <feedback>` or `push back <id>: <feedback>`.
  ReviewCommand? _parsePushBack(String trimmed) {
    // Strip case-insensitive "push back" prefix.
    final rest = trimmed.substring('push back'.length).trimLeft();
    if (rest.isEmpty) return null; // bare "push back" with no colon/feedback

    final colonIndex = rest.indexOf(':');
    if (colonIndex < 0) return null; // no colon = not a valid push back

    final beforeColon = rest.substring(0, colonIndex).trim();
    final feedback = rest.substring(colonIndex + 1).trim();

    if (feedback.isEmpty) return null; // empty feedback

    // beforeColon is either:
    //   empty  → no task ID
    //   single word → task ID
    //   multiple words → malformed
    if (beforeColon.isNotEmpty && beforeColon.contains(RegExp(r'\s'))) {
      return null; // malformed
    }

    final taskId = beforeColon.isEmpty ? null : beforeColon.toLowerCase();
    return ReviewCommand(action: 'push_back', taskId: taskId, comment: feedback);
  }
}
