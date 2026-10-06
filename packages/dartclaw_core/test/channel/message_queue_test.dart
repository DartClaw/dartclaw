import 'dart:async';
import 'dart:math';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:fake_async/fake_async.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

class FakeChannel extends Channel {
  @override
  final String name = 'fake';
  @override
  ChannelType type = ChannelType.whatsapp;
  final List<(String, ChannelResponse)> sent = [];
  final List<String> typingEvents = [];
  bool failSend = false;

  /// Fails this many sends, then succeeds.
  int failNextSends = 0;
  int sendAttempts = 0;
  List<ChannelResponse> Function(String text)? formatter;
  bool failTyping = false;
  Completer<void>? startTypingGate;
  Completer<void>? stopTypingGate;

  @override
  Future<void> connect() async {}

  @override
  Future<void> disconnect() async {}

  @override
  bool ownsJid(String jid) => true;

  @override
  Future<void> sendMessage(String recipientJid, ChannelResponse response) async {
    sendAttempts++;
    if (failSend) throw Exception('send failed');
    if (failNextSends > 0) {
      failNextSends--;
      throw Exception('send failed');
    }
    typingEvents.add('send:$recipientJid');
    sent.add((recipientJid, response));
  }

  @override
  List<ChannelResponse> formatResponse(String text) => formatter?.call(text) ?? super.formatResponse(text);

  @override
  Future<void> startTyping(String recipientJid) async {
    typingEvents.add('start:$recipientJid');
    await startTypingGate?.future;
    if (failTyping) throw Exception('typing failed');
  }

  @override
  Future<void> stopTyping(String recipientJid) async {
    typingEvents.add('stop:$recipientJid');
    await stopTypingGate?.future;
    if (failTyping) throw Exception('typing failed');
  }
}

enum _FakeQuoteReplyMode { native, sender }

class _FakeGoogleChatChannel extends Channel {
  new({required this.quoteReplyMode});

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
    late List<({ChannelType channelType, String? groupJid})> dispatchedOrigins;
    late Completer<void>? dispatchGate;
    late Completer<void>? dispatchStarted;

    setUp(() {
      channel = FakeChannel();
      dispatched = [];
      dispatchedSenders = [];
      dispatchedOrigins = [];
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
      Duration retryDelay = const Duration(milliseconds: 10),
      String response = 'response',
      TurnObserver? turnObserver,
      MessageRedactor? redactor,
    }) {
      return MessageQueue(
        debounceWindow: debounce,
        maxConcurrentTurns: maxConcurrent,
        maxQueueDepth: maxDepth,
        maxQueued: maxQueued,
        defaultRetryPolicy: RetryPolicy(maxAttempts: maxRetries, baseDelay: retryDelay),
        queueStrategy: queueStrategy,
        random: Random(42), // deterministic
        isAdmin: isAdmin,
        turnObserver: turnObserver,
        redactor: redactor,
        dispatcher:
            (
              sessionKey,
              message, {
              required ChannelType channelType,
              String? senderJid,
              String? senderDisplayName,
              String? groupJid,
              String? recipientId,
              String? threadId,
            }) async {
              if (dispatchStarted != null && !dispatchStarted!.isCompleted) {
                dispatchStarted!.complete();
              }
              if (dispatchGate != null) await dispatchGate!.future;
              if (shouldFail != null && shouldFail()) throw Exception('dispatch failed');
              dispatched.add((sessionKey, message));
              dispatchedSenders.add(senderJid);
              dispatchedOrigins.add((channelType: channelType, groupJid: groupJid));
              return response;
            },
      );
    }

