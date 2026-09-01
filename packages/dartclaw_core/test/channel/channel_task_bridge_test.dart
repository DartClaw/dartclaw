import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeChannel;
import 'package:test/test.dart';

void main() {
  test('task-shaped text falls through to normal session routing', () async {
    final channel = FakeChannel(ownedJids: {'sender@s.whatsapp.net'});
    final bridge = ChannelTaskBridge();
    final message = ChannelMessage(
      channelType: ChannelType.whatsapp,
      senderJid: 'sender@s.whatsapp.net',
      text: 'task: fix login redirect',
    );

    final handled = await bridge.tryHandle(message, channel, sessionKey: 'agent:main:dm:whatsapp:sender');

    expect(handled, isFalse);
    expect(channel.sentMessages, isEmpty);
  });
}
