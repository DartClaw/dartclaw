import 'package:dartclaw_kernel/dartclaw_kernel.dart' show ChannelType;

/// Where an agent turn came from, built by the host and never supplied by a model.
///
/// [surface] is a [ChannelType] name for a chat or web-chat turn, or `cron` for a scheduled prompt. A turn with no
/// [senderId] is not a channel turn (web chat, scheduled), so a sender gate refuses or bypasses it by its own rule.
final class TurnProvenance {
  /// A chat-channel turn: [surface] and [channelType] both name [channelType].
  new channel({
    required ChannelType channelType,
    required this.sessionKey,
    this.recipientId,
    this.threadId,
    this.senderId,
  }) : surface = channelType.name,
       channelType = channelType.name;

  /// A web-chat turn: the session's own key and nothing channel-shaped.
  const new web({this.sessionKey})
    : surface = 'web',
      channelType = null,
      recipientId = null,
      threadId = null,
      senderId = null;

  /// A scheduled prompt turn.
  const new cron()
    : surface = 'cron',
      channelType = null,
      recipientId = null,
      threadId = null,
      sessionKey = null,
      senderId = null;

  /// A [ChannelType] name, or `cron`.
  final String surface;

  /// Channel type name of a chat turn.
  final String? channelType;

  /// Recipient the chat turn replies to.
  final String? recipientId;

  /// Thread within [recipientId], when the channel threads.
  final String? threadId;

  /// Key of the session the turn runs in.
  final String? sessionKey;

  /// Sender of the inbound chat message.
  final String? senderId;

  @override
  bool operator ==(Object other) =>
      other is TurnProvenance &&
      other.surface == surface &&
      other.channelType == channelType &&
      other.recipientId == recipientId &&
      other.threadId == threadId &&
      other.sessionKey == sessionKey &&
      other.senderId == senderId;

  @override
  int get hashCode => Object.hash(surface, channelType, recipientId, threadId, sessionKey, senderId);

  @override
  String toString() =>
      'TurnProvenance($surface, recipient: $recipientId, thread: $threadId, session: $sessionKey, sender: $senderId)';
}
