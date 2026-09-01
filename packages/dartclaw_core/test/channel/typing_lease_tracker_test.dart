import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:fake_async/fake_async.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  group('TypingLeaseTracker', () {
    late List<(String, bool)> sent;
    late bool canSend;
    Completer<void>? nextGate;

    TypingLeaseTracker trackerWith({Duration? refreshInterval}) => TypingLeaseTracker(
      send: (String recipientId, {required bool isTyping}) async {
        sent.add((recipientId, isTyping));
        final gate = nextGate;
        nextGate = null;
        if (gate != null) await gate.future;
      },
      canSend: () => canSend,
      log: Logger('TypingLeaseTrackerTest'),
      refreshInterval: refreshInterval,
    );

    setUp(() {
      sent = [];
      canSend = true;
      nextGate = null;
    });

    test('overlapping turns for one recipient share a single START and STOP', () async {
      final tracker = trackerWith();

      await Future.wait([tracker.start('r'), tracker.start('r'), tracker.start('r')]);
      await tracker.stop('r');
      await tracker.stop('r');

      expect(sent, [('r', true)]);

      await tracker.stop('r');

      expect(sent, [('r', true), ('r', false)]);
    });

    test('a refresh interval re-sends START until the lease is released', () {
      fakeAsync((async) {
        final tracker = trackerWith(refreshInterval: const Duration(seconds: 10));

        unawaited(tracker.start('r'));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 25));
        async.flushMicrotasks();

        expect(sent, [('r', true), ('r', true), ('r', true)]);

        unawaited(tracker.stop('r'));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 25));
        async.flushMicrotasks();

        expect(sent, [('r', true), ('r', true), ('r', true), ('r', false)]);
      });
    });

    test('a stop landing while the first START is in flight leaves no orphan refresh', () {
      fakeAsync((async) {
        final tracker = trackerWith(refreshInterval: const Duration(seconds: 1));
        final startGate = Completer<void>();
        nextGate = startGate;

        unawaited(tracker.start('r'));
        async.flushMicrotasks();
        unawaited(tracker.stop('r'));
        async.flushMicrotasks();

        startGate.complete();
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 3));
        async.flushMicrotasks();

        expect(sent, [('r', true), ('r', false)]);
      });
    });

    test('a start on an unsendable channel emits nothing and takes no lease', () async {
      final tracker = trackerWith();
      canSend = false;

      await tracker.start('r');
      await tracker.start('r');

      expect(sent, isEmpty);

      canSend = true;
      await tracker.start('r');
      await tracker.stop('r');

      expect(sent, [('r', true), ('r', false)]);
    });

    test('a stop on an unsendable channel still releases the lease and cancels the refresh', () {
      fakeAsync((async) {
        final tracker = trackerWith(refreshInterval: const Duration(seconds: 1));

        unawaited(tracker.start('r'));
        async.flushMicrotasks();
        expect(sent, [('r', true)]);

        canSend = false;
        unawaited(tracker.stop('r'));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();

        expect(sent, [('r', true)]);

        canSend = true;
        unawaited(tracker.start('r'));
        async.flushMicrotasks();

        expect(sent, [('r', true), ('r', true)]);
      });
    });

    test('shutdown latches typing off until the tracker is resumed', () async {
      final tracker = trackerWith();

      await tracker.start('r');
      await tracker.shutdown();

      expect(sent, [('r', true), ('r', false)]);

      await tracker.start('r');

      expect(sent, [('r', true), ('r', false)]);

      tracker.resume();
      await tracker.start('r');

      expect(sent, [('r', true), ('r', false), ('r', true)]);
    });
  });
}
