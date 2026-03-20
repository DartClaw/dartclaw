import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  group('FakeChannel', () {
    test('tracks lifecycle calls and connection state', () async {
      final channel = FakeChannel();

      await channel.connect();
      expect(channel.connected, isTrue);
      expect(channel.connectCallCount, 1);

      await channel.disconnect();
      expect(channel.connected, isFalse);
      expect(channel.disconnectCallCount, 1);
    });

    test('records sent messages and owned jids', () async {
      final channel = FakeChannel(ownedJids: const {'alice@s.whatsapp.net'});
      const response = ChannelResponse(text: 'hello');

      expect(channel.ownsJid('alice@s.whatsapp.net'), isTrue);
      expect(channel.ownsJid('bob@s.whatsapp.net'), isFalse);

      await channel.sendMessage('alice@s.whatsapp.net', response);

      expect(channel.sentMessages, [('alice@s.whatsapp.net', response)]);
    });

    test('can be configured to own all jids', () {
      final channel = FakeChannel(ownsAllJids: true);

      expect(channel.ownsJid('anyone@example.com'), isTrue);
    });

    test('can simulate send failures', () async {
      final channel = FakeChannel(throwOnSend: true);

      await expectLater(
        channel.sendMessage('alice@s.whatsapp.net', const ChannelResponse(text: 'hello')),
        throwsA(isA<StateError>()),
      );
      expect(channel.sentMessages, isEmpty);
    });
  });
}
