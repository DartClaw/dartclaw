import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' show RepoLock;
import 'package:test/test.dart';

void main() {
  group('RepoLock', () {
    test('returns the action result after acquire/release', () async {
      final lock = RepoLock();

      final result = await lock.acquire('/repo/.git', () => 'ok');

      expect(result, 'ok');
    });

    test('serializes contended acquisitions for the same key', () async {
      final lock = RepoLock();
      final gate = Completer<void>();
      final events = <String>[];

      final first = lock.acquire('/repo/.git', () async {
        events.add('first-enter');
        await gate.future;
        events.add('first-exit');
      });
      final second = lock.acquire('/repo/.git', () {
        events.add('second-enter');
      });

      await Future<void>.delayed(Duration.zero);
      expect(events, ['first-enter']);

      gate.complete();
      await Future.wait([first, second]);

      expect(events, ['first-enter', 'first-exit', 'second-enter']);
    });

    test('rejects nested acquisition for the same key', () async {
      final lock = RepoLock();

      await expectLater(
        () => lock.acquire('/repo/.git', () => lock.acquire('/repo/.git', () {})),
        throwsA(anyOf(isA<AssertionError>(), isA<StateError>())),
      );
    });
  });
}
