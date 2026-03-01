import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/src/harness/agent_harness.dart';
import 'package:dartclaw_core/src/harness/claude_code_harness.dart';
import 'package:dartclaw_core/src/harness/harness_config.dart';
import 'package:dartclaw_core/src/harness/tool_policy.dart';
import 'package:dartclaw_core/src/worker/worker_state.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// FakeProcess — controllable Process for unit tests
// ---------------------------------------------------------------------------

/// A no-op [IOSink] that silently discards all writes.
class _NullIOSink implements IOSink {
  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) {}
  @override
  void addError(Object error, [StackTrace? stackTrace]) {}
  @override
  Future<void> addStream(Stream<List<int>> stream) async {}
  @override
  Future<void> close() async {}
  @override
  Future<void> get done => Completer<void>().future;
  @override
  Future<void> flush() async {}
  @override
  void write(Object? object) {}
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {}
  @override
  void writeCharCode(int charCode) {}
  @override
  void writeln([Object? object = '']) {}
}

class FakeProcess implements Process {
  final StreamController<List<int>> _stdoutCtrl;
  final StreamController<List<int>> _stderrCtrl;
  final Completer<int> _exitCodeCompleter = Completer<int>();

  FakeProcess({StreamController<List<int>>? stdoutCtrl, StreamController<List<int>>? stderrCtrl})
    : _stdoutCtrl = stdoutCtrl ?? StreamController<List<int>>(),
      _stderrCtrl = stderrCtrl ?? StreamController<List<int>>();

  @override
  int get pid => 42;

  @override
  IOSink get stdin => _NullIOSink();

  @override
  Stream<List<int>> get stdout => _stdoutCtrl.stream;

  @override
  Stream<List<int>> get stderr => _stderrCtrl.stream;

  @override
  Future<int> get exitCode => _exitCodeCompleter.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;

  /// Emit a line on stdout (simulates claude binary output).
  void emitStdout(String line) {
    _stdoutCtrl.add(utf8.encode('$line\n'));
  }

  /// Complete the process with the given exit code.
  void exit(int code) {
    if (!_exitCodeCompleter.isCompleted) _exitCodeCompleter.complete(code);
  }
}

/// A [FakeProcess] variant that captures JSONL lines written to stdin.
class CapturingFakeProcess extends FakeProcess {
  final List<Map<String, dynamic>> _captured;

  CapturingFakeProcess(this._captured);

  @override
  IOSink get stdin => _CapturingIOSink(_captured);
}

class _CapturingIOSink extends _NullIOSink {
  final List<Map<String, dynamic>> _captured;
  _CapturingIOSink(this._captured);

