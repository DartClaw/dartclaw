import 'dart:async';
import 'dart:math';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

class FakeChannel extends Channel {
  @override
  final String name = 'fake';
  @override
  final ChannelType type = ChannelType.whatsapp;
  final List<(String, ChannelResponse)> sent = [];
  bool failSend = false;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  bool ownsJid(String jid) => true;

  @override
  Future<void> sendMessage(String recipientJid, ChannelResponse response) async {
    if (failSend) throw Exception('send failed');
    sent.add((recipientJid, response));
  }
}

enum _FakeQuoteReplyMode { native, sender }

class _FakeGoogleChatChannel extends Channel {
  _FakeGoogleChatChannel({required this.quoteReplyMode});

  final _FakeQuoteReplyMode quoteReplyMode;
  final List<(String spaceName, String text)> sentMessages = [];
  String? lastQuotedMessageName;
  String? lastQuotedMessageLastUpdateTime;

  @override
  final String name = 'googlechat';

  @override
  final ChannelType type = ChannelType.googlechat;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  bool ownsJid(String jid) => jid.startsWith('spaces/');

  @override
  Future<void> sendMessage(String recipientJid, ChannelResponse response) async {
    var text = response.text;
    final senderDisplayName = response.metadata['senderDisplayName'];
    if (quoteReplyMode == _FakeQuoteReplyMode.sender &&
        response.metadata['spaceType'] == 'SPACE' &&
        senderDisplayName is String) {
      text = '*@$senderDisplayName* – $text';
    }
    sentMessages.add((recipientJid, text));
    lastQuotedMessageName = response.metadata['messageName'] as String?;
    lastQuotedMessageLastUpdateTime = response.metadata['messageCreateTime'] as String?;
  }
}

ChannelMessage _msg({String sender = 'user@test', String text = 'hello', String? groupJid}) {
  return ChannelMessage(channelType: ChannelType.whatsapp, senderJid: sender, text: text, groupJid: groupJid);
}

