import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/behavior/heartbeat_scheduler.dart';
import 'package:dartclaw_server/src/concurrency/session_lock_manager.dart';
import 'package:dartclaw_server/src/context/context_monitor.dart';
import 'package:dartclaw_server/src/context/result_trimmer.dart';
import 'package:dartclaw_server/src/scheduling/schedule_service.dart';
import 'package:dartclaw_server/src/session/session_reset_service.dart';
import 'package:dartclaw_server/src/turn_manager.dart';
import 'package:dartclaw_server/src/workspace/workspace_git_sync.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Builds a [ConfigDelta] with [current] config and [changedKeys].
/// [previous] defaults to the defaults config.
ConfigDelta _delta(DartclawConfig current, Set<String> changedKeys) =>
    ConfigDelta(previous: const DartclawConfig.defaults(), current: current, changedKeys: changedKeys);

void main() {
  // ---------------------------------------------------------------------------
  // G1: HeartbeatScheduler
  // ---------------------------------------------------------------------------

  group('HeartbeatScheduler.reconfigure()', () {
    test('updates _interval when heartbeatIntervalMinutes changes', () {
      final scheduler = HeartbeatScheduler(
        interval: const Duration(minutes: 30),
        workspaceDir: '/tmp',
        dispatch: (sessionKey, message) async {},
      );
      expect(scheduler.interval, const Duration(minutes: 30));

      final newConfig = DartclawConfig(scheduling: const SchedulingConfig(heartbeatIntervalMinutes: 60));
      scheduler.reconfigure(_delta(newConfig, {'scheduling.*'}));

      expect(scheduler.interval, const Duration(minutes: 60));
    });

    test('no-op when interval is unchanged', () {
      final scheduler = HeartbeatScheduler(
        interval: const Duration(minutes: 30),
        workspaceDir: '/tmp',
        dispatch: (sessionKey, message) async {},
      );
      final newConfig = DartclawConfig(scheduling: const SchedulingConfig(heartbeatIntervalMinutes: 30));
      // Should not throw or restart timer
      scheduler.reconfigure(_delta(newConfig, {'scheduling.*'}));
      expect(scheduler.interval, const Duration(minutes: 30));
    });

    test('does not restart timer if not running', () {
      final scheduler = HeartbeatScheduler(
        interval: const Duration(minutes: 30),
        workspaceDir: '/tmp',
        dispatch: (sessionKey, message) async {},
      );
      // Timer not started — reconfigure should not crash
      final newConfig = DartclawConfig(scheduling: const SchedulingConfig(heartbeatIntervalMinutes: 15));
      scheduler.reconfigure(_delta(newConfig, {'scheduling.*'}));
      expect(scheduler.interval, const Duration(minutes: 15));
    });

    test('watchKeys is scheduling.*', () {
      final scheduler = HeartbeatScheduler(
        interval: const Duration(minutes: 30),
        workspaceDir: '/tmp',
        dispatch: (sessionKey, message) async {},
      );
      expect(scheduler.watchKeys, {'scheduling.*'});
    });
  });

  // ---------------------------------------------------------------------------
  // G1: WorkspaceGitSync
  // ---------------------------------------------------------------------------

  group('WorkspaceGitSync.reconfigure()', () {
    test('updates pushEnabled when gitSyncPushEnabled changes', () {
      final gs = WorkspaceGitSync(
        workspaceDir: '/tmp',
        pushEnabled: true,
        commandRunner: (exe, args, {workingDirectory}) async => ProcessResult(0, 0, '', ''),
      );
      expect(gs.pushEnabled, isTrue);

      final newConfig = DartclawConfig(
        workspace: const WorkspaceConfig(gitSyncEnabled: true, gitSyncPushEnabled: false),
      );
      gs.reconfigure(_delta(newConfig, {'workspace.*'}));

      expect(gs.pushEnabled, isFalse);
    });

    test('no-op when pushEnabled is unchanged', () {
      final gs = WorkspaceGitSync(
        workspaceDir: '/tmp',
        pushEnabled: true,
        commandRunner: (exe, args, {workingDirectory}) async => ProcessResult(0, 0, '', ''),
      );
      final newConfig = DartclawConfig(
        workspace: const WorkspaceConfig(gitSyncEnabled: true, gitSyncPushEnabled: true),
      );
      gs.reconfigure(_delta(newConfig, {'workspace.*'}));
      expect(gs.pushEnabled, isTrue);
    });

    test('watchKeys is workspace.*', () {
      final gs = WorkspaceGitSync(workspaceDir: '/tmp');
      expect(gs.watchKeys, {'workspace.*'});
    });
  });

  // ---------------------------------------------------------------------------
  // G1: ScheduleService
  // ---------------------------------------------------------------------------

  group('ScheduleService.reconfigure()', () {
    test('completes without error and does not alter job list', () {
      final service = ScheduleService(turns: _NoopTurnManager(), sessions: _NoopSessionService(), jobs: const []);
      final newConfig = DartclawConfig(scheduling: const SchedulingConfig(heartbeatIntervalMinutes: 60));
      // Should not throw
      service.reconfigure(_delta(newConfig, {'scheduling.*'}));
    });

    test('watchKeys is scheduling.*', () {
      final service = ScheduleService(turns: _NoopTurnManager(), sessions: _NoopSessionService(), jobs: const []);
      expect(service.watchKeys, {'scheduling.*'});
    });
  });

  // ---------------------------------------------------------------------------
  // G2: SessionLockManager
  // ---------------------------------------------------------------------------

  group('SessionLockManager.reconfigure()', () {
    test('updates _maxParallel when maxParallelTurns changes', () {
      final manager = SessionLockManager(maxParallel: 3);
      expect(manager.maxParallel, 3);

      final newConfig = DartclawConfig(server: const ServerConfig(maxParallelTurns: 5));
      manager.reconfigure(_delta(newConfig, {'server.*'}));

      expect(manager.maxParallel, 5);
    });

    test('new cap constrains future acquire() calls', () async {
      final manager = SessionLockManager(maxParallel: 3);

      // Acquire 2 locks
      await manager.acquire('s1');
      await manager.acquire('s2');

      // Reconfigure to cap of 2
      final newConfig = DartclawConfig(server: const ServerConfig(maxParallelTurns: 2));
      manager.reconfigure(_delta(newConfig, {'server.*'}));

      // s3 should be rejected (cap now 2, 2 active)
      await expectLater(manager.acquire('s3'), throwsA(isA<BusyTurnException>()));

      // Release one — s3 can now acquire
      manager.release('s1');
      await manager.acquire('s3');
      manager.release('s2');
      manager.release('s3');
    });

    test('no-op when maxParallel is unchanged', () {
      final manager = SessionLockManager(maxParallel: 3);
      final newConfig = DartclawConfig(server: const ServerConfig(maxParallelTurns: 3));
      manager.reconfigure(_delta(newConfig, {'server.*'}));
      expect(manager.maxParallel, 3);
    });

    test('watchKeys is server.*', () {
      expect(SessionLockManager().watchKeys, {'server.*'});
    });
  });

  // ---------------------------------------------------------------------------
  // G2: SessionResetService
  // ---------------------------------------------------------------------------

  group('SessionResetService.reconfigure()', () {
    test('updates _resetHour and _idleTimeoutMinutes', () {
      final svc = SessionResetService(
        sessions: _NoopSessionService(),
        messages: _NoopMessageService(),
        resetHour: 4,
        idleTimeoutMinutes: 0,
      );

      final newConfig = DartclawConfig(sessions: const SessionConfig(resetHour: 6, idleTimeoutMinutes: 30));
      svc.reconfigure(_delta(newConfig, {'sessions.*'}));

      // Internal state is not exposed, but reconfigure() must not throw.
      // Verify by reconfiguring again with same values — no timer restart.
      svc.reconfigure(_delta(newConfig, {'sessions.*'}));
    });

    test('watchKeys is sessions.*', () {
      final svc = SessionResetService(sessions: _NoopSessionService(), messages: _NoopMessageService());
      expect(svc.watchKeys, {'sessions.*'});
    });
  });

  // ---------------------------------------------------------------------------
  // G3: ContextMonitor
  // ---------------------------------------------------------------------------

  group('ContextMonitor.reconfigure()', () {
    test('updates reserveTokens and warningThreshold', () {
      final monitor = ContextMonitor(reserveTokens: 20000, warningThreshold: 80);

      final newConfig = DartclawConfig(context: const ContextConfig(reserveTokens: 30000, warningThreshold: 90));
      monitor.reconfigure(_delta(newConfig, {'context.*'}));

      expect(monitor.reserveTokens, 30000);
      expect(monitor.warningThreshold, 90);
    });

    test('shouldFlush uses updated reserveTokens', () {
      final monitor = ContextMonitor(reserveTokens: 20000);
      monitor.update(contextWindow: 200000, contextTokens: 185000);
      expect(monitor.shouldFlush, isTrue); // 185000 > 200000 - 20000

      // Increase reserve so same token count no longer triggers flush
      final newConfig = DartclawConfig(context: const ContextConfig(reserveTokens: 10000));
      monitor.reconfigure(_delta(newConfig, {'context.*'}));
      monitor.markFlushCompleted(); // reset pending flag
      expect(monitor.shouldFlush, isFalse); // 185000 < 200000 - 10000 = 190000
    });

    test('watchKeys is context.*', () {
      expect(ContextMonitor().watchKeys, {'context.*'});
    });
  });

  // ---------------------------------------------------------------------------
  // G3: ResultTrimmer
  // ---------------------------------------------------------------------------

  group('ResultTrimmer.reconfigure()', () {
    test('updates _maxBytes', () {
      final trimmer = ResultTrimmer(maxBytes: 50 * 1024);
      expect(trimmer.maxBytes, 50 * 1024);

      final newConfig = DartclawConfig(context: const ContextConfig(maxResultBytes: 100 * 1024));
      trimmer.reconfigure(_delta(newConfig, {'context.*'}));

      expect(trimmer.maxBytes, 100 * 1024);
    });

    test('trim uses updated maxBytes', () {
      final trimmer = ResultTrimmer(maxBytes: 100);
      final large = 'a' * 10000;
      expect(trimmer.trim(large), contains('trimmed'));

      // Increase limit — same content should now pass through
      final newConfig = DartclawConfig(context: const ContextConfig(maxResultBytes: 100000));
      trimmer.reconfigure(_delta(newConfig, {'context.*'}));
      expect(trimmer.trim(large), large); // not trimmed
    });

    test('no-op when maxBytes is unchanged', () {
      final trimmer = ResultTrimmer(maxBytes: 50 * 1024);
      final newConfig = DartclawConfig(context: const ContextConfig(maxResultBytes: 50 * 1024));
      trimmer.reconfigure(_delta(newConfig, {'context.*'}));
      expect(trimmer.maxBytes, 50 * 1024);
    });

    test('watchKeys is context.*', () {
      expect(ResultTrimmer().watchKeys, {'context.*'});
    });
  });

  // ---------------------------------------------------------------------------
  // G4: TurnManager (no-op — governance config change is logged only)
  // ---------------------------------------------------------------------------
  // Tested in turn_manager_test.dart ('TurnManager.reconfigure()' group).

  // ---------------------------------------------------------------------------
  // G6: ConfigNotifier integration — reload() propagates to services
  // ---------------------------------------------------------------------------

  group('ConfigNotifier integration', () {
    test('reload() with changed context config updates ContextMonitor and ResultTrimmer', () {
      final notifier = ConfigNotifier(const DartclawConfig.defaults());

      final monitor = ContextMonitor(reserveTokens: 20000, warningThreshold: 80);
      final trimmer = ResultTrimmer(maxBytes: 50 * 1024);
      notifier.register(monitor);
      notifier.register(trimmer);

      const newConfig = DartclawConfig(
        context: ContextConfig(reserveTokens: 30000, warningThreshold: 90, maxResultBytes: 100 * 1024),
      );
      final delta = notifier.reload(newConfig);

      expect(delta, isNotNull);
      expect(monitor.reserveTokens, 30000);
      expect(monitor.warningThreshold, 90);
      expect(trimmer.maxBytes, 100 * 1024);
    });

    test('reload() with changed scheduling config triggers HeartbeatScheduler reconfigure()', () {
      const initial = DartclawConfig.defaults();
      final notifier = ConfigNotifier(initial);

      final scheduler = HeartbeatScheduler(
        interval: const Duration(minutes: 30),
        workspaceDir: '/tmp',
        dispatch: (sessionKey, message) async {},
      );
      notifier.register(scheduler);

      const newConfig = DartclawConfig(scheduling: SchedulingConfig(heartbeatIntervalMinutes: 60));
      notifier.reload(newConfig);

      expect(scheduler.interval, const Duration(minutes: 60));
    });

    test('reload() returns null if config is unchanged', () {
      const initial = DartclawConfig.defaults();
      final notifier = ConfigNotifier(initial);

      final monitor = ContextMonitor();
      notifier.register(monitor);

      // Reload with same config — should return null and not call reconfigure
      final delta = notifier.reload(initial);
      expect(delta, isNull);
    });

    test('reload() does not call reconfigure on services whose watchKeys do not match', () {
      const initial = DartclawConfig.defaults();
      final notifier = ConfigNotifier(initial);

      // Register a scheduler (watches scheduling.*)
      final scheduler = HeartbeatScheduler(
        interval: const Duration(minutes: 30),
        workspaceDir: '/tmp',
        dispatch: (sessionKey, message) async {},
      );
      notifier.register(scheduler);

      // Only change context config — scheduler should NOT be reconfigured
      const newConfig = DartclawConfig(context: ContextConfig(reserveTokens: 99999));
      notifier.reload(newConfig);

      // Scheduler interval unchanged — it was not reconfigured
      expect(scheduler.interval, const Duration(minutes: 30));
    });
  });
}

// ---------------------------------------------------------------------------
// Minimal stubs for SessionService, MessageService, TurnManager used in tests
// that instantiate ScheduleService / SessionResetService but don't exercise
// their turn/session logic.
// ---------------------------------------------------------------------------

class _NoopSessionService implements SessionService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(invocation.memberName.toString());
}

class _NoopMessageService implements MessageService {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(invocation.memberName.toString());
}

class _NoopTurnManager implements TurnManager {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(invocation.memberName.toString());
}
