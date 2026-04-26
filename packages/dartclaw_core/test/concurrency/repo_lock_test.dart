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

    test('reentrant within same zone: nested acquisition runs directly', () async {
      final lock = RepoLock();
      final events = <String>[];

      final result = await lock.acquire('/repo/.git', () async {
        events.add('outer-enter');
        final inner = await lock.acquire('/repo/.git', () {
          events.add('inner-run');
          return 42;
        });
        events.add('outer-exit');
        return inner;
      });

      expect(result, 42);
      expect(events, ['outer-enter', 'inner-run', 'outer-exit']);
    });

    test('reentrant nesting does not block contended sibling acquisition', () async {
      final lock = RepoLock();
      final gate = Completer<void>();
      final events = <String>[];

      final first = lock.acquire('/repo/.git', () async {
        events.add('first-outer-enter');
        await lock.acquire('/repo/.git', () {
          events.add('first-inner-run');
        });
        await gate.future;
        events.add('first-outer-exit');
      });
      final second = lock.acquire('/repo/.git', () {
        events.add('second-enter');
      });

      await Future<void>.delayed(Duration.zero);
      expect(events, ['first-outer-enter', 'first-inner-run']);

      gate.complete();
      await Future.wait([first, second]);

      expect(events, [
        'first-outer-enter',
        'first-inner-run',
        'first-outer-exit',
        'second-enter',
      ]);
    });
  });
}
