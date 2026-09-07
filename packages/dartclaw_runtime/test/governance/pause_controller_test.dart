import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide GoogleJwtVerifier, TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:test/test.dart';

void main() {
  group('PauseController', () {
    late PauseController controller;

    setUp(() {
      controller = PauseController();
    });

    // ---- Initial state ----

    test('starts unpaused', () {
      expect(controller.isPaused, isFalse);
      expect(controller.pausedBy, isNull);
      expect(controller.pausedAt, isNull);
      expect(controller.queueDepth, 0);
    });

    // ---- pause() ----

    test('pause() sets paused state and returns true', () {
      final result = controller.pause('alice');
      expect(result, isTrue);
      expect(controller.isPaused, isTrue);
      expect(controller.pausedBy, 'alice');
      expect(controller.pausedAt, isNotNull);
    });

    test('pause() is idempotent — returns false if already paused', () {
      controller.pause('alice');
      final secondResult = controller.pause('bob');
      expect(secondResult, isFalse);
      expect(controller.pausedBy, 'alice'); // state unchanged
    });

    // ---- enqueue() ----

    test('enqueue() queues a message and returns QueueResult.queued', () {
      controller.pause('alice');
      final msg = _msg(sender: 'user1@s.whatsapp.net', text: 'hello');
      final channel = _FakeChannel();
      final result = controller.enqueue(msg, channel, 'session:1');
      expect(result, QueueResult.queued);
      expect(controller.queueDepth, 1);
    });

    test('enqueue() returns QueueResult.full when at capacity', () {
      final smallController = PauseController(maxQueueSize: 2);
      smallController.pause('alice');
      final channel = _FakeChannel();
      final msg = _msg(sender: 'user@s.whatsapp.net', text: 'hi');

      expect(smallController.enqueue(msg, channel, 'session:1'), QueueResult.queued);
      expect(smallController.enqueue(msg, channel, 'session:2'), QueueResult.queued);
      expect(smallController.enqueue(msg, channel, 'session:3'), QueueResult.full);
      expect(smallController.queueDepth, 2);
    });

    test('enqueue() enforces per-sender pause queue limit', () {
      controller.pause('alice');
      final channel = _FakeChannel();

      expect(
        controller.enqueue(_msg(sender: 'user@s.whatsapp.net', text: '1'), channel, 'session:1', maxPauseQueued: 1),
        QueueResult.queued,
      );
      expect(
        controller.enqueue(_msg(sender: 'user@s.whatsapp.net', text: '2'), channel, 'session:1', maxPauseQueued: 1),
        QueueResult.full,
      );
      expect(
        controller.enqueue(_msg(sender: 'other@s.whatsapp.net', text: '3'), channel, 'session:1', maxPauseQueued: 1),
        QueueResult.queued,
      );
    });

    test('enqueue() exempts admin senders from per-sender pause queue limit', () {
      controller.pause('alice');
      final channel = _FakeChannel();

      expect(
        controller.enqueue(
          _msg(sender: 'admin@s.whatsapp.net', text: '1'),
          channel,
          'session:1',
          maxPauseQueued: 1,
          isAdmin: (senderId) => senderId == 'admin@s.whatsapp.net',
        ),
        QueueResult.queued,
      );
      expect(
        controller.enqueue(
          _msg(sender: 'admin@s.whatsapp.net', text: '2'),
          channel,
          'session:1',
          maxPauseQueued: 1,
          isAdmin: (senderId) => senderId == 'admin@s.whatsapp.net',
        ),
        QueueResult.queued,
      );
    });

    // ---- drain() ----

    test('drain() returns null when not paused', () {
      expect(controller.drain(), isNull);
    });

    test('drain() unpauses and clears queue', () {
      controller.pause('alice');
      final channel = _FakeChannel();
      controller.enqueue(_msg(sender: 'user@s.whatsapp.net', text: 'hi'), channel, 'session:1');
      controller.drain();
      expect(controller.isPaused, isFalse);
      expect(controller.queueDepth, 0);
      expect(controller.pausedBy, isNull);
      expect(controller.pausedAt, isNull);
    });

    test('drain() returns an empty list when queue is empty', () {
      controller.pause('alice');
      final result = controller.drain();
      expect(result, isNotNull);
      expect(result!.isEmpty, isTrue);
    });

    test('drain() collapses single sender — one line', () {
      controller.pause('alice');
      final channel = _FakeChannel();
      controller.enqueue(_msg(sender: 'bob@wa', text: 'msg1'), channel, 'sess:1');
      controller.enqueue(_msg(sender: 'bob@wa', text: 'msg2'), channel, 'sess:1');
      final result = controller.drain()!;
      expect(result.length, 1);
      final text = result.single.message.text;
      expect(result.single.sessionKey, 'sess:1');
      expect(result.single.channel, same(channel));
      expect(text, contains('1 participant'));
      expect(text, contains('- bob@wa: msg1, msg2'));
    });

    test('drain() collapses multiple senders — multi-line', () {
      controller.pause('alice');
      final channel = _FakeChannel();
      controller.enqueue(_msg(sender: 'alice@wa', text: 'hello', group: 'team'), channel, 'sess:1');
      controller.enqueue(_msg(sender: 'bob@wa', text: 'world', group: 'team'), channel, 'sess:1');
      final result = controller.drain()!;
      final text = result.single.message.text;
      expect(text, contains('2 participants'));
      expect(text, contains('- alice@wa: hello'));
      expect(text, contains('- bob@wa: world'));
    });

    test('drain() partitions messages by session key', () {
      controller.pause('alice');
      final channel = _FakeChannel();
      controller.enqueue(_msg(sender: 'alice@wa', text: 'msg-a'), channel, 'sess:1');
      controller.enqueue(_msg(sender: 'bob@wa', text: 'msg-b'), channel, 'sess:2');
      final result = controller.drain()!;
      expect(result.map((turn) => turn.sessionKey), containsAll(['sess:1', 'sess:2']));
      expect(result.singleWhere((turn) => turn.sessionKey == 'sess:1').message.text, contains('alice@wa'));
      expect(result.singleWhere((turn) => turn.sessionKey == 'sess:2').message.text, contains('bob@wa'));
    });

    test('drain() keeps different DM rows separate even when they share a session key', () {
      controller.pause('admin');
      final channel = _FakeChannel();
      controller.enqueue(_msg(sender: 'alice@wa', text: 'first'), channel, 'shared');
      controller.enqueue(_msg(sender: 'bob@wa', text: 'second'), channel, 'shared');

      final result = controller.drain()!;

      expect(result, hasLength(2));
      expect(result.map((turn) => turn.message.senderJid), unorderedEquals(['alice@wa', 'bob@wa']));
    });

    test('drain() preserves chronological sender order', () {
      controller.pause('admin');
      final channel = _FakeChannel();
      controller.enqueue(_msg(sender: 'charlie@wa', text: '1st', group: 'team'), channel, 's');
      controller.enqueue(_msg(sender: 'alpha@wa', text: '2nd', group: 'team'), channel, 's');
      controller.enqueue(_msg(sender: 'charlie@wa', text: '3rd', group: 'team'), channel, 's');
      final text = controller.drain()!.single.message.text;
      final charliePos = text.indexOf('charlie@wa');
      final alphaPos = text.indexOf('alpha@wa');
      expect(charliePos, lessThan(alphaPos));
    });

    // ---- Sender name extraction ----

    test('uses senderDisplayName metadata when available', () {
      controller.pause('admin');
      final channel = _FakeChannel();
      final msg = ChannelMessage(
        channelType: ChannelType.whatsapp,
        senderJid: '+1234567890',
        text: 'hello',
        metadata: const {'senderDisplayName': 'Alice'},
      );
      controller.enqueue(msg, channel, 'sess');
      final text = controller.drain()!.single.message.text;
      expect(text, contains('Alice'));
      expect(text, isNot(contains('+1234567890')));
    });

    test('falls back to pushname metadata when senderDisplayName not set', () {
      controller.pause('admin');
      final channel = _FakeChannel();
      final msg = ChannelMessage(
        channelType: ChannelType.whatsapp,
        senderJid: '+1234567890',
        text: 'hello',
        metadata: const {'pushname': 'WA Bob'},
      );
      controller.enqueue(msg, channel, 'sess');
      final text = controller.drain()!.single.message.text;
      expect(text, contains('WA Bob'));
    });

    test('falls back to senderJid when no display name metadata', () {
      controller.pause('admin');
      final channel = _FakeChannel();
      final msg = ChannelMessage(channelType: ChannelType.whatsapp, senderJid: '+1234567890', text: 'hello');
      controller.enqueue(msg, channel, 'sess');
      final text = controller.drain()!.single.message.text;
      expect(text, contains('+1234567890'));
    });

    // ---- reset() ----

    test('reset() clears all state without drain', () {
      controller.pause('alice');
      final channel = _FakeChannel();
      controller.enqueue(_msg(sender: 'user@wa', text: 'hi'), channel, 'sess:1');
      controller.reset();
      expect(controller.isPaused, isFalse);
      expect(controller.queueDepth, 0);
      expect(controller.pausedBy, isNull);
    });

    // ---- queueDepth ----

    test('queueDepth increments with each enqueue', () {
      controller.pause('admin');
      final channel = _FakeChannel();
      expect(controller.queueDepth, 0);
      controller.enqueue(_msg(sender: 'a@wa', text: '1'), channel, 's');
      expect(controller.queueDepth, 1);
      controller.enqueue(_msg(sender: 'a@wa', text: '2'), channel, 's');
      expect(controller.queueDepth, 2);
    });
  });
}

ChannelMessage _msg({required String sender, required String text, String? group}) {
  return ChannelMessage(channelType: ChannelType.whatsapp, senderJid: sender, groupJid: group, text: text);
}

class _FakeChannel extends Channel {
  @override
  final String name = 'fake';
  @override
  final ChannelType type = ChannelType.whatsapp;

  final List<(String, ChannelResponse)> sent = [];

  @override
  bool ownsJid(String jid) => true;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  Future<void> sendMessage(String recipientId, ChannelResponse response) async {
    sent.add((recipientId, response));
  }
}
