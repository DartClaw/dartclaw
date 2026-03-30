import 'package:dartclaw_cli/src/commands/wiring/channel_session_title.dart';
import 'package:test/test.dart';

void main() {
  group('channelSessionTitle', () {
    test('WhatsApp JID extracts number before @', () {
      expect(channelSessionTitle('+491234567@s.whatsapp.net'), 'WA › +491234567');
    });

    test('Google Chat user strips users/ prefix', () {
      expect(channelSessionTitle('users/12345'), 'Google Chat › 12345');
    });

    test('Google Chat space strips spaces/ prefix', () {
      expect(channelSessionTitle('spaces/AAAA'), 'Google Chat › AAAA');
    });

    test('Signal JID starting with + is kept as-is', () {
      expect(channelSessionTitle('+491234567'), 'Signal › +491234567');
    });

    test('Signal short identifier is kept as-is', () {
      expect(channelSessionTitle('abc'), 'Signal › abc');
    });

    test('Signal long identifier is truncated to 8 chars', () {
      expect(channelSessionTitle('abcdef1234567890'), 'Signal › abcdef12');
    });
  });
}
