import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/src/channel/whatsapp/gowa_manager.dart';
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
      final mgr = GowaManager(executable: 'whatsapp', host: '0.0.0.0', port: 4000);
      expect(mgr.baseUrl, 'http://0.0.0.0:4000');
    });

    test('default baseUrl uses port 3000', () {
      final mgr = GowaManager(executable: 'whatsapp');
      expect(mgr.baseUrl, 'http://127.0.0.1:3000');
    });

    test('isRunning is false initially', () {
      final mgr = GowaManager(executable: 'whatsapp');
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
          return FakeProcess();
        },
        delay: (d) => Future.value(),
      );

      try {
        await mgr.start();
      } on StateError {
        // Expected: health check fails (no real server)
      }

      expect(capturedExe, '/usr/local/bin/whatsapp');
      expect(capturedArgs, [
        'rest',
        '--host', '0.0.0.0',
        '--port', '5000',
        '--db-uri', '/data/wa.db',
        '--webhook=http://localhost:3333/webhook/whatsapp?secret=abc',
      ]);
    });

    test('start without dbUri omits --db-uri flag', () async {
      late List<String> capturedArgs;

      final mgr = GowaManager(
        executable: 'whatsapp',
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
          return FakeProcess();
        },
        delay: (d) => Future.value(),
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

    test('stop sends SIGTERM to running process', () async {
      final proc = FakeProcess();
      final mgr = GowaManager(
        executable: 'whatsapp',
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
      final proc = FakeProcess();
      final mgr = GowaManager(
        executable: 'whatsapp',
        processFactory: (exe, args,
            {workingDirectory, environment, includeParentEnvironment = true}) async {
          return proc;
        },
        delay: (d) => Future.value(),
      );

      expect(proc.killed, isFalse);
      await expectLater(() => mgr.start(), throwsStateError);
      expect(proc.killed, isTrue);
    });
  });
}