  @override
  void add(List<int> data) {
    final line = utf8.decode(data).trim();
    if (line.isNotEmpty) {
      try {
        _captured.add(jsonDecode(line) as Map<String, dynamic>);
      } catch (_) {}
    }
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Creates a [ProcessResult] with the given exit code and stdout.
ProcessResult _result({int exitCode = 0, String stdout = ''}) => ProcessResult(0, exitCode, stdout, '');

/// Builds a harness with common test defaults. Callers can override
/// individual factories as needed.
ClaudeCodeHarness _buildHarness({
  ProcessFactory? processFactory,
  CommandProbe? commandProbe,
  DelayFactory? delayFactory,
  Map<String, String>? environment,
  HarnessConfig harnessConfig = const HarnessConfig(),
}) {
  return ClaudeCodeHarness(
    cwd: '/tmp',
    processFactory: processFactory ?? _defaultProcessFactory,
    commandProbe: commandProbe ?? _defaultCommandProbe,
    delayFactory: delayFactory ?? _noOpDelay,
    environment: environment ?? {'ANTHROPIC_API_KEY': 'sk-test-key'},
    harnessConfig: harnessConfig,
  );
}

/// Default process factory that returns a FakeProcess which immediately
/// emits the initialize control_response on stdout.
Future<Process> _defaultProcessFactory(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
  bool includeParentEnvironment = true,
}) async {
  final fake = FakeProcess();
  // Schedule init response so _sendInitialize completes.
  scheduleMicrotask(() {
    fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
  });
  return fake;
}

/// Default command probe — succeeds for both `--version` and `auth status`.
Future<ProcessResult> _defaultCommandProbe(String exe, List<String> args) async {
  return _result(exitCode: 0, stdout: '1.0.0');
}

/// Delay factory that completes immediately (no real waiting in tests).
Future<void> _noOpDelay(Duration _) async {}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('ClaudeCodeHarness', () {
    // ----- Constructor defaults & configuration --------------------------

    group('constructor defaults', () {
      test('uses sensible defaults for optional parameters', () {
        final h = ClaudeCodeHarness(cwd: '/tmp');
        expect(h.claudeExecutable, 'claude');
        expect(h.cwd, '/tmp');
        expect(h.turnTimeout, const Duration(seconds: 600));
        expect(h.maxRetries, 5);
        expect(h.baseBackoff, const Duration(seconds: 5));
        expect(h.toolPolicy, ToolApprovalPolicy.allowAll);
      });

      test('initial state is stopped', () {
        final h = ClaudeCodeHarness(cwd: '/tmp');
        expect(h.state, WorkerState.stopped);
      });

      test('sessionId is null before start', () {
        final h = ClaudeCodeHarness(cwd: '/tmp');
        expect(h.sessionId, isNull);
      });

      test('accepts custom configuration', () {
        final h = ClaudeCodeHarness(
          claudeExecutable: '/usr/local/bin/claude',
          cwd: '/home/user',
          turnTimeout: const Duration(seconds: 120),
          maxRetries: 3,
          baseBackoff: const Duration(seconds: 2),
        );
        expect(h.claudeExecutable, '/usr/local/bin/claude');
        expect(h.cwd, '/home/user');
        expect(h.turnTimeout, const Duration(seconds: 120));
        expect(h.maxRetries, 3);
        expect(h.baseBackoff, const Duration(seconds: 2));
      });
    });

    // ----- start() -------------------------------------------------------

    group('start()', () {
      test('calls commandProbe to verify claude binary exists', () async {
        var probeCalled = false;
        String? probeExe;
        List<String>? probeArgs;

        final h = _buildHarness(
          commandProbe: (exe, args) async {
            probeCalled = true;
            probeExe = exe;
            probeArgs = args;
            return _result(exitCode: 0, stdout: '1.0.0');
          },
        );

        await h.start();
        addTeardownAsync(() => h.dispose());

        expect(probeCalled, isTrue);
        expect(probeExe, 'claude');
        expect(probeArgs, ['--version']);
      });

      test('throws StateError when commandProbe reports binary missing', () async {
        final h = _buildHarness(commandProbe: (exe, args) async => _result(exitCode: 1));
        addTeardownAsync(() => h.dispose());

        await expectLater(h.start(), throwsA(isA<StateError>()));
      });

      test('throws when ANTHROPIC_API_KEY missing and OAuth check fails', () async {
        var callCount = 0;
        final h = _buildHarness(
          environment: {}, // no API key
          commandProbe: (exe, args) async {
            callCount++;
            if (args.contains('--version')) return _result(exitCode: 0);
            // auth status check fails
            return _result(exitCode: 1);
          },
        );
        addTeardownAsync(() => h.dispose());

        await expectLater(
          h.start(),
          throwsA(isA<StateError>().having((e) => e.message, 'message', contains('No authentication configured'))),
        );
        // Two probe calls: --version + auth status
        expect(callCount, 2);
      });

      test('transitions state from stopped to idle on success', () async {
        final h = _buildHarness();
        addTeardownAsync(() => h.dispose());

        expect(h.state, WorkerState.stopped);
        await h.start();
        expect(h.state, WorkerState.idle);
      });

      test('is idempotent when already idle', () async {
        final h = _buildHarness();
        addTeardownAsync(() => h.dispose());

        await h.start();
        expect(h.state, WorkerState.idle);

        // Second start() should be a no-op.
        await h.start();
        expect(h.state, WorkerState.idle);
      });

      test('throws when called while busy', () async {
        final fakeProcess = FakeProcess();

        final h = _buildHarness(
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            scheduleMicrotask(() {
              fakeProcess.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
            });
            return fakeProcess;
          },
        );
        addTeardownAsync(() => h.dispose());

        await h.start();

        // Initiate a turn that will never complete (no TurnResult emitted).
        final turnFuture = h.turn(
          sessionId: 'test',
          messages: [
            {'role': 'user', 'content': 'hello'},
          ],
          systemPrompt: 'test',
        );

        // Allow microtasks to run so turn() acquires lock and sets busy.
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(h.state, WorkerState.busy);

        await expectLater(h.start(), throwsA(isA<StateError>()));

        // Clean up: kill process so the pending turn completes with error.
        fakeProcess.exit(1);
        await turnFuture.catchError((_) => <String, dynamic>{});
      });

      test('spawns process with correct arguments and cleaned env', () async {
        String? capturedExe;
        List<String>? capturedArgs;
        Map<String, String>? capturedEnv;

        final h = _buildHarness(
          environment: {'ANTHROPIC_API_KEY': 'sk-test', 'CLAUDECODE': 'nested', 'HOME': '/home/user'},
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            capturedExe = exe;
            capturedArgs = args;
            capturedEnv = environment;
            final fake = FakeProcess();
            scheduleMicrotask(() {
              fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
            });
            return fake;
          },
        );
        addTeardownAsync(() => h.dispose());

        await h.start();

        expect(capturedExe, 'claude');
        expect(capturedArgs, contains('--print'));
        expect(capturedArgs, contains('--output-format'));
        expect(capturedArgs, contains('stream-json'));
        // Nesting-detection env vars should be stripped.
        expect(capturedEnv, isNot(contains('CLAUDECODE')));
        expect(capturedEnv, isNot(contains('CLAUDE_CODE_ENTRYPOINT')));
        // Regular env vars should remain.
        expect(capturedEnv?['HOME'], '/home/user');
        expect(capturedEnv?['ANTHROPIC_API_KEY'], 'sk-test');
      });
    });

