import 'dart:math';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';

/// Derives a human-readable session title from the channel and sender JID.
String channelSessionTitle(ChannelType channelType, String senderJid) => switch (channelType) {
  ChannelType.whatsapp => 'WA › ${senderJid.split('@').first}',
  ChannelType.googlechat => 'Google Chat › ${_googleChatId(senderJid)}',
  ChannelType.signal =>
    senderJid.startsWith('+') ? 'Signal › $senderJid' : 'Signal › ${senderJid.substring(0, min(8, senderJid.length))}',
  ChannelType.web => 'Web › $senderJid',
};

String _googleChatId(String senderJid) {
  for (final prefix in const ['users/', 'spaces/']) {
    if (senderJid.startsWith(prefix)) return senderJid.substring(prefix.length);
  }
  return senderJid;
}
