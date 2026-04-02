import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/src/harness/agent_harness.dart';
import 'package:dartclaw_core/src/harness/claude_code_harness.dart';
import 'package:dartclaw_core/src/harness/harness_config.dart';
import 'package:dartclaw_core/src/harness/process_types.dart';
import 'package:dartclaw_core/src/harness/tool_policy.dart';
import 'package:dartclaw_core/src/worker/worker_state.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show NullIoSink;
import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// FakeProcess — controllable Process for unit tests
// ---------------------------------------------------------------------------

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
  IOSink get stdin => NullIoSink();

  @override
  Stream<List<int>> get stdout => _stdoutCtrl.stream;

  @override
  Stream<List<int>> get stderr => _stderrCtrl.stream;

  @override
  Future<int> get exitCode => _exitCodeCompleter.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    // Complete exitCode on kill so _stopInternal's SIGKILL escalation
    // doesn't wait for the grace period timeout in tests.
    if (!_exitCodeCompleter.isCompleted) _exitCodeCompleter.complete(0);
    return true;
  }

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

class _CapturingIOSink extends NullIoSink {
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

/// [FakeProcess] variant that tracks kill signals for SIGKILL escalation tests.
class _KillTrackingFakeProcess extends FakeProcess {
  final List<ProcessSignal> killSignals = [];
  final bool _completeExitOnKill;
  final int _killExitCode;

  _KillTrackingFakeProcess({bool completeExitOnKill = false, int killExitCode = 0})
    : _completeExitOnKill = completeExitOnKill,
      _killExitCode = killExitCode;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killSignals.add(signal);
    if (_completeExitOnKill) exit(_killExitCode);
    return true;
  }
}

class _RecordingGuard extends Guard {
  GuardContext? lastContext;

  @override
  String get name => 'recording-guard';

  @override
  String get category => 'test';

