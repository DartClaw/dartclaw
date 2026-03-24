import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/src/bridge/bridge_events.dart';
import 'package:dartclaw_core/src/harness/codex_exec_harness.dart';
import 'package:dartclaw_core/src/harness/harness_config.dart';
import 'package:dartclaw_core/src/worker/worker_state.dart';
import 'package:test/test.dart';

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

class FakeCodexExecProcess implements Process {
  final StreamController<List<int>> _stdoutCtrl;
  final StreamController<List<int>> _stderrCtrl;
  final Completer<int> _exitCodeCompleter = Completer<int>();
  final List<String> writtenStdin = <String>[];
  final List<ProcessSignal> killSignals = <ProcessSignal>[];
  final bool _completeExitOnKill;
  bool killed = false;

  FakeCodexExecProcess({
    StreamController<List<int>>? stdoutCtrl,
    StreamController<List<int>>? stderrCtrl,
    bool completeExitOnKill = false,
  }) : _stdoutCtrl = stdoutCtrl ?? StreamController<List<int>>(),
       _stderrCtrl = stderrCtrl ?? StreamController<List<int>>(),
       _completeExitOnKill = completeExitOnKill;

  @override
  int get pid => 42;

  @override
  IOSink get stdin => _CapturingIOSink(writtenStdin);

  @override
  Stream<List<int>> get stdout => _stdoutCtrl.stream;

  @override
  Stream<List<int>> get stderr => _stderrCtrl.stream;

  @override
  Future<int> get exitCode => _exitCodeCompleter.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    killSignals.add(signal);
    if (_completeExitOnKill) exit(0);
    return true;
  }

  void emitStdout(String line) {
    _stdoutCtrl.add(utf8.encode('$line\n'));
  }

  void emitStderr(String line) {
    _stderrCtrl.add(utf8.encode('$line\n'));
  }

  void exit(int code) {
    if (!_exitCodeCompleter.isCompleted) {
      _exitCodeCompleter.complete(code);
    }
  }
}

class _CapturingIOSink extends _NullIOSink {
  final List<String> _captured;

  _CapturingIOSink(this._captured);

  @override
  void add(List<int> data) {
    final line = utf8.decode(data).trim();
    if (line.isNotEmpty) {
      _captured.add(line);
    }
  }
}

Future<Process> _processFactory(
  List<String> capturedArgs,
  FakeCodexExecProcess process,
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
  bool includeParentEnvironment = true,
}) async {
  capturedArgs
    ..clear()
    ..addAll(arguments);
  return process;
}

