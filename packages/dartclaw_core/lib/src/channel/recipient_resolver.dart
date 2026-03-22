import 'channel.dart';

/// Resolves the recipient identifier for outbound channel messages.
///
/// Resolution priority:
/// 1. `metadata['spaceName']` — Google Chat Space name (e.g. `spaces/AAAA`).
///    Replies to a Space must target the space, not the sender user ID.
/// 2. `groupJid` — WhatsApp/Signal group JID for group messages.
/// 3. `senderJid` — Direct message sender as the fallback.
///
/// This is the single consolidated implementation replacing the previously-
/// duplicate `ChannelManager._resolveRecipientId` and
/// `MessageQueue._resolveRecipientJid` (H-5 from the 0.12 architecture review).
String resolveRecipientId(ChannelMessage message) {
  final metadataRecipient = message.metadata['spaceName'];
  if (metadataRecipient is String && metadataRecipient.isNotEmpty) {
    return metadataRecipient;
  }
  return message.groupJid ?? message.senderJid;
}