  @override
  Future<GuardVerdict> evaluate(GuardContext context) async {
    lastContext = context;
    return GuardVerdict.pass();
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
  Duration killGracePeriod = Duration.zero,
}) {
  return ClaudeCodeHarness(
    cwd: '/tmp',
    processFactory: processFactory ?? _defaultProcessFactory,
    commandProbe: commandProbe ?? _defaultCommandProbe,
    delayFactory: delayFactory ?? _noOpDelay,
    environment: environment ?? {'ANTHROPIC_API_KEY': 'sk-test-key'},
    harnessConfig: harnessConfig,
    killGracePeriod: killGracePeriod,
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
        expect(capturedArgs, contains('--setting-sources'));
        expect(capturedArgs, contains('--dangerously-skip-permissions'));
        expect(capturedArgs, isNot(contains('--permission-prompt-tool')));
        // Nesting-detection env vars should be stripped.
        expect(capturedEnv, isNot(contains('CLAUDECODE')));
        expect(capturedEnv, isNot(contains('CLAUDE_CODE_ENTRYPOINT')));
        // Regular env vars should remain.
        expect(capturedEnv?['HOME'], '/home/user');
        expect(capturedEnv?['ANTHROPIC_API_KEY'], 'sk-test');
      });

      test('restarts in the requested working directory before a task turn', () async {
        final workingDirectories = <String?>[];

        final h = _buildHarness(
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            workingDirectories.add(workingDirectory);
            final fake = FakeProcess();
            scheduleMicrotask(() {
              fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
            });
            Future.delayed(const Duration(milliseconds: 20), () {
              fake.emitStdout(
                jsonEncode({
                  'type': 'result',
                  'result': 'test response',
                  'cost_usd': 0.01,
                  'duration_ms': 100,
                  'duration_api_ms': 50,
                  'num_turns': 1,
                  'is_error': false,
                  'session_id': 'test-session',
                }),
              );
            });
            return fake;
          },
        );
        addTeardownAsync(() => h.dispose());

        await h.start();
        await h.turn(
          sessionId: 'task-session',
          messages: const [
            {'role': 'user', 'content': 'edit code'},
          ],
          systemPrompt: 'system',
          directory: '/tmp/worktree/task-1',
        );

        expect(workingDirectories, containsAllInOrder(['/tmp', '/tmp/worktree/task-1']));
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
              fake.emitStdout(
                jsonEncode({
                  'type': 'result',
                  'result': 'test response',
                  'cost_usd': 0.01,
                  'duration_ms': 100,
                  'duration_api_ms': 50,
                  'num_turns': 1,
                  'is_error': false,
                  'session_id': 'test-session',
                }),
              );
            });
            return fake;
          },
        );
        addTeardownAsync(() => h.dispose());

        await h.start();
        expect(h.promptStrategy, PromptStrategy.append);

        await h.turn(
          sessionId: 'test',
          messages: [
            {'role': 'user', 'content': 'hello'},
          ],
          systemPrompt: 'this should NOT appear in payload',
        );

        // Find the user-type payload (the turn message)
        final userPayloads = stdinLines.where((p) => p['type'] == 'user').toList();
        expect(userPayloads, isNotEmpty, reason: 'Should have sent a user message');
        for (final p in userPayloads) {
          expect(
            p.containsKey('system_prompt'),
            isFalse,
            reason: 'Append-strategy harness should not send system_prompt in JSONL',
          );
        }
      });
    });

    group('hook callbacks', () {
      test('PreToolUse maps Claude tool names before guard evaluation and preserves raw provider name', () async {
        final stdinLines = <Map<String, dynamic>>[];
        final guard = _RecordingGuard();
        late CapturingFakeProcess fake;
        List<String>? capturedArgs;

        final h = ClaudeCodeHarness(
          cwd: '/tmp',
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            capturedArgs = args;
            fake = CapturingFakeProcess(stdinLines);
            scheduleMicrotask(() {
              fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
            });
            return fake;
          },
          commandProbe: _defaultCommandProbe,
          delayFactory: _noOpDelay,
          environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
          guardChain: GuardChain(guards: [guard]),
        );
        addTeardownAsync(() => h.dispose());

        await h.start();
        expect(capturedArgs, contains('--setting-sources'));
        fake.emitStdout(
          jsonEncode({
            'type': 'control_request',
            'request_id': 'req-hook',
            'request': {
              'subtype': 'hook_callback',
              'input': {
                'hook_event_name': 'PreToolUse',
                'tool_name': 'Bash',
                'tool_input': {'command': 'git status'},
              },
            },
          }),
        );

        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(guard.lastContext, isNotNull);
        expect(guard.lastContext!.toolName, 'shell');
        expect(guard.lastContext!.rawProviderToolName, 'Bash');
        expect(guard.lastContext!.toolInput, {'command': 'git status'});
        expect(
          stdinLines,
          contains(
            containsPair(
              'response',
              containsPair('response', containsPair('hookSpecificOutput', containsPair('hookEventName', 'PreToolUse'))),
            ),
          ),
        );
      });

      test('PreToolUse evaluates unmapped Claude tools under claude: prefix and logs warning', () async {
        final stdinLines = <Map<String, dynamic>>[];
        final guard = _RecordingGuard();
        final records = <LogRecord>[];
        final oldLevel = Logger.root.level;
        late CapturingFakeProcess fake;
        Logger.root.level = Level.ALL;
        final sub = Logger.root.onRecord.listen(records.add);
        addTearDown(() async {
          Logger.root.level = oldLevel;
          await sub.cancel();
        });

        final h = ClaudeCodeHarness(
          cwd: '/tmp',
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            fake = CapturingFakeProcess(stdinLines);
            scheduleMicrotask(() {
              fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
            });
            return fake;
          },
          commandProbe: _defaultCommandProbe,
          delayFactory: _noOpDelay,
          environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
          guardChain: GuardChain(guards: [guard]),
        );
        addTeardownAsync(() => h.dispose());

        await h.start();
        fake.emitStdout(
          jsonEncode({
            'type': 'control_request',
            'request_id': 'req-hook-unmapped',
            'request': {
              'subtype': 'hook_callback',
              'input': {
                'hook_event_name': 'PreToolUse',
                'tool_name': 'TodoWrite',
                'tool_input': {'todos': []},
              },
            },
          }),
        );

        await Future<void>.delayed(const Duration(milliseconds: 10));

        expect(guard.lastContext, isNotNull);
        expect(guard.lastContext!.toolName, 'claude:TodoWrite');
        expect(guard.lastContext!.rawProviderToolName, 'TodoWrite');
        expect(
          records.any(
            (record) =>
                record.loggerName == 'ClaudeCodeHarness' &&
                record.level == Level.WARNING &&
                record.message.contains('Falling back to unmapped Claude tool name: TodoWrite -> claude:TodoWrite'),
          ),
          isTrue,
        );
        expect(stdinLines, isNotEmpty);
      });
    });

    // ----- SIGKILL escalation during stop --------------------------------

    group('SIGKILL escalation', () {
      test('stop() escalates to SIGKILL when process does not exit after SIGTERM', () async {
        final fake = _KillTrackingFakeProcess();

        final h = ClaudeCodeHarness(
          cwd: '/tmp',
          killGracePeriod: const Duration(milliseconds: 50),
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            scheduleMicrotask(() {
              fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
            });
            return fake;
          },
          commandProbe: _defaultCommandProbe,
          delayFactory: _noOpDelay,
          environment: {'ANTHROPIC_API_KEY': 'sk-test-key'},
        );

        await h.start();
        expect(h.state, WorkerState.idle);

        // Schedule process exit after SIGKILL would be sent.
        Timer(const Duration(milliseconds: 100), () => fake.exit(137));

        await h.stop();

        expect(h.state, WorkerState.stopped);
        // First signal is SIGTERM from stop(), second is SIGKILL from escalation.
        expect(fake.killSignals, hasLength(greaterThanOrEqualTo(2)));
        expect(fake.killSignals.first, ProcessSignal.sigterm);
        if (!Platform.isWindows) {
          expect(fake.killSignals.last, ProcessSignal.sigkill);
        }
      });

      test('stop() does not escalate to SIGKILL when process exits promptly on SIGTERM', () async {
        final fake = _KillTrackingFakeProcess(completeExitOnKill: true);

        final h = ClaudeCodeHarness(
          cwd: '/tmp',
          killGracePeriod: const Duration(seconds: 5),
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
            scheduleMicrotask(() {
              fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
            });
            return fake;
          },
          commandProbe: _defaultCommandProbe,
          delayFactory: _noOpDelay,
          environment: {'ANTHROPIC_API_KEY': 'sk-test-key'},
        );

        await h.start();
        await h.stop();

        expect(h.state, WorkerState.stopped);
        // Only SIGTERM — no escalation needed.
        expect(fake.killSignals, [ProcessSignal.sigterm]);
      });
    });

    // -------------------------------------------------------------------------
    // T11: Effort tolerance — null -> non-null does not restart harness
    // -------------------------------------------------------------------------

    group('T11: Effort tolerance', () {
      test('null processEffort adopts first-use non-null effort without restart', () async {
        var spawnCount = 0;
        final stdinLines = <Map<String, dynamic>>[];

        Future<Process> makeProcess() async {
          spawnCount++;
          final fake = CapturingFakeProcess(stdinLines);
          scheduleMicrotask(() {
            fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
          });
          Future.delayed(const Duration(milliseconds: 20), () {
            fake.emitStdout(
              jsonEncode({
                'type': 'result',
                'result': 'ok',
                'cost_usd': 0.001,
                'duration_ms': 10,
                'duration_api_ms': 5,
                'num_turns': 1,
                'is_error': false,
                'session_id': 'test-session',
              }),
            );
          });
          return fake;
        }

        // Harness spawned with no effort (null).
        final h = ClaudeCodeHarness(
          cwd: '/tmp',
          harnessConfig: const HarnessConfig(effort: null),
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) =>
              makeProcess(),
          commandProbe: _defaultCommandProbe,
          delayFactory: _noOpDelay,
          environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
        );
        addTeardownAsync(() => h.dispose());

        await h.start();
        expect(spawnCount, 1, reason: 'Should spawn exactly once on start');

        // Call turn() with effort: 'medium' — should be adopted without restart.
        await h.turn(
          sessionId: 'test',
          messages: const [
            {'role': 'user', 'content': 'hello'},
          ],
          systemPrompt: '',
          effort: 'medium',
        );

        // Only one spawn — no restart triggered for null -> 'medium' adoption.
        expect(spawnCount, 1, reason: 'First-use adoption must not trigger a restart');
        expect(h.state, WorkerState.idle);
      });

      test('non-null -> different non-null effort triggers restart', () async {
        var spawnCount = 0;

        Future<Process> makeProcess() async {
          spawnCount++;
          final fake = FakeProcess();
          scheduleMicrotask(() {
            fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
          });
          Future.delayed(const Duration(milliseconds: 20), () {
            fake.emitStdout(
              jsonEncode({
                'type': 'result',
                'result': 'ok',
                'cost_usd': 0.001,
                'duration_ms': 10,
                'duration_api_ms': 5,
                'num_turns': 1,
                'is_error': false,
                'session_id': 'test-session',
              }),
            );
          });
          return fake;
        }

        final h = ClaudeCodeHarness(
          cwd: '/tmp',
          harnessConfig: const HarnessConfig(effort: 'low'),
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) =>
              makeProcess(),
          commandProbe: _defaultCommandProbe,
          delayFactory: _noOpDelay,
          environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
        );
        addTeardownAsync(() => h.dispose());

        await h.start();
        expect(spawnCount, 1);

        // Turn with different effort — should trigger restart.
        await h.turn(
          sessionId: 'test',
          messages: const [
            {'role': 'user', 'content': 'hello'},
          ],
          systemPrompt: '',
          effort: 'high',
        );

        expect(spawnCount, 2, reason: 'Different non-null effort must trigger restart');
      });
    });

    // -------------------------------------------------------------------------
    // T12: Restart mid-session produces <conversation_history> in JSONL
    // -------------------------------------------------------------------------

    group('T12: Restart mid-session produces conversation_history', () {
      test('second spawn receives <conversation_history> when messages > 1', () async {
        var spawnCount = 0;
        final capturedPayloads = <Map<String, dynamic>>[];

        Future<Process> makeProcess() async {
          spawnCount++;
          final fake = CapturingFakeProcess(capturedPayloads);
          scheduleMicrotask(() {
            fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
          });
          // Schedule a turn result so the turn call completes.
          Future.delayed(const Duration(milliseconds: 30), () {
            fake.emitStdout(
              jsonEncode({
                'type': 'result',
                'result': 'done',
                'cost_usd': 0.001,
                'duration_ms': 10,
                'duration_api_ms': 5,
                'num_turns': 1,
                'is_error': false,
                'session_id': 's1',
              }),
            );
          });
          return fake;
        }

        final h = ClaudeCodeHarness(
          cwd: '/tmp',
          harnessConfig: const HarnessConfig(model: 'sonnet'),
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) =>
              makeProcess(),
          commandProbe: _defaultCommandProbe,
          delayFactory: _noOpDelay,
          environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
        );
        addTeardownAsync(() => h.dispose());

        await h.start();

        // First turn (warm — no history injection).
        await h.turn(
          sessionId: 'test',
          messages: const [
            {'role': 'user', 'content': 'first message'},
          ],
          systemPrompt: '',
        );
        expect(spawnCount, 1);

        // Second turn with model change — triggers restart (cold process).
        // Pass 3 messages: prior user+assistant pair + the current user message.
        // The history block requires at least one complete user+assistant exchange.
        await h.turn(
          sessionId: 'test',
          messages: const [
            {'role': 'user', 'content': 'first message'},
            {'role': 'assistant', 'content': 'first response'},
            {'role': 'user', 'content': 'second message'},
          ],
          systemPrompt: '',
          model: 'opus',
        );
        expect(spawnCount, 2, reason: 'Model change should trigger restart');

        // The payload sent to the second process should contain conversation_history.
        final userPayloads = capturedPayloads.where((p) => p['type'] == 'user').toList();
        final secondTurnPayload = userPayloads.last;
        final messageContent = secondTurnPayload['message']?['content'] as String? ?? '';
        expect(
          messageContent,
          contains('<conversation_history>'),
          reason: 'Cold process turn with prior messages must inject conversation history',
        );
      });
    });

    // -------------------------------------------------------------------------
    // T13: Parameter-change restart emits warning log
    // -------------------------------------------------------------------------

    group('T13: Parameter-change restart emits warning log', () {
      test('model change restart emits Restarting harness warning', () async {
        final logRecords = <LogRecord>[];
        final sub = Logger('ClaudeCodeHarness').onRecord.listen(logRecords.add);
        addTearDown(sub.cancel);

        Future<Process> makeProcess() async {
          final fake = FakeProcess();
          scheduleMicrotask(() {
            fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
          });
          Future.delayed(const Duration(milliseconds: 20), () {
            fake.emitStdout(
              jsonEncode({
                'type': 'result',
                'result': 'ok',
                'cost_usd': 0.001,
                'duration_ms': 10,
                'duration_api_ms': 5,
                'num_turns': 1,
                'is_error': false,
                'session_id': 's1',
              }),
            );
          });
          return fake;
        }

        final h = ClaudeCodeHarness(
          cwd: '/tmp',
          harnessConfig: const HarnessConfig(model: 'sonnet'),
          processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) =>
              makeProcess(),
          commandProbe: _defaultCommandProbe,
          delayFactory: _noOpDelay,
          environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
        );
        addTeardownAsync(() => h.dispose());

        await h.start();

        // Trigger a model-change restart.
        await h.turn(
          sessionId: 'test',
          messages: const [
            {'role': 'user', 'content': 'hello'},
          ],
          systemPrompt: '',
          model: 'opus',
        );

        final warnings = logRecords
            .where((r) => r.level == Level.WARNING && r.message.contains('Restarting harness due to parameter change'))
            .toList();
        expect(warnings, isNotEmpty, reason: 'Should emit warning on parameter-change restart');
        expect(warnings.first.message, contains('model:'));
      });
    });
  });
}

/// Registers async teardown — shorthand for [addTearDown] with async closures.
void addTeardownAsync(Future<void> Function() fn) => addTearDown(fn);
