import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/alerts/alert_delivery_adapter.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  late FakeChannel channel;
  late AlertDeliveryAdapter adapter;

  setUp(() {
    channel = FakeChannel(name: 'whatsapp', type: ChannelType.whatsapp);
    adapter = AlertDeliveryAdapter((typeName) => typeName == 'whatsapp' ? channel : null);
  });

  group('AlertDeliveryAdapter.deliver()', () {
    test('calls sendMessage with correct recipientJid and response', () async {
      const target = AlertTarget(channel: 'whatsapp', recipient: '+1234567890');
      const response = ChannelResponse(text: 'Alert: guard blocked');

      await adapter.deliver(target, response);

      expect(channel.sentMessages, hasLength(1));
      final (jid, sent) = channel.sentMessages.first;
      expect(jid, '+1234567890');
      expect(sent.text, 'Alert: guard blocked');
    });

    test('unknown channel type logs warning and does not throw', () async {
      const target = AlertTarget(channel: 'unknown_channel', recipient: '+1234');
      const response = ChannelResponse(text: 'test');

      await expectLater(adapter.deliver(target, response), completes);
      expect(channel.sentMessages, isEmpty);
    });

    test('sendMessage exception is caught and does not propagate', () async {
      channel.throwOnSend = true;
      const target = AlertTarget(channel: 'whatsapp', recipient: '+1234');
      const response = ChannelResponse(text: 'test');

      await expectLater(adapter.deliver(target, response), completes);
    });

    test('multiple delivers to same channel each call sendMessage', () async {
      const target1 = AlertTarget(channel: 'whatsapp', recipient: '+1111');
      const target2 = AlertTarget(channel: 'whatsapp', recipient: '+2222');
      const response = ChannelResponse(text: 'alert');

      await adapter.deliver(target1, response);
      await adapter.deliver(target2, response);

      expect(channel.sentMessages, hasLength(2));
      expect(channel.sentMessages[0].$1, '+1111');
      expect(channel.sentMessages[1].$1, '+2222');
    });
  });
}
