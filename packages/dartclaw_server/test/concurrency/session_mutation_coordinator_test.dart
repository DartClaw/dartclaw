import 'dart:async';

import 'package:dartclaw_server/src/concurrency/session_mutation_coordinator.dart';
import 'package:test/test.dart';

void main() {
  group('SessionMutationCoordinator', () {
    test('idle session runs the operation and returns its value', () async {
      final coordinator = SessionMutationCoordinator();
      expect(await coordinator.run('s1', () async => 42), 42);
    });

    test('same-session operations run one at a time in arrival order', () async {
      final coordinator = SessionMutationCoordinator();
      final events = <String>[];
      final firstGate = Completer<void>();
      final secondGate = Completer<void>();

      final first = coordinator.run('s1', () async {
        events.add('first:start');
        await firstGate.future;
        events.add('first:end');
      });
      final second = coordinator.run('s1', () async {
        events.add('second:start');
        await secondGate.future;
        events.add('second:end');
      });
      final third = coordinator.run('s1', () async => events.add('third'));
      await pumpEventQueue();
      expect(events, ['first:start']);

      firstGate.complete();
      await pumpEventQueue();
      expect(events, [
        'first:start',
        'first:end',
        'second:start',
      ], reason: 'third must wait for second, not just first');

      secondGate.complete();
      await Future.wait([first, second, third]);
      expect(events, ['first:start', 'first:end', 'second:start', 'second:end', 'third']);
    });

    test('a throwing operation releases the chain and its error stays with its own caller', () async {
      final coordinator = SessionMutationCoordinator();
      var secondRan = false;
      final first = coordinator.run<void>('s1', () async => throw StateError('head failed'));
      final second = coordinator.run('s1', () async {
        secondRan = true;
        return 'ran';
      });

      await expectLater(first, throwsStateError);
      await pumpEventQueue();
      expect(secondRan, isTrue, reason: 'the chain must release when the head throws');
      expect(await second, 'ran');
    });

    test('sessions are independent chains', () async {
      final coordinator = SessionMutationCoordinator();
      final gate = Completer<void>();
      var otherRan = false;

      final blocked = coordinator.run('s1', () => gate.future);
      final other = coordinator.run('s2', () async => otherRan = true);
      await pumpEventQueue();
      expect(otherRan, isTrue);

      gate.complete();
      await Future.wait([blocked, other]);
    });
  });
}
