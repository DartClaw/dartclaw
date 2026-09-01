import 'dart:math';

/// Derives a human-readable session title from a channel sender JID.
///
/// Heuristic: inspects JID format to determine channel type and extracts
/// a meaningful prefix for display in the session list.
String channelSessionTitle(String senderJid) {
  if (senderJid.contains('@')) {
    return 'WA › ${senderJid.split('@').first}';
  }
  if (senderJid.startsWith('users/')) {
    return 'Google Chat › ${senderJid.substring('users/'.length)}';
  }
  if (senderJid.startsWith('spaces/')) {
    return 'Google Chat › ${senderJid.substring('spaces/'.length)}';
  }
  if (senderJid.startsWith('+')) {
    return 'Signal › $senderJid';
  }
  return 'Signal › ${senderJid.substring(0, min(8, senderJid.length))}';
}
