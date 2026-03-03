import '../channel.dart';

/// DM access mode for Signal channel.
enum SignalDmAccessMode { allowlist, open, disabled }

/// Controls which senders are allowed to DM the bot via Signal.
class SignalDmAccessController {
  final SignalDmAccessMode mode;
  final Set<String> _allowlist;

  SignalDmAccessController({required this.mode, Set<String>? allowlist}) : _allowlist = allowlist ?? {};

  Set<String> get allowlist => Set.unmodifiable(_allowlist);

  /// Whether the given sender phone number is allowed to message the bot.
  bool isAllowed(String senderId) {
    switch (mode) {
      case SignalDmAccessMode.open:
        return true;
      case SignalDmAccessMode.disabled:
        return false;
      case SignalDmAccessMode.allowlist:
        return _allowlist.contains(senderId);
    }
  }

  /// Add a phone number to the allowlist.
  void addToAllowlist(String phoneNumber) {
    _allowlist.add(phoneNumber);
  }
}

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
