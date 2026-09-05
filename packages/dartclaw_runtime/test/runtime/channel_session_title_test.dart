import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/runtime/channel_session_title.dart';
import 'package:test/test.dart';

void main() {
  group('channelSessionTitle', () {
    test('WhatsApp JID extracts number before @', () {
      expect(channelSessionTitle(ChannelType.whatsapp, '+491234567@s.whatsapp.net'), 'WA › +491234567');
    });

    test('Google Chat user strips users/ prefix', () {
      expect(channelSessionTitle(ChannelType.googlechat, 'users/12345'), 'Google Chat › 12345');
    });

    test('Google Chat space strips spaces/ prefix', () {
      expect(channelSessionTitle(ChannelType.googlechat, 'spaces/AAAA'), 'Google Chat › AAAA');
    });

    test('Signal JID starting with + is kept as-is', () {
      expect(channelSessionTitle(ChannelType.signal, '+491234567'), 'Signal › +491234567');
    });

    test('Signal short identifier is kept as-is', () {
      expect(channelSessionTitle(ChannelType.signal, 'abc'), 'Signal › abc');
    });

    test('Signal long identifier is truncated to 8 chars', () {
      expect(channelSessionTitle(ChannelType.signal, 'abcdef1234567890'), 'Signal › abcdef12');
    });
  });
}
