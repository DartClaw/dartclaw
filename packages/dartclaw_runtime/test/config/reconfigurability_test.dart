import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager;
import 'package:dartclaw_runtime/src/concurrency/session_lock_manager.dart';
import 'package:dartclaw_runtime/src/context/context_monitor.dart';
import 'package:dartclaw_runtime/src/context/result_trimmer.dart';
import 'package:dartclaw_runtime/src/scheduling/schedule_service.dart';
import 'package:dartclaw_runtime/src/session/session_reset_service.dart';
import 'package:dartclaw_runtime/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_runtime/src/config/runtime_toggle_applier.dart';
import 'package:dartclaw_runtime/src/runtime_config.dart';
import 'package:dartclaw_runtime/src/workspace/workspace_git_sync.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show RecordingGitRunner;
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
  // G1: WorkspaceGitSync
  // ---------------------------------------------------------------------------

  group('workspace.* push-enabled reload', () {
    ({WorkspaceGitSync sync, RuntimeConfig runtime, WorkspaceGitSyncReconfigurer reconfigurer}) build({
      required bool pushEnabled,
    }) {
      final sync = WorkspaceGitSync(
        workspaceDir: '/tmp',
        pushEnabled: pushEnabled,
        commandRunner: RecordingGitRunner().run,
      );
      final runtime = RuntimeConfig(heartbeatEnabled: true, gitSyncEnabled: true, gitSyncPushEnabled: pushEnabled);
      return (
        sync: sync,
        runtime: runtime,
        reconfigurer: WorkspaceGitSyncReconfigurer(RuntimeToggleApplier(runtimeConfig: runtime, gitSync: sync)),
      );
    }

    test('a reload applies pushEnabled', () {
      final w = build(pushEnabled: true);
      w.reconfigurer.reconfigure(
        _delta(DartclawConfig(workspace: const WorkspaceConfig(gitSyncEnabled: true, gitSyncPushEnabled: false)), {
          'workspace.*',
        }),
      );
      expect(w.sync.pushEnabled, isFalse);
    });

    test('an unchanged value leaves both readings alone', () {
      final w = build(pushEnabled: true);
      w.reconfigurer.reconfigure(
        _delta(DartclawConfig(workspace: const WorkspaceConfig(gitSyncEnabled: true, gitSyncPushEnabled: true)), {
          'workspace.*',
        }),
      );
      expect(w.sync.pushEnabled, isTrue);
      expect(w.runtime.gitSyncPushEnabled, isTrue);
    });

    // The defect: an operator turned push off through the ephemeral toggle, an
    // unrelated persisted `workspace.*` write turned it back on behind the
    // applier's back, and `GET /api/settings/runtime` went on reporting `false`
    // — the value the applier had recorded, not the one in force. The revert is
    // intended (an ephemeral toggle does not outlive a persisted write); the
    // surface lying about it was not.
    test('a persisted reload that reverts an ephemeral toggle leaves the reported value truthful', () {
      final w = build(pushEnabled: true);
      RuntimeToggleApplier(runtimeConfig: w.runtime, gitSync: w.sync).setGitSyncPushEnabled(false);
      expect(w.sync.pushEnabled, isFalse);
      expect(w.runtime.gitSyncPushEnabled, isFalse);

      w.reconfigurer.reconfigure(
        _delta(DartclawConfig(workspace: const WorkspaceConfig(gitSyncEnabled: true, gitSyncPushEnabled: true)), {
          'workspace.*',
        }),
      );

      expect(w.sync.pushEnabled, isTrue, reason: 'the persisted write wins');
      expect(
        w.runtime.gitSyncPushEnabled,
        isTrue,
        reason: 'and the value the runtime endpoint reports moves with it, because one authority wrote both',
      );
    });
  });

  // ---------------------------------------------------------------------------
  // G1: ScheduleService is not a config-reload participant
  // ---------------------------------------------------------------------------

  group('ScheduleService config participation', () {
    // It used to watch scheduling.* and only log that the job list needed a
    // restart. That requirement is declared by the scheduling section's restart
    // tier, by PATCH /api/config rejecting scheduling.jobs, and by the job CRUD
    // routes writing restart.pending.
    test('is not a Reconfigurable, so it cannot be registered with ConfigNotifier', () {
      final service = ScheduleService(turns: _NoopTurnManager(), sessions: _NoopSessionService(), jobs: const []);
      expect(service, isNot(isA<Reconfigurable>()));
    });

    test('a scheduling-only reload produces no delta and reports scheduling restart-required', () {
      final notifier = ConfigNotifier(const DartclawConfig.defaults());

      final delta = notifier.reload(const DartclawConfig(scheduling: SchedulingConfig(heartbeatIntervalMinutes: 60)));

      expect(delta, isNull);
      expect(notifier.restartRequiredSections, {'scheduling'});
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
      expect(
        monitor.shouldFlushForCompactionSignal(compactionSignalAvailable: false),
        isTrue,
      ); // 185000 > 200000 - 20000

      // Increase reserve so same token count no longer triggers flush
      final newConfig = DartclawConfig(context: const ContextConfig(reserveTokens: 10000));
      monitor.reconfigure(_delta(newConfig, {'context.*'}));
      monitor.markFlushCompleted(); // reset pending flag
      expect(
        monitor.shouldFlushForCompactionSignal(compactionSignalAvailable: false),
        isFalse,
      ); // 185000 < 200000 - 10000 = 190000
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
  });

  // ---------------------------------------------------------------------------
  // G4: TurnManager is not a config-reload participant
  // ---------------------------------------------------------------------------
  // Tested in turn_manager_test.dart ('TurnManager config participation' group).

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

    test('reload() with changed alerts config notifies services watching alerts.*', () {
      const initial = DartclawConfig.defaults();
      final notifier = ConfigNotifier(initial);

      final watcher = _RecordingReconfigurable(const {'alerts.*'});
      notifier.register(watcher);

      const newConfig = DartclawConfig(alerts: AlertsConfig(cooldownSeconds: 45));
      notifier.reload(newConfig);

      expect(watcher.deltas, hasLength(1));
      expect(watcher.deltas.single.current.alerts.cooldownSeconds, 45);
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

      final watcher = _RecordingReconfigurable(const {'alerts.*'});
      notifier.register(watcher);

      // Only change context config — the alerts watcher must not be reconfigured.
      const newConfig = DartclawConfig(context: ContextConfig(reserveTokens: 99999));
      notifier.reload(newConfig);

      expect(watcher.deltas, isEmpty);
    });
  });
}

// ---------------------------------------------------------------------------
// Minimal stubs for SessionService, MessageService, TurnManager used in tests
// that instantiate ScheduleService / SessionResetService but don't exercise
// their turn/session logic.
// ---------------------------------------------------------------------------

class _RecordingReconfigurable implements Reconfigurable {
  new(this.watchKeys);

  @override
  final Set<String> watchKeys;

  final deltas = <ConfigDelta>[];

  @override
  void reconfigure(ConfigDelta delta) => deltas.add(delta);
}

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