void main() {
  group('MessageQueue', () {
    late FakeChannel channel;
    late List<(String, String)> dispatched;
    late List<String?> dispatchedSenders;
    late Completer<void>? dispatchGate;
    late Completer<void>? dispatchStarted;

    setUp(() {
      channel = FakeChannel();
      dispatched = [];
      dispatchedSenders = [];
      dispatchGate = null;
      dispatchStarted = null;
    });

    MessageQueue makeQueue({
      Duration debounce = const Duration(milliseconds: 50),
      int maxConcurrent = 3,
      int maxDepth = 100,
      int maxQueued = 0,
      int maxRetries = 3,
      QueueStrategy queueStrategy = QueueStrategy.fifo,
      bool Function(String senderId)? isAdmin,
      bool Function()? shouldFail,
    }) {
      return MessageQueue(
        debounceWindow: debounce,
        maxConcurrentTurns: maxConcurrent,
        maxQueueDepth: maxDepth,
        maxQueued: maxQueued,
        defaultRetryPolicy: RetryPolicy(maxAttempts: maxRetries, baseDelay: const Duration(milliseconds: 10)),
        queueStrategy: queueStrategy,
        random: Random(42), // deterministic
        isAdmin: isAdmin,
        dispatcher: (sessionKey, message, {String? senderJid, String? senderDisplayName}) async {
          if (dispatchStarted != null && !dispatchStarted!.isCompleted) {
            dispatchStarted!.complete();
          }
          if (dispatchGate != null) await dispatchGate!.future;
          if (shouldFail != null && shouldFail()) throw Exception('dispatch failed');
          dispatched.add((sessionKey, message));
          dispatchedSenders.add(senderJid);
          return 'response';
        },
      );
    }

    test('debounce coalesces messages within window', () async {
      final queue = makeQueue();
      addTearDown(queue.dispose);

      queue.enqueue(_msg(text: 'first'), channel, 'session-1');
      queue.enqueue(_msg(text: 'second'), channel, 'session-1');

      // Wait for debounce + dispatch
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(dispatched, hasLength(1));
      expect(dispatched.first.$2, 'first\nsecond'); // coalesced
    });

    test('debounce is per-sender-per-session', () async {
      final queue = makeQueue();
      addTearDown(queue.dispose);

      queue.enqueue(_msg(sender: 'alice@test', text: 'first'), channel, 'session-1');
      queue.enqueue(_msg(sender: 'bob@test', text: 'second'), channel, 'session-1');

      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(dispatched, hasLength(2));
      expect(dispatched.map((entry) => entry.$2), containsAll(['first', 'second']));
      expect(dispatchedSenders, containsAll(['alice@test', 'bob@test']));
    });

    test('messages beyond debounce window dispatch separately', () async {
      final queue = makeQueue(debounce: const Duration(milliseconds: 30));
      addTearDown(queue.dispose);

      queue.enqueue(_msg(text: 'first'), channel, 'session-1');
      await Future<void>.delayed(const Duration(milliseconds: 80)); // beyond window
      queue.enqueue(_msg(text: 'second'), channel, 'session-1');
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(dispatched, hasLength(2));
      expect(dispatched[0].$2, 'first');
      expect(dispatched[1].$2, 'second');
    });

    test('FIFO: same-session messages processed in order', () async {
      dispatchGate = Completer<void>();
      final queue = makeQueue(debounce: const Duration(milliseconds: 10));
      addTearDown(queue.dispose);

      // Enqueue first message
      queue.enqueue(_msg(text: 'msg-1'), channel, 'session-1');
      await Future<void>.delayed(const Duration(milliseconds: 30));

      // Enqueue second while first is processing
      queue.enqueue(_msg(text: 'msg-2'), channel, 'session-1');
      await Future<void>.delayed(const Duration(milliseconds: 30));

      // Release first
      dispatchGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(dispatched, hasLength(2));
      expect(dispatched[0].$2, 'msg-1');
      expect(dispatched[1].$2, 'msg-2');
    });

    test('global concurrency cap respected', () async {
      final gates = <Completer<void>>[];
      var activeCount = 0;
      var maxActive = 0;

      final queue = MessageQueue(
        debounceWindow: const Duration(milliseconds: 10),
        maxConcurrentTurns: 2,
        defaultRetryPolicy: const RetryPolicy(maxAttempts: 1),
        random: Random(42),
        dispatcher: (sessionKey, message, {String? senderJid, String? senderDisplayName}) async {
          activeCount++;
          if (activeCount > maxActive) maxActive = activeCount;
          final gate = Completer<void>();
          gates.add(gate);
          await gate.future;
          activeCount--;
          return 'ok';
        },
      );
      addTearDown(queue.dispose);

      // Enqueue 3 messages on different sessions
      queue.enqueue(_msg(text: 'a'), channel, 'session-a');
      queue.enqueue(_msg(text: 'b'), channel, 'session-b');
      queue.enqueue(_msg(text: 'c'), channel, 'session-c');

      await Future<void>.delayed(const Duration(milliseconds: 100));

      // Only 2 should be active (cap = 2)
      expect(maxActive, 2);

      // Release all
      for (final g in gates) {
        if (!g.isCompleted) g.complete();
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });

    test('retry on dispatch failure', () async {
      var failCount = 2;
      final queue = MessageQueue(
        debounceWindow: const Duration(milliseconds: 10),
        maxConcurrentTurns: 3,
        defaultRetryPolicy: const RetryPolicy(maxAttempts: 3, baseDelay: Duration(milliseconds: 10)),
        random: Random(42),
        dispatcher: (sessionKey, message, {String? senderJid, String? senderDisplayName}) async {
          if (failCount > 0) {
            failCount--;
            throw Exception('transient');
          }
          dispatched.add((sessionKey, message));
          return 'ok';
        },
      );
      addTearDown(queue.dispose);

      queue.enqueue(_msg(text: 'retry-me'), channel, 'session-1');
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(dispatched, hasLength(1));
      expect(dispatched.first.$2, 'retry-me');
    });

    test('dead-letter after max retries', () async {
      final queue = MessageQueue(
        debounceWindow: const Duration(milliseconds: 10),
        maxConcurrentTurns: 3,
        defaultRetryPolicy: const RetryPolicy(maxAttempts: 2, baseDelay: Duration(milliseconds: 10)),
        random: Random(42),
        dispatcher: (sessionKey, message, {String? senderJid, String? senderDisplayName}) async {
          throw Exception('permanent');
        },
      );
      addTearDown(queue.dispose);

      queue.enqueue(_msg(text: 'doomed'), channel, 'session-1');
      await Future<void>.delayed(const Duration(milliseconds: 500));

      expect(dispatched, isEmpty);
      // Channel should have received a dead-letter notification
      expect(channel.sent, isNotEmpty);
      expect(channel.sent.last.$2.text, contains('unable to process'));
    });

    test('queue full sends busy response', () async {
      dispatchGate = Completer<void>();
      final queue = MessageQueue(
        debounceWindow: const Duration(milliseconds: 5),
        maxConcurrentTurns: 3,
        maxQueueDepth: 1,
        defaultRetryPolicy: const RetryPolicy(maxAttempts: 1),
        random: Random(42),
        dispatcher: (sessionKey, message, {String? senderJid, String? senderDisplayName}) async {
          await dispatchGate!.future; // block processing
          dispatched.add((sessionKey, message));
          return 'ok';
        },
      );
      addTearDown(() {
        if (!dispatchGate!.isCompleted) dispatchGate!.complete();
        queue.dispose();
      });

      // First message: debounce flushes, enters queue, starts processing (blocked by gate)
      queue.enqueue(_msg(text: '1'), channel, 'session-1');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Second message: debounce flushes, enters queue (queue now at depth 1 = max)
      queue.enqueue(_msg(text: '2'), channel, 'session-1');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Third message: debounce flushes, queue full -> busy response
      queue.enqueue(_msg(text: '3'), channel, 'session-1');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final busyResponses = channel.sent.where((s) => s.$2.text.contains('busy'));
      expect(busyResponses, isNotEmpty);

      dispatchGate!.complete();
    });

    test('per-sender queue limit rejects only the overflowing sender', () async {
      dispatchGate = Completer<void>();
      final queue = makeQueue(maxQueued: 1, isAdmin: (_) => false, debounce: const Duration(milliseconds: 5));
      addTearDown(() {
        if (!dispatchGate!.isCompleted) dispatchGate!.complete();
        queue.dispose();
      });

      queue.enqueue(_msg(sender: 'alice@test', text: '1'), channel, 'session-1');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      queue.enqueue(_msg(sender: 'alice@test', text: '2'), channel, 'session-1');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      queue.enqueue(_msg(sender: 'alice@test', text: '3'), channel, 'session-1');
      queue.enqueue(_msg(sender: 'bob@test', text: '4'), channel, 'session-1');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final queueFullResponses = channel.sent.where((sent) => sent.$2.text.contains('Queue full'));
      expect(queueFullResponses, hasLength(1));

      dispatchGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(dispatched.map((entry) => entry.$2), containsAll(['1', '2', '4']));
    });

    test('admin senders are exempt from per-sender queue limits', () async {
      dispatchGate = Completer<void>();
      final queue = makeQueue(
        maxQueued: 1,
        debounce: const Duration(milliseconds: 5),
        isAdmin: (senderId) => senderId == 'admin@test',
      );
      addTearDown(() {
        if (!dispatchGate!.isCompleted) dispatchGate!.complete();
        queue.dispose();
      });

      queue.enqueue(_msg(sender: 'admin@test', text: '1'), channel, 'session-1');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      queue.enqueue(_msg(sender: 'admin@test', text: '2'), channel, 'session-1');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      queue.enqueue(_msg(sender: 'admin@test', text: '3'), channel, 'session-1');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(channel.sent.where((sent) => sent.$2.text.contains('Queue full')), isEmpty);

      dispatchGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(dispatched.map((entry) => entry.$2), containsAll(['1', '2', '3']));
    });

    test('fair strategy drains senders in round-robin order', () async {
      dispatchGate = Completer<void>();
      dispatchStarted = Completer<void>();
      final queue = makeQueue(queueStrategy: QueueStrategy.fair, debounce: const Duration(milliseconds: 5));
      addTearDown(() {
        if (!dispatchGate!.isCompleted) dispatchGate!.complete();
        queue.dispose();
      });

      Future<void> enqueueAndWait(String sender, String text) async {
        queue.enqueue(_msg(sender: sender, text: text), channel, 'session-1');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      await enqueueAndWait('alice@test', 'A-1');
      await dispatchStarted!.future;
      await enqueueAndWait('alice@test', 'A-2');
      await enqueueAndWait('alice@test', 'A-3');
      await enqueueAndWait('bob@test', 'B-1');
      await enqueueAndWait('bob@test', 'B-2');
      await enqueueAndWait('charlie@test', 'C-1');

      dispatchGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(dispatched.map((entry) => entry.$2).toList(), ['A-1', 'B-1', 'C-1', 'A-2', 'B-2', 'A-3']);
    });

    test('fair strategy includes late-arriving sender in the next rotation cycle', () async {
      dispatchGate = Completer<void>();
      dispatchStarted = Completer<void>();
      final queue = makeQueue(queueStrategy: QueueStrategy.fair, debounce: const Duration(milliseconds: 5));
      addTearDown(() {
        if (!dispatchGate!.isCompleted) dispatchGate!.complete();
        queue.dispose();
      });

      Future<void> enqueueAndWait(String sender, String text) async {
        queue.enqueue(_msg(sender: sender, text: text), channel, 'session-1');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      await enqueueAndWait('alice@test', 'A-1');
      await dispatchStarted!.future;
      await enqueueAndWait('alice@test', 'A-2');
      await enqueueAndWait('bob@test', 'B-1');
      await enqueueAndWait('dana@test', 'D-1');

      dispatchGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(dispatched.map((entry) => entry.$2).toList(), ['A-1', 'B-1', 'D-1', 'A-2']);
    });

    test('dispose cancels timers', () async {
      final queue = makeQueue(debounce: const Duration(seconds: 10));

      queue.enqueue(_msg(text: 'pending'), channel, 'session-1');
      queue.dispose();

      // Should not dispatch after dispose
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(dispatched, isEmpty);
    });

    test('replies to groupJid for group messages', () async {
      final queue = makeQueue();
      addTearDown(queue.dispose);

      queue.enqueue(_msg(sender: 'alice@test', groupJid: 'group@test'), channel, 'session-1');
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(channel.sent, hasLength(1));
      expect(channel.sent.single.$1, 'group@test');
    });

    test('prefers metadata spaceName as reply recipient', () async {
      final queue = makeQueue();
      addTearDown(queue.dispose);

      queue.enqueue(
        ChannelMessage(
          channelType: ChannelType.googlechat,
          senderJid: 'users/123',
          text: 'hello',
          metadata: const {'spaceName': 'spaces/AAAA'},
        ),
        channel,
        'session-1',
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(channel.sent, hasLength(1));
      expect(channel.sent.single.$1, 'spaces/AAAA');
    });

    test('preserves Google Chat quote metadata through the queued path', () async {
      final googleChatChannel = _FakeGoogleChatChannel(quoteReplyMode: _FakeQuoteReplyMode.native);
      final queue = makeQueue();
      addTearDown(queue.dispose);

      queue.enqueue(
        ChannelMessage(
          channelType: ChannelType.googlechat,
          senderJid: 'users/123',
          text: 'hello',
          metadata: const {
            'spaceName': 'spaces/AAAA',
            'messageName': 'spaces/AAAA/messages/source',
            'messageCreateTime': '2024-03-15T10:30:00.260127Z',
          },
        ),
        googleChatChannel,
        'session-1',
      );

      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(googleChatChannel.sentMessages, [('spaces/AAAA', 'response')]);
      expect(googleChatChannel.lastQuotedMessageName, 'spaces/AAAA/messages/source');
      expect(googleChatChannel.lastQuotedMessageLastUpdateTime, '2024-03-15T10:30:00.260127Z');
    });

    test('preserves senderDisplayName for sender attribution through the queued path', () async {
      final googleChatChannel = _FakeGoogleChatChannel(quoteReplyMode: _FakeQuoteReplyMode.sender);
      final queue = makeQueue();
      addTearDown(queue.dispose);

      queue.enqueue(
        ChannelMessage(
          channelType: ChannelType.googlechat,
          senderJid: 'users/123',
          text: 'hello',
          metadata: const {'spaceName': 'spaces/AAAA', 'spaceType': 'SPACE', 'senderDisplayName': 'Alice Smith'},
        ),
        googleChatChannel,
        'session-1',
      );

      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(googleChatChannel.sentMessages, hasLength(1));
      expect(googleChatChannel.sentMessages.single.$2, startsWith('*@Alice Smith* – '));
    });
  });
}
