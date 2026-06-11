import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  group('FakeChannelManager', () {
    test('captures inbound messages in arrival order', () {
      final manager = FakeChannelManager();
      final first = ChannelMessage(channelType: ChannelType.signal, senderJid: 'a', text: 'one');
      final second = ChannelMessage(channelType: ChannelType.signal, senderJid: 'b', text: 'two');

      manager.handleInboundMessage(first);
      manager.handleInboundMessage(second);

      expect(manager.received, [first, second]);
    });

    test('received starts empty', () {
      expect(FakeChannelManager().received, isEmpty);
    });
  });
}
