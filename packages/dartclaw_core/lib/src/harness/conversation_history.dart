import 'package:dartclaw_config/dartclaw_config.dart' show HistoryConfig;

// Regex patterns for synthetic assistant markers that indicate guard-blocked
// or failed exchanges. All patterns use ^ and $ anchors for exact matching.
final _blockedByGuardRe = RegExp(r'^\[Blocked by guard:.*\]$');
final _responseBlockedRe = RegExp(r'^\[Response blocked by guard:.*\]$');
final _turnFailedRe = RegExp(r'^\[Turn failed(?::.*)?]$');
final _turnCancelledRe = RegExp(r'^\[Turn cancelled\]$');
final _loopDetectedRe = RegExp(r'^\[Loop detected:.*\]$');

bool _isSyntheticMarker(String content) =>
    _blockedByGuardRe.hasMatch(content) ||
    _responseBlockedRe.hasMatch(content) ||
    _turnFailedRe.hasMatch(content) ||
    _turnCancelledRe.hasMatch(content) ||
    _loopDetectedRe.hasMatch(content);

String _truncateMessage(String content, int maxChars) {
  if (content.length <= maxChars) return content;
  return '${content.substring(0, maxChars - 1)}...';
}

List<({String userContent, String assistantContent})> _enforceHistoryBudget(
  List<({String userContent, String assistantContent})> pairs,
  int maxTotalChars,
) {
  var total = 0;
  for (final pair in pairs) {
    total += pair.userContent.length + pair.assistantContent.length;
  }
  // Drop oldest complete pairs until within budget.
  final result = List.of(pairs);
  while (total > maxTotalChars && result.isNotEmpty) {
    final oldest = result.removeAt(0);
    total -= oldest.userContent.length + oldest.assistantContent.length;
  }
  return result;
}

/// Builds a replay-safe conversation history block from persisted messages.
///
/// Filters out guard-blocked exchanges, synthetic status markers, interrupted
/// turns, and non-user/assistant roles. Truncates per-message and enforces
/// total budget by dropping oldest exchange pairs first.
///
/// Returns empty string if no usable history remains after filtering.
String buildReplaySafeHistory(List<Map<String, dynamic>> messages, HistoryConfig config) {
  // Step 1: Role filter — keep only user and assistant messages with content.
  final filtered = <Map<String, dynamic>>[];
  for (final msg in messages) {
    final role = msg['role'] as String?;
    if (role != 'user' && role != 'assistant') continue;
    final content = msg['content'];
    final contentStr = content is String ? content : content?.toString() ?? '';
    if (contentStr.trim().isEmpty) continue;
    filtered.add({'role': role, 'content': contentStr});
  }

  // Step 2: Pair messages into (user, assistant) exchange pairs.
  // Orphaned user messages (no following assistant) are skipped.
  final pairs = <({String userContent, String assistantContent})>[];
  var i = 0;
  while (i < filtered.length) {
    final msg = filtered[i];
    if (msg['role'] == 'user') {
      // Look for the next assistant message.
      if (i + 1 < filtered.length && filtered[i + 1]['role'] == 'assistant') {
        final userContent = msg['content'] as String;
        final assistantContent = filtered[i + 1]['content'] as String;

        // Step 3: Exclude pairs where the assistant response is a synthetic marker.
        if (!_isSyntheticMarker(assistantContent)) {
          pairs.add((userContent: userContent, assistantContent: assistantContent));
        }
        i += 2;
      } else {
        // Orphaned user message — skip it (covers trailing orphan and
        // user-after-user cases).
        i++;
      }
    } else {
      // Assistant message without preceding user — skip.
      i++;
    }
  }

  if (pairs.isEmpty) return '';

  // Step 4: Per-message truncation.
  final truncated = pairs
      .map(
        (p) => (
          userContent: _truncateMessage(p.userContent, config.maxMessageChars),
          assistantContent: _truncateMessage(p.assistantContent, config.maxMessageChars),
        ),
      )
      .toList();

  // Step 5: Total budget enforcement — drop oldest complete pairs first.
  final budgeted = _enforceHistoryBudget(truncated, config.maxTotalChars);

  if (budgeted.isEmpty) return '';

  // Step 6: Format output block.
  final buffer = StringBuffer();
  buffer.writeln('<conversation_history>');
  buffer.writeln('Below is the conversation history from prior turns in this session.');
  buffer.writeln('Use this as context for the current message.');
  buffer.writeln();
  for (final pair in budgeted) {
    buffer.writeln('[user]: ${pair.userContent}');
    buffer.writeln('[assistant]: ${pair.assistantContent}');
  }
  // Remove trailing newline before closing tag.
  final content = buffer.toString().trimRight();
  return '$content\n</conversation_history>';
}