    test('dispatcher receives the source channel type and group JID', () async {
      // The channel a turn arrives on is what the prompt names, so the queue
      // must report the source channel rather than the message's own claim.
      channel.type = ChannelType.signal;
      final queue = makeQueue();
      addTearDown(queue.dispose);

      queue.enqueue(_msg(text: 'direct'), channel, 'session-dm');
      queue.enqueue(_msg(text: 'grouped', groupJid: 'group-1'), channel, 'session-group');

      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(dispatchedOrigins, hasLength(2));
      expect(dispatchedOrigins.every((origin) => origin.channelType == ChannelType.signal), isTrue);
      expect(dispatchedOrigins.map((origin) => origin.groupJid), containsAll([null, 'group-1']));
    });

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
        dispatcher:
            (
              sessionKey,
              message, {
              required ChannelType channelType,
              String? senderJid,
              String? senderDisplayName,
              String? groupJid,
              String? recipientId,
              String? threadId,
            }) async {
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

    test('dispatch failure sends one apology and never re-runs the turn', () async {
      var dispatchCalls = 0;
      final queue = MessageQueue(
        debounceWindow: Duration.zero,
        maxConcurrentTurns: 3,
        defaultRetryPolicy: const RetryPolicy(maxAttempts: 3, baseDelay: Duration.zero),
        random: Random(42),
        dispatcher:
            (
              sessionKey,
              message, {
              required ChannelType channelType,
              String? senderJid,
              String? senderDisplayName,
              String? groupJid,
              String? recipientId,
              String? threadId,
            }) async {
              dispatchCalls++;
              throw Exception('permanent');
            },
      );
      addTearDown(queue.dispose);

      queue.enqueue(_msg(text: 'doomed'), channel, 'session-1');
      await pumpEventQueue(times: 100);

      expect(dispatchCalls, 1);
      expect(channel.sendAttempts, 1);
      expect(channel.sent.single.$2.text, contains('unable to process'));
    });

    test('a failed reply send is retried per policy without re-running the turn', () async {
      channel.failNextSends = 2;
      var dispatchCalls = 0;
      final queue = MessageQueue(
        debounceWindow: Duration.zero,
        defaultRetryPolicy: const RetryPolicy(maxAttempts: 3, baseDelay: Duration.zero),
        random: Random(42),
        dispatcher:
            (
              sessionKey,
              message, {
              required ChannelType channelType,
              String? senderJid,
              String? senderDisplayName,
              String? groupJid,
              String? recipientId,
              String? threadId,
            }) async {
              dispatchCalls++;
              return 'the answer';
            },
      );
      addTearDown(queue.dispose);

      queue.enqueue(_msg(), channel, 'session-1');
      await pumpEventQueue(times: 100);

      expect(dispatchCalls, 1);
      expect(channel.sendAttempts, 3);
      expect(channel.sent.single.$2.text, 'the answer');
    });

    test('a reply that exhausts the policy is dead-lettered without re-running the turn or apologizing', () async {
      channel.failSend = true;
      final severe = <LogRecord>[];
      final sub = Logger('MessageQueue').onRecord.where((r) => r.level >= Level.SEVERE).listen(severe.add);
      addTearDown(sub.cancel);
      final queue = makeQueue(debounce: Duration.zero, maxRetries: 2, retryDelay: Duration.zero);
      addTearDown(queue.dispose);

      queue.enqueue(_msg(text: 'q'), channel, 'session-1');
      await pumpEventQueue(times: 100);

      expect(dispatched, hasLength(1));
      expect(channel.sendAttempts, 2);
      expect(channel.sent, isEmpty);
      expect(severe, hasLength(1));
      expect(severe.single.message, contains('Dead-letter'));
    });

    test('a dead-lettered reply stops its remaining chunks and frees the session for the next message', () async {
      channel.formatter = (text) => [ChannelResponse(text: '$text-1'), ChannelResponse(text: '$text-2')];
      channel.failNextSends = 2;
      final queue = makeQueue(debounce: Duration.zero, maxRetries: 2, retryDelay: Duration.zero);
      addTearDown(queue.dispose);

      queue.enqueue(_msg(text: 'first'), channel, 'session-1');
      await pumpEventQueue(times: 100);

      expect(channel.sendAttempts, 2, reason: 'chunk 1 exhausted its attempts; chunk 2 was never tried');
      expect(channel.sent, isEmpty);

      queue.enqueue(_msg(text: 'second'), channel, 'session-1');
      await pumpEventQueue(times: 100);

      expect(dispatched.map((d) => d.$2), ['first', 'second']);
      expect(channel.sent.map((s) => s.$2.text), ['response-1', 'response-2']);
    });

    test('the slot stays held while a reply send is backing off', () {
      fakeAsync((async) {
        channel.failNextSends = 1;
        final started = <String>[];
        final queue = MessageQueue(
          debounceWindow: Duration.zero,
          maxConcurrentTurns: 1,
          defaultRetryPolicy: const RetryPolicy(maxAttempts: 2, baseDelay: Duration(seconds: 10), jitterFactor: 0),
          random: Random(42),
          dispatcher:
              (
                sessionKey,
                message, {
                required ChannelType channelType,
                String? senderJid,
                String? senderDisplayName,
                String? groupJid,
                String? recipientId,
                String? threadId,
              }) async {
                started.add(message);
                return 'ok';
              },
        );

        queue.enqueue(_msg(text: 'a'), channel, 'session-a');
        queue.enqueue(_msg(text: 'b'), channel, 'session-b');
        async.elapse(const Duration(seconds: 5));
        expect(started, ['a'], reason: 'a is backing off its first failed send and still holds the only slot');

        async.elapse(const Duration(seconds: 10));
        expect(started, ['a', 'b']);
        expect(channel.sent.map((s) => s.$2.text), ['ok', 'ok']);
        queue.dispose();
      });
    });

    test('dispose during a reply-send backoff stops quietly', () {
      fakeAsync((async) {
        channel.failSend = true;
        final queue = makeQueue(debounce: Duration.zero, maxRetries: 3, retryDelay: const Duration(seconds: 10));

        queue.enqueue(_msg(), channel, 'session-1');
        async.elapse(const Duration(seconds: 5));
        expect(channel.sendAttempts, 1);

        queue.dispose();
        async.elapse(const Duration(minutes: 5));

        expect(channel.sendAttempts, 1);
        expect(dispatched, hasLength(1));
      });
    });

    test('queue full sends busy response', () async {
      dispatchGate = Completer<void>();
      final queue = MessageQueue(
        debounceWindow: const Duration(milliseconds: 5),
        maxConcurrentTurns: 3,
        maxQueueDepth: 1,
        defaultRetryPolicy: const RetryPolicy(maxAttempts: 1),
        random: Random(42),
        dispatcher:
            (
              sessionKey,
              message, {
              required ChannelType channelType,
              String? senderJid,
              String? senderDisplayName,
              String? groupJid,
              String? recipientId,
              String? threadId,
            }) async {
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

    test('shows typing only while the queued turn is running', () async {
      dispatchGate = Completer<void>();
      dispatchStarted = Completer<void>();
      final queue = makeQueue(debounce: Duration.zero);
      addTearDown(() {
        if (!dispatchGate!.isCompleted) dispatchGate!.complete();
        queue.dispose();
      });

      queue.enqueue(_msg(groupJid: 'group@test'), channel, 'session-1');
      await dispatchStarted!.future;

      expect(channel.typingEvents, ['start:group@test']);

      dispatchGate!.complete();
      await pumpEventQueue();

      expect(channel.typingEvents, ['start:group@test', 'stop:group@test', 'send:group@test']);
    });

    test('typing failures never block the response', () async {
      channel.failTyping = true;
      final queue = makeQueue(debounce: Duration.zero);
      addTearDown(queue.dispose);

      queue.enqueue(_msg(), channel, 'session-1');
      await pumpEventQueue();

      expect(channel.sent.single.$2.text, 'response');
      expect(channel.typingEvents, ['start:user@test', 'stop:user@test', 'send:user@test']);
    });

    test('stops typing before an observer suppresses the normal send', () async {
      String? observedResponse;
      final queue = makeQueue(
        debounce: Duration.zero,
        turnObserver: (sessionKey, message, sourceChannel, recipientJid, responseFuture) async {
          observedResponse = await responseFuture;
          return true;
        },
      );
      addTearDown(queue.dispose);

      queue.enqueue(_msg(), channel, 'session-1');
      await pumpEventQueue();

      expect(observedResponse, 'response');
      expect(channel.sent, isEmpty);
      expect(channel.typingEvents, ['start:user@test', 'stop:user@test']);
    });

    test('stops typing before sending a redacted response', () async {
      final queue = makeQueue(
        debounce: Duration.zero,
        response: 'SECRET-VALUE',
        redactor: MessageRedactor(extraPatterns: [r'SECRET-[A-Z]+']),
      );
      addTearDown(queue.dispose);

      queue.enqueue(_msg(), channel, 'session-1');
      await pumpEventQueue();

      expect(channel.sent.single.$2.text, 'SECRET***');
      expect(channel.typingEvents, ['start:user@test', 'stop:user@test', 'send:user@test']);
    });

    test('a reply-send retry does not restart typing', () async {
      channel.failNextSends = 1;
      final queue = makeQueue(debounce: Duration.zero, maxRetries: 2, retryDelay: Duration.zero);
      addTearDown(queue.dispose);

      queue.enqueue(_msg(), channel, 'session-1');
      await pumpEventQueue(times: 100);

      expect(dispatched, hasLength(1));
      expect(channel.sent.single.$2.text, 'response');
      expect(channel.typingEvents, ['start:user@test', 'stop:user@test', 'send:user@test']);
    });

    test('a stalled typing start cannot block dispatch', () {
      fakeAsync((async) {
        channel.startTypingGate = Completer<void>();
        final queue = makeQueue(debounce: Duration.zero);

        queue.enqueue(_msg(), channel, 'session-1');
        async.elapse(Duration.zero);
        async.flushMicrotasks();

        expect(dispatched, isEmpty);
        expect(channel.typingEvents, ['start:user@test']);

        async.elapse(const Duration(seconds: 3));
        async.flushMicrotasks();

        expect(dispatched, [('session-1', 'hello')]);
        expect(channel.typingEvents, ['start:user@test', 'stop:user@test', 'send:user@test']);
        queue.dispose();
      });
    });

    test('a stalled typing stop cannot block final delivery', () {
      fakeAsync((async) {
        channel.stopTypingGate = Completer<void>();
        final queue = makeQueue(debounce: Duration.zero);

        queue.enqueue(_msg(), channel, 'session-1');
        async.elapse(Duration.zero);
        async.flushMicrotasks();

        expect(channel.typingEvents, ['start:user@test', 'stop:user@test']);
        expect(channel.sent, isEmpty);

        async.elapse(const Duration(seconds: 3));
        async.flushMicrotasks();

        expect(channel.typingEvents, ['start:user@test', 'stop:user@test', 'send:user@test']);
        expect(channel.sent.single.$2.text, 'response');
        queue.dispose();
      });
    });

    test('stops typing when dispatch fails', () async {
      final queue = makeQueue(debounce: Duration.zero, maxRetries: 1, shouldFail: () => true);
      addTearDown(queue.dispose);

      queue.enqueue(_msg(), channel, 'session-1');
      await pumpEventQueue();

      expect(channel.typingEvents.take(2), ['start:user@test', 'stop:user@test']);
      expect(channel.sent.single.$2.text, contains('unable to process'));
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

  group('MessageQueue concurrency slots', () {
    late FakeChannel channel;
    late Map<String, Completer<void>> gates;
    late List<String> started;
    var inFlight = 0;
    var peakInFlight = 0;

    setUp(() {
      channel = FakeChannel();
      gates = {};
      started = [];
      inFlight = 0;
      peakInFlight = 0;
    });

    MessageQueue makeGatedQueue({required int maxConcurrent}) {
      return MessageQueue(
        debounceWindow: Duration.zero,
        maxConcurrentTurns: maxConcurrent,
        defaultRetryPolicy: const RetryPolicy(maxAttempts: 1),
        random: Random(42),
        dispatcher:
            (
              sessionKey,
              message, {
              required ChannelType channelType,
              String? senderJid,
              String? senderDisplayName,
              String? groupJid,
              String? recipientId,
              String? threadId,
            }) async {
              started.add(message);
              inFlight++;
              peakInFlight = max(peakInFlight, inFlight);
              try {
                await (gates[message] = Completer<void>()).future;
              } finally {
                inFlight--;
              }
              return 'ok';
            },
      );
    }

    void settle(FakeAsync async) {
      async.elapse(Duration.zero);
      async.flushMicrotasks();
    }

    void finish(FakeAsync async, String message) {
      gates[message]!.complete();
      settle(async);
    }

    test('a freed slot goes to the waiting session, not to the releasing session\'s next message', () {
      // The releasing session loops straight into its next queued message; the
      // slot has to be committed to the waiter at release or both run at once.
      fakeAsync((async) {
        final queue = makeGatedQueue(maxConcurrent: 1);
        queue.enqueue(_msg(text: 'a1'), channel, 'session-a');
        settle(async);
        queue.enqueue(_msg(text: 'b1'), channel, 'session-b');
        settle(async);
        queue.enqueue(_msg(text: 'a2'), channel, 'session-a');
        settle(async);
        expect(started, ['a1']);

        finish(async, 'a1');

        expect(started, ['a1', 'b1']);
        expect(peakInFlight, 1);

        finish(async, 'b1');

        expect(started, ['a1', 'b1', 'a2']);
        expect(peakInFlight, 1);
        queue.dispose();
      });
    });

    test('disposing while a session waits for a slot raises no uncaught error and never runs it', () {
      fakeAsync((async) {
        final queue = makeGatedQueue(maxConcurrent: 1);
        queue.enqueue(_msg(text: 'a'), channel, 'session-a');
        settle(async);
        queue.enqueue(_msg(text: 'b'), channel, 'session-b');
        settle(async);
        expect(started, ['a']);

        queue.dispose();
        async.flushMicrotasks();

        finish(async, 'a');
        expect(started, ['a']);
      });
    });

    test('raising the cap admits waiting sessions immediately, up to the new cap', () {
      fakeAsync((async) {
        final queue = makeGatedQueue(maxConcurrent: 1);
        for (final name in ['a', 'b', 'c']) {
          queue.enqueue(_msg(text: name), channel, 'session-$name');
          settle(async);
        }
        expect(started, ['a']);

        queue.maxConcurrentTurns = 2;
        async.flushMicrotasks();

        expect(started, ['a', 'b']);

        queue.maxConcurrentTurns = 3;
        async.flushMicrotasks();

        expect(started, ['a', 'b', 'c']);
        expect(peakInFlight, 3);
        queue.dispose();
      });
    });

    test('lowering the cap admits nothing new until in-flight turns drop below it', () {
      fakeAsync((async) {
        final queue = makeGatedQueue(maxConcurrent: 3);
        for (final name in ['a', 'b', 'c', 'd']) {
          queue.enqueue(_msg(text: name), channel, 'session-$name');
          settle(async);
        }
        expect(started, ['a', 'b', 'c']);

        queue.maxConcurrentTurns = 1;
        async.flushMicrotasks();
        expect(started, ['a', 'b', 'c']);

        finish(async, 'a');
        expect(started, ['a', 'b', 'c']);

        finish(async, 'b');
        expect(started, ['a', 'b', 'c']);

        finish(async, 'c');
        expect(started, ['a', 'b', 'c', 'd']);
        queue.dispose();
      });
    });
  });
}
