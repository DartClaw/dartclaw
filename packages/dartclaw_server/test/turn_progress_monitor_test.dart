import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';

void main() {
  group('TurnProgressMonitor', () {
    test('fires once the stall timeout elapses after start', () {
      fakeAsync((async) {
        final stalls = <Duration>[];
        final monitor = TurnProgressMonitor(stallTimeout: const Duration(seconds: 5), onStall: stalls.add);

        monitor.start();

        async.elapse(const Duration(seconds: 4));
        expect(stalls, isEmpty);

        async.elapse(const Duration(seconds: 1));
        expect(stalls, hasLength(1));
        expect(stalls.single, greaterThanOrEqualTo(const Duration(seconds: 5)));
      });
    });

    test('recordProgress resets the stall timer', () {
      fakeAsync((async) {
        final stalls = <Duration>[];
        final monitor = TurnProgressMonitor(stallTimeout: const Duration(seconds: 5), onStall: stalls.add);

        monitor.start();
        async.elapse(const Duration(seconds: 4));

        monitor.recordProgress();
        async.elapse(const Duration(seconds: 4));
        expect(stalls, isEmpty);

        async.elapse(const Duration(seconds: 1));
        expect(stalls, hasLength(1));
      });
    });

    test('stop cancels a pending stall timer', () {
      fakeAsync((async) {
        final stalls = <Duration>[];
        final monitor = TurnProgressMonitor(stallTimeout: const Duration(seconds: 5), onStall: stalls.add);

        monitor.start();
        async.elapse(const Duration(seconds: 2));
        monitor.stop();

        async.elapse(const Duration(seconds: 10));
        expect(stalls, isEmpty);
      });
    });

    test('can be restarted after stop', () {
      fakeAsync((async) {
        final stalls = <Duration>[];
        final monitor = TurnProgressMonitor(stallTimeout: const Duration(seconds: 5), onStall: stalls.add);

        monitor.start();
        async.elapse(const Duration(seconds: 2));
        monitor.stop();

        async.elapse(const Duration(seconds: 10));
        expect(stalls, isEmpty);

        monitor.start();
        async.elapse(const Duration(seconds: 5));
        expect(stalls, hasLength(1));
      });
    });
  });
}
