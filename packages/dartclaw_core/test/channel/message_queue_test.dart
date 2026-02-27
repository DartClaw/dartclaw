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

ChannelMessage _msg({String sender = 'user@test', String text = 'hello', String? groupJid}) {
  return ChannelMessage(channelType: ChannelType.whatsapp, senderJid: sender, text: text, groupJid: groupJid);
}

void main() {
  group('MessageQueue', () {
    late FakeChannel channel;
    late List<(String, String)> dispatched;
    late Completer<void>? dispatchGate;

    setUp(() {
      channel = FakeChannel();
      dispatched = [];
      dispatchGate = null;
    });

    MessageQueue makeQueue({
      Duration debounce = const Duration(milliseconds: 50),
      int maxConcurrent = 3,
      int maxDepth = 100,
      int maxRetries = 3,
      bool Function()? shouldFail,
    }) {
      return MessageQueue(
        debounceWindow: debounce,
        maxConcurrentTurns: maxConcurrent,
        maxQueueDepth: maxDepth,
        defaultRetryPolicy: RetryPolicy(maxAttempts: maxRetries, baseDelay: const Duration(milliseconds: 10)),
        random: Random(42), // deterministic
        dispatcher: (sessionKey, message, {String? senderJid}) async {
          if (dispatchGate != null) await dispatchGate!.future;
          if (shouldFail != null && shouldFail()) throw Exception('dispatch failed');
          dispatched.add((sessionKey, message));
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
        dispatcher: (sessionKey, message, {String? senderJid}) async {
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
        dispatcher: (sessionKey, message, {String? senderJid}) async {
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
        dispatcher: (sessionKey, message, {String? senderJid}) async {
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
        dispatcher: (sessionKey, message, {String? senderJid}) async {
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

    test('dispose cancels timers', () async {
      final queue = makeQueue(debounce: const Duration(seconds: 10));

      queue.enqueue(_msg(text: 'pending'), channel, 'session-1');
      queue.dispose();

      // Should not dispatch after dispose
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(dispatched, isEmpty);
    });
  });
}
