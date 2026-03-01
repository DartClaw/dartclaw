import '../channel.dart';

/// Controls whether a group message should be processed based on mention/reply status.
class MentionGating {
  final bool requireMention;
  final List<RegExp> _patterns;
  String ownJid;

  MentionGating({required this.requireMention, required List<String> mentionPatterns, required this.ownJid})
    : _patterns = mentionPatterns.map(RegExp.new).toList();

  /// Whether the given message should be processed.
  ///
  /// DM messages (no groupJid) always return true.
  /// Group messages require a mention or reply-to-bot when [requireMention] is true.
  bool shouldProcess(ChannelMessage message) {
    // DMs always process
    if (message.groupJid == null) return true;

    // Group messages: if mention not required, always process
    if (!requireMention) return true;

    // Check native mentionedJids
    if (message.mentionedJids.contains(ownJid)) return true;

    // Check regex mention patterns against text
    for (final pattern in _patterns) {
      if (pattern.hasMatch(message.text)) return true;
    }

    return false;
  }
}
