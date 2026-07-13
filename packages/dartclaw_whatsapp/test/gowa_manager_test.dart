import 'dart:async';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' show PlatformCapabilities;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeProcess;
import 'package:dartclaw_whatsapp/dartclaw_whatsapp.dart';
import 'package:test/test.dart';

void main() {
  group('GowaManager', () {
    test('start adopts healthy existing service without spawning', () async {
      var spawned = false;
      final mgr = GowaManager(
        executable: 'whatsapp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          spawned = true;
          return FakeProcess(completeExitOnKill: true);
        },
        healthProbe: () async => true,
      );

      await mgr.start();

      expect(spawned, isFalse);
      expect(mgr.isRunning, isTrue);

      await mgr.stop();
      expect(mgr.isRunning, isFalse);
    });

    test('start spawns process with correct args (rest subcommand, --db-uri, --webhook)', () async {
      late String capturedExe;
      late List<String> capturedArgs;

      final mgr = GowaManager(
        executable: '/usr/local/bin/whatsapp',
        host: '0.0.0.0',
        port: 5000,
        dbUri: '/data/wa.db',
        webhookUrl: 'http://localhost:3333/webhook/whatsapp?secret=abc',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          capturedExe = exe;
          capturedArgs = args;
          return FakeProcess(completeExitOnKill: true);
        },
        delay: (d) => Future.value(),
        healthProbe: () async => false,
      );

      try {
        await mgr.start();
      } on StateError {
        // Expected: health check fails (no real server)
      }

      expect(capturedExe, '/usr/local/bin/whatsapp');
      expect(capturedArgs, [
        'rest',
        '--host',
        '0.0.0.0',
        '--port',
        '5000',
        '--os',
        'DartClaw',
        '--db-uri',
        '/data/wa.db',
        '--webhook=http://localhost:3333/webhook/whatsapp?secret=abc',
      ]);
    });

    test('start without dbUri omits --db-uri flag', () async {
      late List<String> capturedArgs;

      final mgr = GowaManager(
        executable: 'whatsapp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          capturedArgs = args;
          return FakeProcess(completeExitOnKill: true);
        },
        delay: (d) => Future.value(),
        healthProbe: () async => false,
      );

      try {
        await mgr.start();
      } on StateError {
        // Expected: health check fails
      }

      expect(capturedArgs, contains('rest'));
      expect(capturedArgs, containsAllInOrder(['--host', '127.0.0.1', '--port', '3000']));
      expect(capturedArgs, isNot(contains('--db-uri')));
    });

    test('start without webhookUrl omits --webhook flag', () async {
      late List<String> capturedArgs;

      final mgr = GowaManager(
        executable: 'whatsapp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          capturedArgs = args;
          return FakeProcess(completeExitOnKill: true);
        },
        delay: (d) => Future.value(),
        healthProbe: () async => false,
      );

      try {
        await mgr.start();
      } on StateError {
        // Expected: health check fails
      }

      expect(capturedArgs, isNot(contains(startsWith('--webhook'))));
    });

    test('start throws when already stopped', () async {
      final mgr = GowaManager(executable: 'whatsapp');
      await mgr.stop(); // sets _stopped = true
      expect(() => mgr.start(), throwsStateError);
    });

    test('start rethrows process spawn failure', () async {
      final mgr = GowaManager(
        executable: 'whatsapp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          throw ProcessException('whatsapp', args, 'not found');
        },
      );

      expect(() => mgr.start(), throwsA(isA<ProcessException>()));
    });

    test('stop reaps the GOWA process', () async {
      final proc = FakeProcess(completeExitOnKill: true);
      var healthProbeCalls = 0;
      final mgr = GowaManager(
        executable: 'whatsapp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          return proc;
        },
        delay: (d) => Future.value(),
        healthProbe: () async => healthProbeCalls++ > 0,
      );

      await mgr.start();

      expect(proc.killCalled, isFalse);
      await mgr.stop();
      expect(proc.killCalled, isTrue);
      expect(await proc.exitCode, 0);
      expect(mgr.isRunning, isFalse);
    });

    test('stop waits for an in-flight start and reaps the spawned process', () async {
      final spawn = Completer<Process>();
      final proc = FakeProcess(completeExitOnKill: true);
      var healthProbeCalls = 0;
      final mgr = GowaManager(
        executable: 'whatsapp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) => spawn.future,
        healthProbe: () async => healthProbeCalls++ > 0,
      );

      final start = mgr.start();
      await pumpEventQueue(times: 1);
      final stop = mgr.stop();
      spawn.complete(proc);

      await expectLater(start, throwsStateError);
      await stop;
      expect(proc.killCalled, isTrue);
      expect(mgr.isRunning, isFalse);
    });

    test('stop on already-stopped manager is a no-op', () async {
      final mgr = GowaManager(executable: 'whatsapp');
      await mgr.stop();
      // Should not throw
      await mgr.stop();
    });

    test('dispose aliases stop', () async {
      final mgr = GowaManager(executable: 'whatsapp');
      await mgr.dispose();
      expect(mgr.isRunning, isFalse);
    });

    test('startup timeout kills process before throwing', () async {
      final proc = FakeProcess(completeExitOnKill: true);
      final mgr = GowaManager(
        executable: 'whatsapp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          return proc;
        },
        delay: (d) => Future.value(),
        healthProbe: () async => false,
      );

      expect(proc.killCalled, isFalse);
      await expectLater(() => mgr.start(), throwsStateError);
      expect(proc.killCalled, isTrue);
    });

    test('startup timeout escalates a POSIX child and releases confirmed ownership', () async {
      final proc = FakeProcess();
      final mgr = GowaManager(
        executable: 'whatsapp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async => proc,
        delay: (d) => Future.value(),
        healthProbe: () async => false,
        platformCapabilities: PlatformCapabilities(operatingSystem: 'linux'),
        terminationGracePeriod: Duration.zero,
      );

      final start = mgr.start();
      for (var i = 0; i < 10 && proc.killSignals.length < 2; i++) {
        await pumpEventQueue(times: 1);
      }
      expect(proc.killSignals, [ProcessSignal.sigterm, ProcessSignal.sigkill]);
      proc.exit(137);

      await expectLater(start, throwsStateError);
      expect(mgr.isRunning, isFalse);
    });

    test('startup timeout releases a confirmed Windows root', () async {
      final proc = FakeProcess(completeExitOnKill: true);
      final mgr = GowaManager(
        executable: 'whatsapp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async => proc,
        delay: (d) => Future.value(),
        healthProbe: () async => false,
        platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
        terminationGracePeriod: Duration.zero,
      );

      await expectLater(mgr.start(), throwsStateError);
      expect(proc.killSignals, [ProcessSignal.sigterm]);
      expect(mgr.isRunning, isFalse);

      await mgr.stop();
      expect(proc.killSignals, [ProcessSignal.sigterm]);
      expect(mgr.isRunning, isFalse);
      await mgr.stop();
      expect(proc.killSignals, [ProcessSignal.sigterm]);
    });

    test('reset does not restart the intentionally terminated process', () async {
      var spawnCount = 0;
      var healthProbeCalls = 0;
      final mgr = GowaManager(
        executable: 'whatsapp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          spawnCount++;
          return FakeProcess(completeExitOnKill: true);
        },
        delay: (_) async {},
        healthProbe: () async => (++healthProbeCalls).isEven,
      );

      await mgr.start();
      await mgr.reset();
      await pumpEventQueue(times: 20);

      expect(spawnCount, 1);
      expect(mgr.restartCount, 0);
    });

    test('queued reset releases the confirmed Windows root', () async {
      final spawn = Completer<Process>();
      final proc = FakeProcess(completeExitOnKill: true);
      var healthProbeCalls = 0;
      final mgr = GowaManager(
        executable: 'whatsapp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) => spawn.future,
        healthProbe: () async => (++healthProbeCalls).isEven,
        platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
        terminationGracePeriod: Duration.zero,
      );

      final start = mgr.start();
      await pumpEventQueue(times: 1);
      final reset = mgr.reset();
      spawn.complete(proc);

      await start;
      await reset;
      expect(mgr.isRunning, isFalse);
    });
  });
}
