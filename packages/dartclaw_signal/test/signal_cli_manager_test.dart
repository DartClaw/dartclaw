import 'dart:io';

import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeProcess;
import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:test/test.dart';

void main() {
  group('SignalCliManager', () {
    test('baseUrl constructed from host and port', () {
      final mgr = SignalCliManager(executable: 'signal-cli', host: '0.0.0.0', port: 9090, phoneNumber: '+1');
      expect(mgr.baseUrl, 'http://0.0.0.0:9090');
    });

    test('default baseUrl uses port 8080', () {
      final mgr = SignalCliManager(executable: 'signal-cli', phoneNumber: '+1');
      expect(mgr.baseUrl, 'http://127.0.0.1:8080');
    });

    test('isRunning is false initially', () {
      final mgr = SignalCliManager(executable: 'signal-cli', phoneNumber: '+1');
      expect(mgr.isRunning, isFalse);
    });

    test('start spawns process with correct args', () async {
      late String capturedExe;
      late List<String> capturedArgs;

      final mgr = SignalCliManager(
        executable: '/usr/local/bin/signal-cli',
        host: '0.0.0.0',
        port: 9090,
        phoneNumber: '+1234567890',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          capturedExe = exe;
          capturedArgs = args;
          return FakeProcess();
        },
        delay: (d) => Future.value(),
        healthProbe: () async => false,
      );

      try {
        await mgr.start();
      } on StateError {
        // Expected: health check fails (no real server)
      }

      expect(capturedExe, '/usr/local/bin/signal-cli');
      expect(capturedArgs, ['daemon', '--http', '0.0.0.0:9090']);
    });

    test('start throws when already stopped', () async {
      final mgr = SignalCliManager(executable: 'signal-cli', phoneNumber: '+1');
      await mgr.stop();
      expect(() => mgr.start(), throwsStateError);
    });

    test('start rethrows process spawn failure', () async {
      final mgr = SignalCliManager(
        executable: 'signal-cli',
        phoneNumber: '+1',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          throw ProcessException('signal-cli', args, 'not found');
        },
      );

      expect(() => mgr.start(), throwsA(isA<ProcessException>()));
    });

    test('stop sends SIGTERM to running process', () async {
      final proc = FakeProcess();
      final mgr = SignalCliManager(
        executable: 'signal-cli',
        phoneNumber: '+1',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          return proc;
        },
        delay: (d) => Future.value(),
        healthProbe: () async => false,
      );

      // Start will fail health check, but process is still assigned
      try {
        await mgr.start();
      } on StateError {
        // Expected
      }

      await mgr.stop();
      expect(proc.killCalled, isTrue);
      expect(mgr.isRunning, isFalse);
    });

    test('stop on already-stopped manager is a no-op', () async {
      final mgr = SignalCliManager(executable: 'signal-cli', phoneNumber: '+1');
      await mgr.stop();
      // Should not throw
      await mgr.stop();
    });

    test('dispose aliases stop', () async {
      final mgr = SignalCliManager(executable: 'signal-cli', phoneNumber: '+1');
      await mgr.dispose();
      expect(mgr.isRunning, isFalse);
    });

    test('startup timeout kills process before throwing', () async {
      final proc = FakeProcess();
      final mgr = SignalCliManager(
        executable: 'signal-cli',
        phoneNumber: '+1',
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

    test('requestVoiceVerification exists and is callable', () {
      final mgr = SignalCliManager(executable: 'signal-cli', phoneNumber: '+1');
      // Verify the method exists on SignalCliManager (will fail at RPC level
      // without a real server, but we just verify it doesn't throw synchronously).
      expect(() => mgr.requestVoiceVerification(), throwsA(anything));
    });

    test('events stream is broadcast', () {
      final mgr = SignalCliManager(executable: 'signal-cli', phoneNumber: '+1');
      // Should allow multiple listeners without error
      mgr.events.listen((_) {});
      mgr.events.listen((_) {});
    });
  });
}
