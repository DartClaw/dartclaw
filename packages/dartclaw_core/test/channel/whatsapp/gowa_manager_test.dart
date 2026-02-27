import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// FakeProcess — mirrors the test double from harness tests
// ---------------------------------------------------------------------------
class FakeProcess implements Process {
  final StreamController<List<int>> _stdoutCtrl = StreamController<List<int>>();
  final StreamController<List<int>> _stderrCtrl = StreamController<List<int>>();
  final Completer<int> _exitCodeCompleter = Completer<int>();

  bool killed = false;
  ProcessSignal? lastSignal;

  @override
  int get pid => 99;

  @override
  IOSink get stdin => _NullIOSink();

  @override
  Stream<List<int>> get stdout => _stdoutCtrl.stream;

  @override
  Stream<List<int>> get stderr => _stderrCtrl.stream;

  @override
  Future<int> get exitCode => _exitCodeCompleter.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    lastSignal = signal;
    if (!_exitCodeCompleter.isCompleted) _exitCodeCompleter.complete(0);
    return true;
  }

  void emitStdout(String line) => _stdoutCtrl.add(utf8.encode('$line\n'));
  void emitStderr(String line) => _stderrCtrl.add(utf8.encode('$line\n'));
  void exit(int code) {
    if (!_exitCodeCompleter.isCompleted) _exitCodeCompleter.complete(code);
  }
}

class _NullIOSink implements IOSink {
  @override
  Encoding get encoding => utf8;
  @override
  set encoding(Encoding value) {}
  @override
  void add(List<int> data) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) => Future.value();
  @override
  Future<void> close() => Future.value();
  @override
  Future<void> get done => Future.value();
  @override
  Future<void> flush() => Future.value();
  @override
  void write(Object? object) {}
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {}
  @override
  void writeCharCode(int charCode) {}
  @override
  void writeln([Object? object = '']) {}
}

void main() {
  group('GowaManager', () {
    test('baseUrl constructed from host and port', () {
      final mgr = GowaManager(executable: 'gowa', host: '0.0.0.0', port: 4000);
      expect(mgr.baseUrl, 'http://0.0.0.0:4000');
    });

    test('default baseUrl', () {
      final mgr = GowaManager(executable: 'gowa');
      expect(mgr.baseUrl, 'http://127.0.0.1:3080');
    });

    test('isRunning is false initially', () {
      final mgr = GowaManager(executable: 'gowa');
      expect(mgr.isRunning, isFalse);
    });

    test('start spawns process with correct args', () async {
      late String capturedExe;
      late List<String> capturedArgs;

      final mgr = GowaManager(
        executable: '/usr/local/bin/gowa',
        host: '0.0.0.0',
        port: 5000,
        dataDir: '/data',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          capturedExe = exe;
          capturedArgs = args;
          return FakeProcess();
        },
        // Health check will fail (no real server), so start() will throw.
        // We catch that to verify the process was spawned with correct args.
        delay: (d) => Future.value(),
      );

      try {
        await mgr.start();
      } on StateError {
        // Expected: health check fails
      }

      expect(capturedExe, '/usr/local/bin/gowa');
      expect(capturedArgs, ['--host', '0.0.0.0', '--port', '5000', '--data', '/data']);
    });

    test('start without dataDir omits --data flag', () async {
      late List<String> capturedArgs;

      final mgr = GowaManager(
        executable: 'gowa',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          capturedArgs = args;
          return FakeProcess();
        },
        delay: (d) => Future.value(),
      );

      try {
        await mgr.start();
      } on StateError {
        // Expected: health check fails
      }

      expect(capturedArgs, ['--host', '127.0.0.1', '--port', '3080']);
      expect(capturedArgs, isNot(contains('--data')));
    });

    test('start throws when already stopped', () async {
      final mgr = GowaManager(executable: 'gowa');
      await mgr.stop(); // sets _stopped = true
      expect(() => mgr.start(), throwsStateError);
    });

    test('start rethrows process spawn failure', () async {
      final mgr = GowaManager(
        executable: 'gowa',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          throw ProcessException('gowa', args, 'not found');
        },
      );

      expect(() => mgr.start(), throwsA(isA<ProcessException>()));
    });

    test('stop sends SIGTERM to running process', () async {
      final proc = FakeProcess();
      final mgr = GowaManager(
        executable: 'gowa',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          return proc;
        },
        delay: (d) => Future.value(),
      );

      // Start will fail health check, but process is still assigned
      try {
        await mgr.start();
      } on StateError {
        // Expected
      }

      await mgr.stop();
      expect(proc.killed, isTrue);
      expect(mgr.isRunning, isFalse);
    });

    test('stop on already-stopped manager is a no-op', () async {
      final mgr = GowaManager(executable: 'gowa');
      await mgr.stop();
      // Should not throw
      await mgr.stop();
    });

    test('dispose aliases stop', () async {
      final mgr = GowaManager(executable: 'gowa');
      await mgr.dispose();
      expect(mgr.isRunning, isFalse);
    });
  });
}