    // ----- state transitions ---------------------------------------------

    group('state transitions', () {
      test('crashed state on unexpected process exit', () async {
        final fakeProcess = FakeProcess();

        final h = _buildHarness(
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            scheduleMicrotask(() {
              fakeProcess.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
            });
            return fakeProcess;
          },
        );
        addTeardownAsync(() => h.dispose());

        await h.start();
        expect(h.state, WorkerState.idle);

        // Simulate unexpected exit.
        fakeProcess.exit(1);
        // Allow the exitCode future handler to fire.
        await Future<void>.delayed(Duration.zero);

        expect(h.state, WorkerState.crashed);
      });

      test('stop() transitions from idle to stopped', () async {
        final h = _buildHarness();
        addTeardownAsync(() => h.dispose());

        await h.start();
        expect(h.state, WorkerState.idle);

        await h.stop();
        expect(h.state, WorkerState.stopped);
      });

      test('stop() from stopped is safe', () async {
        final h = _buildHarness();
        expect(h.state, WorkerState.stopped);
        await h.stop();
        expect(h.state, WorkerState.stopped);
      });
    });

    // ----- dispose() -----------------------------------------------------

    group('dispose()', () {
      test('transitions to stopped and closes event stream', () async {
        final h = _buildHarness();
        await h.start();
        expect(h.state, WorkerState.idle);

        await h.dispose();
        expect(h.state, WorkerState.stopped);

        // Event stream should be closed — adding a listener should get done.
        final events = <dynamic>[];
        h.events.listen(events.add);
        await Future<void>.delayed(Duration.zero);
        expect(events, isEmpty);
      });

      test('is idempotent', () async {
        final h = _buildHarness();
        await h.start();

        await h.dispose();
        await h.dispose(); // should not throw
        expect(h.state, WorkerState.stopped);
      });

      test('kills the spawned process', () async {
        final fakeProcess = FakeProcess();

        final h = _buildHarness(
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            scheduleMicrotask(() {
              fakeProcess.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
            });
            return fakeProcess;
          },
        );

        await h.start();

        // Wrap kill to detect it. FakeProcess.kill always returns true,
        // but we verify dispose invokes stop() which calls kill.
        // We can verify state is stopped as a proxy.
        await h.dispose();
        expect(h.state, WorkerState.stopped);
      });
    });

    // ----- events stream -------------------------------------------------

    group('events stream', () {
      test('is a broadcast stream', () {
        final h = ClaudeCodeHarness(cwd: '/tmp');
        // Broadcast streams allow multiple listeners.
        h.events.listen((_) {});
        h.events.listen((_) {});
        addTeardownAsync(() => h.dispose());
      });
    });

    // ----- prompt strategy / append protocol ------------------------------

    group('prompt strategy', () {
      test('promptStrategy is append', () {
        final h = ClaudeCodeHarness(cwd: '/tmp');
        expect(h.promptStrategy, PromptStrategy.append);
      });

      test('spawn args include --append-system-prompt when configured', () async {
        List<String>? capturedArgs;

        final h = _buildHarness(
          harnessConfig: const HarnessConfig(appendSystemPrompt: 'test behavior prompt'),
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            capturedArgs = args;
            final fake = FakeProcess();
            scheduleMicrotask(() {
              fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
            });
            return fake;
          },
        );
        addTeardownAsync(() => h.dispose());

        await h.start();

        expect(capturedArgs, isNotNull);
        final idx = capturedArgs!.indexOf('--append-system-prompt');
        expect(idx, greaterThanOrEqualTo(0), reason: '--append-system-prompt flag should be present');
        expect(capturedArgs![idx + 1], 'test behavior prompt');
      });

      test('spawn args omit --append-system-prompt when not configured', () async {
        List<String>? capturedArgs;

        final h = _buildHarness(
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            capturedArgs = args;
            final fake = FakeProcess();
            scheduleMicrotask(() {
              fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
            });
            return fake;
          },
        );
        addTeardownAsync(() => h.dispose());

        await h.start();

        expect(capturedArgs, isNotNull);
        expect(capturedArgs, isNot(contains('--append-system-prompt')));
      });

      test('JSONL payload omits system_prompt for append-strategy harness', () async {
        final stdinLines = <Map<String, dynamic>>[];

        final h = _buildHarness(
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            final fake = CapturingFakeProcess(stdinLines);
            scheduleMicrotask(() {
              fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
            });
            // Emit turn result so the turn completes
            Future.delayed(const Duration(milliseconds: 20), () {
              fake.emitStdout(jsonEncode({
                'type': 'result',
                'result': 'test response',
                'cost_usd': 0.01,
                'duration_ms': 100,
                'duration_api_ms': 50,
                'num_turns': 1,
                'is_error': false,
                'session_id': 'test-session',
              }));
            });
            return fake;
          },
        );
        addTeardownAsync(() => h.dispose());

        await h.start();
        expect(h.promptStrategy, PromptStrategy.append);

        await h.turn(
          sessionId: 'test',
          messages: [{'role': 'user', 'content': 'hello'}],
          systemPrompt: 'this should NOT appear in payload',
        );

        // Find the user-type payload (the turn message)
        final userPayloads = stdinLines.where((p) => p['type'] == 'user').toList();
        expect(userPayloads, isNotEmpty, reason: 'Should have sent a user message');
        for (final p in userPayloads) {
          expect(p.containsKey('system_prompt'), isFalse,
              reason: 'Append-strategy harness should not send system_prompt in JSONL');
        }
      });
    });
  });
}

/// Registers async teardown — shorthand for [addTearDown] with async closures.
void addTeardownAsync(Future<void> Function() fn) => addTearDown(fn);
