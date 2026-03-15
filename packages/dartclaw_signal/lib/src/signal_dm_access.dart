import 'package:dartclaw_core/dartclaw_core.dart';

/// Group access mode for Signal channel.
enum SignalGroupAccessMode { allowlist, open, disabled }

/// Controls whether a group message should be processed based on mention status.
class SignalMentionGating {
  final bool requireMention;
  final List<RegExp> _patterns;
  String ownNumber;

  SignalMentionGating({required this.requireMention, required List<String> mentionPatterns, required this.ownNumber})
    : _patterns = mentionPatterns.map(RegExp.new).toList();

  /// Whether the given message should be processed.
  ///
  /// DM messages (no groupJid) always return true.
  /// Group messages require a mention when [requireMention] is true.
  bool shouldProcess(ChannelMessage message) {
    if (message.groupJid == null) return true;
    if (!requireMention) return true;

    // Check native mentionedJids
    if (message.mentionedJids.contains(ownNumber)) return true;

    // Check regex mention patterns against text
    for (final pattern in _patterns) {
      if (pattern.hasMatch(message.text)) return true;
    }

    return false;
  }
}
