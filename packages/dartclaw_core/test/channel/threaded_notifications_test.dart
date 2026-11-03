import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeChannel, FakeChannelManager, FakeThreadedNotifications;
import 'package:test/test.dart';

void main() {
  group('ChannelManager.threadedNotificationsFor', () {
    late FakeChannelManager manager;
    late FakeThreadedNotifications googleChatDeclaration;
    late FakeThreadedNotifications slackDeclaration;

    setUp(() {
      googleChatDeclaration = FakeThreadedNotifications();
      slackDeclaration = FakeThreadedNotifications();
      manager = FakeChannelManager()
        ..registerChannel(
          FakeChannel(name: 'gchat', type: ChannelType.googlechat, threadedNotifications: googleChatDeclaration),
        )
        ..registerChannel(FakeChannel(name: 'slack', type: ChannelType.slack, threadedNotifications: slackDeclaration))
        ..registerChannel(FakeChannel(name: 'wa', type: ChannelType.whatsapp));
    });

    test('answers each registered channel type with its own declaration', () {
      expect(manager.threadedNotificationsFor('googlechat'), same(googleChatDeclaration));
      expect(manager.threadedNotificationsFor('slack'), same(slackDeclaration));
    });

    test('answers null for a registered channel that declares nothing', () {
      expect(manager.threadedNotificationsFor('whatsapp'), isNull);
    });

    test('answers null for a channel type that is not registered', () {
      expect(manager.threadedNotificationsFor('signal'), isNull);
      expect(manager.threadedNotificationsFor('no-such-channel'), isNull);
    });

    test('answers from the registration at the time of the call, not from construction', () {
      final late = FakeThreadedNotifications();
      expect(manager.threadedNotificationsFor('signal'), isNull);

      manager.registerChannel(FakeChannel(name: 'sig', type: ChannelType.signal, threadedNotifications: late));

      expect(manager.threadedNotificationsFor('signal'), same(late));
    });
  });
}
