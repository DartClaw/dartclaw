import 'channel.dart';

/// Controls whether a group message should be processed based on mention/reply status.
class MentionGating {
  /// Whether group messages must explicitly mention the bot to be processed.
  final bool requireMention;

  final List<RegExp> _patterns;

  /// Bot identifier matched against [ChannelMessage.mentionedJids].
  String ownJid;

  /// Creates mention-gating rules for group message processing.
  MentionGating({required this.requireMention, required List<String> mentionPatterns, required this.ownJid})
    : _patterns = mentionPatterns.map(RegExp.new).toList();

  /// Whether the given message should be processed.
  ///
  /// DM messages (no groupJid) always return true.
  /// Group messages require a mention or reply-to-bot when [requireMention] is true.
  bool shouldProcess(ChannelMessage message) {
    if (message.groupJid == null) return true;
    if (!requireMention) return true;
    if (message.mentionedJids.contains(ownJid)) return true;

    for (final pattern in _patterns) {
      if (pattern.hasMatch(message.text)) return true;
    }

    return false;
  }
}
