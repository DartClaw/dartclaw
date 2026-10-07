import 'package:dartclaw_core/dartclaw_core.dart' show ChannelNotification, ChannelNotificationKind;
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

    test('declares no thread capability unless it is handed one', () {
      final declared = FakeThreadedNotifications();

      expect(FakeChannel().threadedNotifications, isNull);
      expect(FakeChannel(threadedNotifications: declared).threadedNotifications, same(declared));
    });
  });

  group('FakeThreadedNotifications', () {
    test('reads a thread from its metadata key and renders a marker card beside the text', () {
      final fake = FakeThreadedNotifications(threadMetadataKey: 'threadName');
      const notification = ChannelNotification(
        kind: ChannelNotificationKind.run,
        id: 'run-1',
        text: 'started',
        title: 'code-review',
        status: 'started',
      );

      final response = fake.render(notification);

      expect(fake.extractThread({'threadName': 'T1'}), 'T1');
      expect(fake.extractThread({'threadName': ''}), isNull);
      expect(fake.extractThread({'other': 'T1'}), isNull);
      expect(response.text, 'started');
      expect(response.structuredPayload, {'fakeCard': 'code-review'});
      expect(fake.rendered, [notification]);
    });

    test('records new-thread and existing-thread sends with the post each answered', () async {
      final fake = FakeThreadedNotifications();
      const response = ChannelResponse(text: 'hello');

      final opened = await fake.sendToNewThread('C1', response, threadKey: 'run-1');
      final reused = await fake.sendToThread('C1', response, threadId: opened!.threadId);

      expect(reused!.threadId, opened.threadId);
      expect(fake.sends.map((s) => (s.recipientId, s.threadKey, s.threadId)), [
        ('C1', 'run-1', null),
        ('C1', null, opened.threadId),
      ]);
      expect(fake.sends.map((s) => s.post), [opened, reused]);
    });

    test('scripted failures answer null or throw, and still record the attempt', () async {
      final fake = FakeThreadedNotifications()
        ..newThreadReturnsNull = true
        ..existingThreadReturnsNull = true;
      const response = ChannelResponse(text: 'hello');

      expect(await fake.sendToNewThread('C1', response, threadKey: 'k'), isNull);
      expect(await fake.sendToThread('C1', response, threadId: 'T'), isNull);

      fake.sendError = StateError('disconnected');
      await expectLater(fake.sendToNewThread('C1', response, threadKey: 'k'), throwsStateError);
      await expectLater(fake.sendToThread('C1', response, threadId: 'T'), throwsStateError);
      expect(fake.sends, hasLength(4));
    });
  });
}
