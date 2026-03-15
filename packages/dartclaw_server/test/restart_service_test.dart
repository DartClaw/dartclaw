import 'dart:async';

import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

/// Minimal TurnManager fake for testing RestartService drain logic.
class _FakeTurnManager implements TurnManager {
  final List<String> _activeIds;
  final List<String> cancelledIds = [];
  final Duration? waitDelay;

  _FakeTurnManager({List<String> activeIds = const [], this.waitDelay}) : _activeIds = List.of(activeIds);

  @override
  Iterable<String> get activeSessionIds => _activeIds;

  @override
  Future<void> cancelTurn(String sessionId) async {
    cancelledIds.add(sessionId);
  }

  @override
  Future<void> waitForCompletion(String sessionId, {Duration timeout = const Duration(seconds: 10)}) async {
    final d = waitDelay;
    if (d != null) await Future<void>.delayed(d);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  group('RestartService', () {
    test('restart drains active turns (wait-first) then exits', () async {
      // Turns with no wait delay complete immediately — should NOT be cancelled.
      final turns = _FakeTurnManager(activeIds: ['s1', 's2']);
      var exitCode = -1;

      final service = RestartService(turns: turns, exit: (code) => exitCode = code);

      await service.restart();

      // Turns completed naturally within deadline — no force-cancel.
      expect(turns.cancelledIds, isEmpty);
      expect(exitCode, 0);
    });

    test('restart broadcasts SSE event before drain', () async {
      final turns = _FakeTurnManager(activeIds: ['s1']);
      final events = <String>[];

      final service = RestartService(turns: turns, exit: (_) {}, broadcastSse: (event, data) => events.add(event));

      await service.restart();

      expect(events, ['server_restart']);
      // Turn completed naturally — no force-cancel.
      expect(turns.cancelledIds, isEmpty);
    });

    test('restart writes restart.pending marker', () async {
      final turns = _FakeTurnManager();
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
      final turns = _FakeTurnManager();
      var exitCode = -1;

      final service = RestartService(turns: turns, exit: (code) => exitCode = code);

      await service.restart();

      expect(turns.cancelledIds, isEmpty);
      expect(exitCode, 0);
    });

    test('drain timeout force-cancels remaining turns then exits', () async {
      // waitDelay > drainDeadline → timeout fires, remaining turns are cancelled.
      final turns = _FakeTurnManager(activeIds: ['s1'], waitDelay: const Duration(seconds: 5));
      var exitCode = -1;

      final service = RestartService(
        turns: turns,
        drainDeadline: const Duration(milliseconds: 100),
        exit: (code) => exitCode = code,
      );

      await service.restart();

      // Turn didn't finish in time — should be force-cancelled.
      expect(turns.cancelledIds, contains('s1'));
      expect(exitCode, 0);
    });

    test('double restart throws StateError', () async {
      final turns = _FakeTurnManager();
      var exitCalled = false;

      final service = RestartService(turns: turns, exit: (_) => exitCalled = true);

      await service.restart();
      expect(exitCalled, isTrue);

      expect(() => service.restart(), throwsStateError);
    });

    test('isRestarting flag set during restart', () async {
      final turns = _FakeTurnManager();

      final service = RestartService(turns: turns, exit: (_) {});

      expect(service.isRestarting, isFalse);

      await service.restart();

      expect(service.isRestarting, isTrue);
    });
  });
}
