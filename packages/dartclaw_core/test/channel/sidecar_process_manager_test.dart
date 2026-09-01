import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeProcess;
import 'package:logging/logging.dart';
import 'package:test/test.dart';

/// Minimal adopter that records what the base hands to the scheduling seam
/// instead of restarting, so the restart *decision* is observable on its own.
class _RecordingSidecar extends SidecarProcessManager {
  new({super.maxRestartAttempts = 5, super.platformCapabilities})
    : super(
        label: 'test-sidecar',
        log: Logger('TestSidecar'),
        executable: 'test-sidecar',
        host: '127.0.0.1',
        port: 1234,
        delay: _noDelay,
      );

  final List<({Duration backoff, int generation})> scheduled = [];

  @override
  void scheduleRestart(Duration backoff, int generation) => scheduled.add((backoff: backoff, generation: generation));

  @override
  Future<bool> defaultStartupProbe(int attempt) async => true;

  @override
  bool get isRunning => process != null && !stopRequested;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async => stopRequested = true;

  @override
  Future<void> reset() async {}

  void watchExitOf(Process p, int atGeneration) {
    process = p;
    attachProcess(p, atGeneration);
  }

  void markIntentionalTeardown(Process p) => beginIntentionalProcessTeardown(p);

  set currentGeneration(int value) => generation = value;

  set attempts(int value) => restartCount = value;
}

Future<void> _noDelay(Duration duration) async {}

void main() {
  group('SidecarProcessManager restart decision', () {
    late _RecordingSidecar manager;

    setUp(() {
      manager = _RecordingSidecar()..currentGeneration = 3;
    });

    test('an unexpected exit at the current generation schedules exactly one backed-off restart', () async {
      final proc = FakeProcess();
      manager.watchExitOf(proc, 3);

      proc.exit(1);
      await pumpEventQueue();

      expect(manager.scheduled, [(backoff: const Duration(seconds: 2), generation: 3)]);
      expect(manager.restartCount, 1);
      expect(manager.isRunning, isFalse, reason: 'the exit released ownership of the process');
    });

    test('backoff doubles per attempt and saturates at 30s', () async {
      for (final (attemptsBefore, expected) in [(1, 4), (2, 8), (3, 16), (4, 30), (9, 30)]) {
        final mgr = _RecordingSidecar(maxRestartAttempts: 100)
          ..currentGeneration = 3
          ..attempts = attemptsBefore;
        final proc = FakeProcess();
        mgr.watchExitOf(proc, 3);

        proc.exit(1);
        await pumpEventQueue();

        expect(mgr.scheduled.single.backoff, Duration(seconds: expected));
        expect(mgr.restartCount, attemptsBefore + 1);
      }
    });

    test('an exit carrying a stale generation schedules nothing', () async {
      final proc = FakeProcess();
      manager.watchExitOf(proc, 2);

      proc.exit(1);
      await pumpEventQueue();

      expect(manager.scheduled, isEmpty);
      expect(manager.restartCount, 0);
    });

    test('an exit after stop schedules nothing', () async {
      final proc = FakeProcess();
      manager.watchExitOf(proc, 3);
      await manager.stop();

      proc.exit(1);
      await pumpEventQueue();

      expect(manager.scheduled, isEmpty);
      expect(manager.restartCount, 0);
    });

    test('an exit observed while an intentional teardown is pending schedules nothing', () async {
      final windows = _RecordingSidecar(platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'))
        ..currentGeneration = 3;
      final proc = FakeProcess();
      windows.watchExitOf(proc, 3);
      windows.markIntentionalTeardown(proc);

      proc.exit(1);
      await pumpEventQueue();

      expect(windows.scheduled, isEmpty);
      expect(windows.restartCount, 0);
    });

    test('an exit once the attempt cap is reached schedules nothing', () async {
      manager.attempts = 5;
      final proc = FakeProcess();
      manager.watchExitOf(proc, 3);

      proc.exit(1);
      await pumpEventQueue();

      expect(manager.scheduled, isEmpty);
      expect(manager.restartCount, 5);
    });
  });
}
