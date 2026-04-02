import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

/// Wraps [FakeTurnManager] so timeout cancellation can iterate a stable snapshot.
class _RestartFakeTurnManager extends FakeTurnManager {
  _RestartFakeTurnManager({super.activeSessionIds, super.waitDelay});

  @override
  Iterable<String> get activeSessionIds => List<String>.of(super.activeSessionIds);
}

void main() {
  group('RestartService', () {
    test('restart drains active turns (wait-first) then exits', () async {
      // Turns with no wait delay complete immediately — should NOT be cancelled.
      final turns = _RestartFakeTurnManager(activeSessionIds: const ['s1', 's2']);
      var exitCode = -1;

      final service = RestartService(turns: turns, exit: (code) => exitCode = code);

      await service.restart();

      // Turns completed naturally within deadline — no force-cancel.
      expect(turns.cancelledSessionIds, isEmpty);
      expect(exitCode, 0);
    });

    test('restart broadcasts SSE event before drain', () async {
      final turns = _RestartFakeTurnManager(activeSessionIds: const ['s1']);
      final events = <String>[];

      final service = RestartService(turns: turns, exit: (_) {}, broadcastSse: (event, data) => events.add(event));

      await service.restart();

      expect(events, ['server_restart']);
      // Turn completed naturally — no force-cancel.
      expect(turns.cancelledSessionIds, isEmpty);
    });

    test('restart writes restart.pending marker', () async {
      final turns = _RestartFakeTurnManager();
      String? writtenDir;
      List<String>? writtenFields;

      final service = RestartService(
        turns: turns,
        exit: (_) {},
        writeRestartPending: (dir, fields) {
          writtenDir = dir;
          writtenFields = fields;
        },
        dataDir: '/tmp/test-data',
      );

      await service.restart(pendingFields: ['agent.model', 'port']);

      expect(writtenDir, '/tmp/test-data');
      expect(writtenFields, ['agent.model', 'port']);
    });

    test('restart with no active turns exits immediately', () async {
      final turns = _RestartFakeTurnManager();
      var exitCode = -1;

      final service = RestartService(turns: turns, exit: (code) => exitCode = code);

      await service.restart();

      expect(turns.cancelledSessionIds, isEmpty);
      expect(exitCode, 0);
    });

    test('drain timeout force-cancels remaining turns then exits', () async {
      // waitDelay > drainDeadline → timeout fires, remaining turns are cancelled.
      final turns = _RestartFakeTurnManager(activeSessionIds: const ['s1'], waitDelay: const Duration(seconds: 5));
      var exitCode = -1;

      final service = RestartService(
        turns: turns,
        drainDeadline: const Duration(milliseconds: 100),
        exit: (code) => exitCode = code,
      );

      await service.restart();

      // Turn didn't finish in time — should be force-cancelled.
      expect(turns.cancelledSessionIds, contains('s1'));
      expect(exitCode, 0);
    });

    test('double restart throws StateError', () async {
      final turns = _RestartFakeTurnManager();
      var exitCalled = false;

      final service = RestartService(turns: turns, exit: (_) => exitCalled = true);

      await service.restart();
      expect(exitCalled, isTrue);

      expect(() => service.restart(), throwsStateError);
    });

    test('isRestarting flag set during restart', () async {
      final turns = _RestartFakeTurnManager();

      final service = RestartService(turns: turns, exit: (_) {});

      expect(service.isRestarting, isFalse);

      await service.restart();

      expect(service.isRestarting, isTrue);
    });
  });
}