void main() {
  group('CodexExecHarness', () {
    test('start() transitions to idle without spawning a persistent process', () async {
      final process = FakeCodexExecProcess();
      final capturedArgs = <String>[];
      var startCalls = 0;

      final harness = CodexExecHarness(
        cwd: '/tmp/workspace',
        processFactory:
            (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async {
              startCalls++;
              return _processFactory(
                capturedArgs,
                process,
                executable,
                arguments,
                workingDirectory: workingDirectory,
                environment: environment,
                includeParentEnvironment: includeParentEnvironment,
              );
            },
        environment: const {'OPENAI_API_KEY': 'sk-test'},
      );
      addTearDown(harness.dispose);

      await harness.start();

      expect(startCalls, 0);
      expect(harness.state, WorkerState.idle);
      expect(capturedArgs, isEmpty);
    });

    test('turn() spawns exec mode with the expected flags and prompt', () async {
      final process = FakeCodexExecProcess();
      final capturedArgs = <String>[];
      final events = <BridgeEvent>[];

      final harness = CodexExecHarness(
        cwd: '/tmp/workspace',
        sandboxMode: 'danger-full-access',
        processFactory:
            (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async {
              return _processFactory(
                capturedArgs,
                process,
                executable,
                arguments,
                workingDirectory: workingDirectory,
                environment: environment,
                includeParentEnvironment: includeParentEnvironment,
              );
            },
        environment: const {'OPENAI_API_KEY': 'sk-test'},
      );
      addTearDown(harness.dispose);
      final sub = harness.events.listen(events.add);
      addTearDown(sub.cancel);

      unawaited(
        Future<void>.microtask(() {
          process.emitStdout(
            jsonEncode({
              'type': 'item.started',
              'item': {'id': 'tool-1', 'type': 'command_execution', 'command': 'ls -la'},
            }),
          );
          process.emitStdout(
            jsonEncode({
              'type': 'item.completed',
              'item': {'id': 'tool-1', 'type': 'command_execution', 'aggregated_output': 'done\n', 'exit_code': 0},
            }),
          );
          process.emitStdout(
            jsonEncode({
              'type': 'item.completed',
              'item': {'id': 'msg-1', 'type': 'agent_message', 'text': 'final answer'},
            }),
          );
          process.emitStdout(
            jsonEncode({
              'type': 'turn.completed',
              'usage': {'input_tokens': 12, 'output_tokens': 34, 'cached_input_tokens': 7},
            }),
          );
          process.exit(0);
        }),
      );

      final result = await harness.turn(
        sessionId: 'session-1',
        messages: [
          {'role': 'user', 'content': 'List the current directory.'},
        ],
        systemPrompt: 'Be concise.',
        directory: '/tmp/workspace/project',
        model: 'gpt-5',
      );

      expect(
        capturedArgs,
        containsAll([
          'exec',
          '--json',
          '--full-auto',
          '--ephemeral',
          '--skip-git-repo-check',
          '--sandbox',
          'danger-full-access',
          '--cd',
          '/tmp/workspace/project',
          '-m',
          'gpt-5',
          'List the current directory.',
        ]),
      );
      expect(capturedArgs, isNot(contains('-c')));
      expect(harness.state, WorkerState.idle);
      expect(events.whereType<ToolUseEvent>(), isNotEmpty);
      expect(events.whereType<ToolResultEvent>(), isNotEmpty);
      expect(events.whereType<DeltaEvent>(), isNotEmpty);
      expect(result['stop_reason'], 'end_turn');
      expect(result['input_tokens'], 12);
      expect(result['output_tokens'], 34);
      expect(result['cache_read_tokens'], 7);
    });

    test('turn() returns an error result when the process exits non-zero', () async {
      final process = FakeCodexExecProcess();
      final capturedArgs = <String>[];

      final harness = CodexExecHarness(
        cwd: '/tmp/workspace',
        processFactory:
            (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async {
              return _processFactory(
                capturedArgs,
                process,
                executable,
                arguments,
                workingDirectory: workingDirectory,
                environment: environment,
                includeParentEnvironment: includeParentEnvironment,
              );
            },
        environment: const {'OPENAI_API_KEY': 'sk-test'},
      );
      addTearDown(harness.dispose);

      unawaited(
        Future<void>.microtask(() {
          process.emitStderr('boom');
          process.exit(2);
        }),
      );

      final result = await harness.turn(
        sessionId: 'session-2',
        messages: [
          {'role': 'user', 'content': 'Do work.'},
        ],
        systemPrompt: 'Be concise.',
      );

      expect(capturedArgs, contains('exec'));
      expect(result['stop_reason'], 'error');
      expect(result['error'], contains('boom'));
    });

    test('cancel() kills the in-progress process', () async {
      final process = FakeCodexExecProcess();
      final capturedArgs = <String>[];
      final harness = CodexExecHarness(
        cwd: '/tmp/workspace',
        processFactory:
            (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async {
              return _processFactory(
                capturedArgs,
                process,
                executable,
                arguments,
                workingDirectory: workingDirectory,
                environment: environment,
                includeParentEnvironment: includeParentEnvironment,
              );
            },
        environment: const {'OPENAI_API_KEY': 'sk-test'},
      );
      addTearDown(harness.dispose);

      final turnFuture = harness.turn(
        sessionId: 'session-3',
        messages: [
          {'role': 'user', 'content': 'Wait.'},
        ],
        systemPrompt: 'Be concise.',
      );

      await Future<void>.delayed(Duration.zero);
      await harness.cancel();
      process.exit(1);

      await expectLater(turnFuture, completes);
      expect(process.killed, isTrue);
    });

    test('stop() cancels the process and transitions to stopped', () async {
      final process = FakeCodexExecProcess();
      final capturedArgs = <String>[];
      final processStarted = Completer<void>();
      final harness = CodexExecHarness(
        cwd: '/tmp/workspace',
        processFactory:
            (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async {
              if (!processStarted.isCompleted) {
                processStarted.complete();
              }
              return _processFactory(
                capturedArgs,
                process,
                executable,
                arguments,
                workingDirectory: workingDirectory,
                environment: environment,
                includeParentEnvironment: includeParentEnvironment,
              );
            },
        environment: const {'OPENAI_API_KEY': 'sk-test'},
      );
      addTearDown(harness.dispose);

      final turnFuture = harness.turn(
        sessionId: 'session-4',
        messages: [
          {'role': 'user', 'content': 'Stop soon.'},
        ],
        systemPrompt: 'Be concise.',
      );

      await processStarted.future;
      await harness.stop();

      expect(harness.state, WorkerState.stopped);
      expect(process.killed, isTrue);
      await expectLater(turnFuture, completes);
    });

    test('stop() returns while process startup is still pending and completes the turn', () async {
      final process = FakeCodexExecProcess();
      final capturedArgs = <String>[];
      final processStartCompleter = Completer<Process>();
      final processStartCalled = Completer<void>();
      final harness = CodexExecHarness(
        cwd: '/tmp/workspace',
        processFactory: (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) {
          if (!processStartCalled.isCompleted) {
            processStartCalled.complete();
          }
          capturedArgs
            ..clear()
            ..addAll(arguments);
          return processStartCompleter.future;
        },
        environment: const {'OPENAI_API_KEY': 'sk-test'},
      );
      addTearDown(harness.dispose);

      final turnFuture = harness.turn(
        sessionId: 'session-pending-start',
        messages: [
          {'role': 'user', 'content': 'Wait for startup.'},
        ],
        systemPrompt: 'Be concise.',
      );

      await processStartCalled.future;
      await harness.stop();

      expect(harness.state, WorkerState.stopped);
      expect(capturedArgs, contains('exec'));
      await expectLater(
        turnFuture,
        completion(allOf([containsPair('stop_reason', 'error'), containsPair('error', 'CodexExecHarness stopped')])),
      );

      processStartCompleter.complete(process);
      await Future<void>.delayed(Duration.zero);
      expect(process.killed, isTrue);
      process.exit(1);
    });

    test('emits no SystemInitEvent in exec mode', () async {
      final process = FakeCodexExecProcess();
      final capturedArgs = <String>[];
      final events = <BridgeEvent>[];

      final harness = CodexExecHarness(
        cwd: '/tmp/workspace',
        processFactory:
            (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async {
              return _processFactory(
                capturedArgs,
                process,
                executable,
                arguments,
                workingDirectory: workingDirectory,
                environment: environment,
                includeParentEnvironment: includeParentEnvironment,
              );
            },
        environment: const {'OPENAI_API_KEY': 'sk-test'},
      );
      addTearDown(harness.dispose);
      final sub = harness.events.listen(events.add);
      addTearDown(sub.cancel);

      unawaited(
        Future<void>.microtask(() {
          process.emitStdout(
            jsonEncode({
              'type': 'turn.completed',
              'usage': {'input_tokens': 1, 'output_tokens': 2},
            }),
          );
          process.exit(0);
        }),
      );

      await harness.turn(
        sessionId: 'session-5',
        messages: [
          {'role': 'user', 'content': 'Hello.'},
        ],
        systemPrompt: 'Be concise.',
      );

      expect(events.whereType<SystemInitEvent>(), isEmpty);
    });

    test('returns a minimal result for an empty turn with no events', () async {
      final process = FakeCodexExecProcess();
      final capturedArgs = <String>[];
      final harness = CodexExecHarness(
        cwd: '/tmp/workspace',
        processFactory:
            (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async {
              return _processFactory(
                capturedArgs,
                process,
                executable,
                arguments,
                workingDirectory: workingDirectory,
                environment: environment,
                includeParentEnvironment: includeParentEnvironment,
              );
            },
        environment: const {'OPENAI_API_KEY': 'sk-test'},
      );
      addTearDown(harness.dispose);

      unawaited(
        Future<void>.microtask(() {
          process.exit(0);
        }),
      );

      final result = await harness.turn(
        sessionId: 'session-6',
        messages: [
          {'role': 'user', 'content': 'No output.'},
        ],
        systemPrompt: 'Be concise.',
      );

      expect(result, isNotEmpty);
    });

    test('turn() writes append prompt and MCP config into CODEX_HOME', () async {
      final process = FakeCodexExecProcess();
      final capturedArgs = <String>[];
      Map<String, String>? capturedEnvironment;
      String? configToml;

      final harness = CodexExecHarness(
        cwd: '/tmp/workspace',
        harnessConfig: const HarnessConfig(
          appendSystemPrompt: 'follow the rules',
          mcpServerUrl: 'http://127.0.0.1:3333/mcp',
          mcpGatewayToken: 'test-token',
        ),
        processFactory:
            (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async {
              capturedEnvironment = environment;
              final codexHome = environment!['CODEX_HOME']!;
              configToml = await File('$codexHome${Platform.pathSeparator}config.toml').readAsString();
              return _processFactory(
                capturedArgs,
                process,
                executable,
                arguments,
                workingDirectory: workingDirectory,
                environment: environment,
                includeParentEnvironment: includeParentEnvironment,
              );
            },
        environment: const {'OPENAI_API_KEY': 'sk-test'},
      );
      addTearDown(harness.dispose);

      unawaited(
        Future<void>.microtask(() {
          process.emitStdout(
            jsonEncode({
              'type': 'turn.completed',
              'usage': {'input_tokens': 1, 'output_tokens': 2},
            }),
          );
          process.exit(0);
        }),
      );

      await harness.turn(
        sessionId: 'session-config',
        messages: [
          {'role': 'user', 'content': 'Hello.'},
        ],
        systemPrompt: '',
      );

      expect(capturedArgs, contains('exec'));
      expect(capturedEnvironment, isNotNull);
      expect(capturedEnvironment!['OPENAI_API_KEY'], 'sk-test');
      expect(capturedEnvironment!['DARTCLAW_MCP_TOKEN'], 'test-token');
      expect(configToml, isNotNull);
      expect(configToml, contains('follow the rules'));
      expect(configToml, contains('[mcp_servers.dartclaw]'));
      expect(configToml, contains('http://127.0.0.1:3333/mcp'));
      expect(configToml, contains('bearer_token_env_var = "DARTCLAW_MCP_TOKEN"'));
    });

    group('SIGKILL escalation', () {
      test('stop() escalates to SIGKILL when process does not exit after SIGTERM', () async {
        final process = FakeCodexExecProcess();
        final spawned = Completer<void>();
        final harness = CodexExecHarness(
          cwd: '/tmp/workspace',
          killGracePeriod: const Duration(milliseconds: 50),
          processFactory:
              (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async {
                if (!spawned.isCompleted) {
                  spawned.complete();
                }
                return process;
              },
          environment: const {'OPENAI_API_KEY': 'sk-test'},
        );

        await harness.start();
        final turnFuture = harness.turn(
          sessionId: 'session-stop-escalate',
          messages: [
            {'role': 'user', 'content': 'Hello.'},
          ],
          systemPrompt: '',
        );
        await spawned.future;

        // Schedule process exit after SIGKILL would be sent.
        Timer(const Duration(milliseconds: 100), () => process.exit(137));

        await harness.stop();
        await turnFuture;

        expect(harness.state, WorkerState.stopped);
        expect(process.killSignals, hasLength(greaterThanOrEqualTo(2)));
        expect(process.killSignals.first, ProcessSignal.sigterm);
        if (!Platform.isWindows) {
          expect(process.killSignals.last, ProcessSignal.sigkill);
        }
      });

      test('stop() does not escalate to SIGKILL when process exits promptly on SIGTERM', () async {
        final process = FakeCodexExecProcess(completeExitOnKill: true);
        final spawned = Completer<void>();
        final harness = CodexExecHarness(
          cwd: '/tmp/workspace',
          killGracePeriod: const Duration(seconds: 5),
          processFactory:
              (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async {
                if (!spawned.isCompleted) {
                  spawned.complete();
                }
                return process;
              },
          environment: const {'OPENAI_API_KEY': 'sk-test'},
        );

        await harness.start();
        final turnFuture = harness.turn(
          sessionId: 'session-stop-term',
          messages: [
            {'role': 'user', 'content': 'Hello.'},
          ],
          systemPrompt: '',
        );
        await spawned.future;

        await harness.stop();
        await turnFuture;

        expect(harness.state, WorkerState.stopped);
        expect(process.killSignals, [ProcessSignal.sigterm]);
      });
    });
  });
}
