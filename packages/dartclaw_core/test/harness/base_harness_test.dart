import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/src/harness/agent_harness.dart';
import 'package:dartclaw_core/src/harness/base_harness.dart';
import 'package:dartclaw_core/src/harness/claude_protocol_adapter.dart';
import 'package:dartclaw_core/src/harness/codex_harness.dart';
import 'package:dartclaw_core/src/harness/codex_protocol_adapter.dart';
import 'package:dartclaw_core/src/harness/harness_launch_options.dart';
import 'package:dartclaw_core/src/harness/process_lifecycle.dart';
import 'package:dartclaw_core/src/harness/protocol_adapter.dart';
import 'package:dartclaw_core/src/worker/worker_state.dart' show WorkerState;
import 'package:dartclaw_testing/dartclaw_testing.dart'
    show
        FakeAgentHarness,
        FakeCodexProcess,
        FakeProcess,
        defaultCommandProbe,
        noOpDelay,
        respondToLatestThreadStart,
        startHarness;
import 'package:logging/logging.dart';
import 'package:test/test.dart';

import 'harness_test_support.dart';

final class _LineRecordingHarness extends BaseHarness {
  new(this.adapter, {this.deferBreachTeardown = false})
    : super(
        log: Logger.detached('base-harness-crlf-test'),
        cwd: '/tmp',
        turnTimeout: const Duration(seconds: 1),
        maxRetries: 0,
        baseBackoff: Duration.zero,
        processFactory: Process.start,
        commandProbe: Process.run,
        delayFactory: Future<void>.delayed,
        harnessConfig: const HarnessLaunchOptions(),
      );

  final ProtocolAdapter adapter;

  /// Holds the breach teardown back so the post-breach admission rules stay observable.
  final bool deferBreachTeardown;
  final parsed = <Object?>[];
  final rawLines = <String>[];
  final stderrLines = <String>[];
  final exitCodes = <int>[];

  Exception? get failure => streamFailure;

  ProcessOutputLimitException? get breach {
    final failure = streamFailure;
    return failure is ProcessOutputLimitException ? failure : null;
  }

  void setOutputCeiling(int maxBytes) => maxOutputBytesPerStream = maxBytes;

  /// Stands in for the turn entry both subprocess harnesses run.
  void enterTurn() => currentState = WorkerState.busy;

  void attach(Process process, {bool watchForUnexpectedExit = false}) =>
      attachProcess(process, dropEmptyStdoutLines: true, watchForUnexpectedExit: watchForUnexpectedExit);

  bool get ownsProcess => currentProcess != null;

  Future<void> shutdownForTest() => shutdownCurrentProcess(
    label: 'test harness',
    gracePeriod: Duration.zero,
    platformCapabilities: PlatformCapabilities(operatingSystem: 'windows'),
  );

  Future<void> startForTest() => startLifecycle(busyMessage: 'busy', start: () async {});

  Future<void> recoverForTest(Future<void> Function() restart) {
    currentState = WorkerState.crashed;
    return recoverFromCrash(restart);
  }

  @override
  void handleProcessStdoutLine(String line) {
    rawLines.add(line);
    parsed.add(adapter.parseLine(line));
  }

  @override
  void handleProcessStderrLine(String line) {
    stderrLines.add(line);
  }

  @override
  void handleUnexpectedProcessExit(int exitCode) {
    exitCodes.add(exitCode);
  }

  @override
  Future<void> shutdownAfterStreamFailure() async {
    if (deferBreachTeardown) return;
    await shutdownCurrentProcess(
      label: 'test harness',
      gracePeriod: Duration.zero,
      platformCapabilities: PlatformCapabilities(operatingSystem: 'linux'),
    );
  }

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> cancel() async {}

  @override
  Future<TurnResult> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    Map<String, dynamic>? mcpServers,
    String? providerSessionId,
    bool requestProviderSessionResume = false,
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
    String? agentId,
    Map<String, dynamic>? outputSchema,
  }) async => const TurnResult();
}

void main() {
  test('in-memory harnesses explicitly confirm no root-process ownership', () {
    final harness = FakeAgentHarness();
    addTearDown(harness.dispose);

    expect(harness.isRootProcessTerminationConfirmed, isTrue);
  });

  test('shared provider stream parsing tolerates CRLF and split CRLF chunks', () async {
    final cases = <({ProtocolAdapter adapter, Map<String, dynamic> line})>[
      (adapter: ClaudeProtocolAdapter(), line: {'type': 'result', 'stop_reason': 'end_turn', 'is_error': false}),
      (
        adapter: CodexProtocolAdapter(),
        line: {
          'method': 'turn/completed',
          'params': {'usage': <String, dynamic>{}},
        },
      ),
    ];

    for (final testCase in cases) {
      final stdoutController = StreamController<List<int>>();
      final process = FakeProcess(stdoutController: stdoutController);
      final harness = _LineRecordingHarness(testCase.adapter)..attach(process);
      addTearDown(harness.dispose);
      final encoded = utf8.encode(jsonEncode(testCase.line));

      stdoutController.add([...encoded, 13]);
      stdoutController.add([10, 13, 10]);
      await pumpEventQueue();

      expect(harness.rawLines, [jsonEncode(testCase.line)]);
      expect(harness.rawLines.single, isNot(contains('\r')));
      expect(harness.parsed.single, isNotNull);
      await stdoutController.close();
    }
  });

  test('confirmed Windows root exit releases direct ownership after shutdown', () async {
    final process = FakeProcess(completeExitOnKill: true);
    final harness = _LineRecordingHarness(ClaudeProtocolAdapter())..attach(process, watchForUnexpectedExit: true);
    addTearDown(harness.dispose);

    expect(harness.isRootProcessTerminationConfirmed, isFalse);

    await harness.shutdownForTest();

    expect(harness.ownsProcess, isFalse);
    expect(harness.isRootProcessTerminationConfirmed, isTrue);
    await expectLater(harness.startForTest(), completes);

    await pumpEventQueue();

    expect(harness.ownsProcess, isFalse);
  });

  test('crash recovery cannot replace a process whose exit remains unconfirmed', () async {
    final process = FakeProcess();
    final harness = _LineRecordingHarness(ClaudeProtocolAdapter())..attach(process);
    addTearDown(harness.dispose);
    var restarted = false;

    await harness.shutdownForTest();
    expect(harness.isRootProcessTerminationConfirmed, isFalse);

    await expectLater(
      harness.recoverForTest(() async => restarted = true),
      throwsA(isA<StateError>().having((error) => error.message, 'message', contains('exit has not been confirmed'))),
    );

    expect(restarted, isFalse);
    expect(harness.ownsProcess, isTrue);
  });

  test('per-stream output budgets are independent below the ceiling', () async {
    final stdoutController = StreamController<List<int>>();
    final stderrController = StreamController<List<int>>();
    final process = FakeProcess(
      stdoutController: stdoutController,
      stderrController: stderrController,
      completeExitOnKill: true,
      closeStreamsOnExit: false,
    );
    final harness = _LineRecordingHarness(ClaudeProtocolAdapter())..setOutputCeiling(64);
    harness.attach(process);
    addTearDown(harness.dispose);

    // 60 + 60 exceeds a shared 64-byte budget but neither stream's own budget.
    stdoutController.add(List<int>.filled(60, 120));
    stderrController.add(List<int>.filled(60, 120));
    await pumpEventQueue();

    expect(harness.breach, isNull);
    expect(process.killCalled, isFalse);

    stderrController.add(List<int>.filled(60, 120));
    await pumpEventQueue();

    expect(harness.breach?.streamName, 'stderr');
    expect(process.killCalled, isTrue);
  });

  test('a newline-free stream stays bounded however many turns it spans', () async {
    final stdoutController = StreamController<List<int>>();
    final process = FakeProcess(
      stdoutController: stdoutController,
      completeExitOnKill: true,
      closeStreamsOnExit: false,
    );
    final harness = _LineRecordingHarness(ClaudeProtocolAdapter())..setOutputCeiling(64);
    harness.attach(process);
    addTearDown(harness.dispose);

    // The decoders carry an unterminated line across turn boundaries, so bytes
    // that never reached a newline stay charged no matter how many turns pass –
    // the volume budget the turn entry clears cannot be the one that stops this.
    for (var round = 0; round < 3; round++) {
      harness.enterTurn();
      stdoutController.add(List<int>.filled(60, 120));
      await pumpEventQueue();
    }

    expect(harness.breach?.streamName, 'stdout');
    expect(process.killCalled, isTrue);
    expect(harness.rawLines, isEmpty);
  });

  test('a completed line releases its bytes, so a stream may spend the ceiling again', () async {
    final stdoutController = StreamController<List<int>>();
    final process = FakeProcess(
      stdoutController: stdoutController,
      completeExitOnKill: true,
      closeStreamsOnExit: false,
    );
    final harness = _LineRecordingHarness(ClaudeProtocolAdapter())..setOutputCeiling(64);
    harness.attach(process);
    addTearDown(harness.dispose);

    for (var round = 0; round < 3; round++) {
      harness.enterTurn();
      stdoutController.add([...List<int>.filled(60, 120), 0x0a]);
      await pumpEventQueue();
    }

    expect(harness.breach, isNull);
    expect(process.killCalled, isFalse);
    expect(harness.rawLines, hasLength(3));
  });

  test('completed lines summing past the ceiling breach it inside one turn', () async {
    final stdoutController = StreamController<List<int>>();
    final process = FakeProcess(
      stdoutController: stdoutController,
      completeExitOnKill: true,
      closeStreamsOnExit: false,
    );
    final harness = _LineRecordingHarness(ClaudeProtocolAdapter())..setOutputCeiling(64);
    harness.attach(process);
    addTearDown(harness.dispose);

    // Every line releases its bytes, so outstanding never grows – volume is the
    // only budget that can stop a provider flooding terminated lines.
    harness.enterTurn();
    for (var chunk = 0; chunk < 4; chunk++) {
      stdoutController.add([...List<int>.filled(19, 120), 0x0a]);
      await pumpEventQueue();
    }

    expect(harness.breach?.streamName, 'stdout');
    expect(process.killCalled, isTrue);
    expect(harness.rawLines, hasLength(3));
  });

  test('the volume budget is per turn, so the same traffic across two turns completes', () async {
    final stdoutController = StreamController<List<int>>();
    final process = FakeProcess(
      stdoutController: stdoutController,
      completeExitOnKill: true,
      closeStreamsOnExit: false,
    );
    final harness = _LineRecordingHarness(ClaudeProtocolAdapter())..setOutputCeiling(64);
    harness.attach(process);
    addTearDown(harness.dispose);

    for (var turn = 0; turn < 2; turn++) {
      harness.enterTurn();
      for (var chunk = 0; chunk < 3; chunk++) {
        stdoutController.add([...List<int>.filled(19, 120), 0x0a]);
        await pumpEventQueue();
      }
    }

    expect(harness.breach, isNull);
    expect(process.killCalled, isFalse);
    expect(harness.rawLines, hasLength(6));
  });

  test('a line completed by a later chunk is charged after its own release', () async {
    final stdoutController = StreamController<List<int>>();
    final process = FakeProcess(
      stdoutController: stdoutController,
      completeExitOnKill: true,
      closeStreamsOnExit: false,
    );
    final harness = _LineRecordingHarness(ClaudeProtocolAdapter())..setOutputCeiling(64);
    harness.attach(process);
    addTearDown(harness.dispose);

    // Charging the whole chunk against the headroom left before it would make
    // the real bound `ceiling - chunk size`: this 61-byte line fits the ceiling
    // but its terminating chunk does not fit the 4 bytes left outstanding.
    harness.enterTurn();
    stdoutController.add(List<int>.filled(60, 120));
    await pumpEventQueue();
    harness.enterTurn();
    stdoutController.add([0x0a, 120, 120, 120, 120]);
    await pumpEventQueue();

    expect(harness.breach, isNull);
    expect(process.killCalled, isFalse);
    expect(harness.rawLines, ['x' * 60]);
  });

  test('a CR-terminated progress stream keeps releasing its bytes', () async {
    final stdoutController = StreamController<List<int>>();
    final process = FakeProcess(
      stdoutController: stdoutController,
      completeExitOnKill: true,
      closeStreamsOnExit: false,
    );
    final harness = _LineRecordingHarness(ClaudeProtocolAdapter())..setOutputCeiling(64);
    harness.attach(process);
    addTearDown(harness.dispose);

    // `LineSplitter` ends a line on a lone CR and buffers nothing after it, so
    // an in-place progress meter holds no more than its longest single line.
    for (var round = 0; round < 3; round++) {
      harness.enterTurn();
      stdoutController.add([...List<int>.filled(60, 120), 0x0d]);
      await pumpEventQueue();
    }

    expect(harness.breach, isNull);
    expect(process.killCalled, isFalse);
    expect(harness.rawLines, hasLength(3));
  });

  test('a breach on one stream does not silence the other before teardown', () async {
    final stdoutController = StreamController<List<int>>();
    final stderrController = StreamController<List<int>>();
    final process = FakeProcess(
      stdoutController: stdoutController,
      stderrController: stderrController,
      completeExitOnKill: true,
      closeStreamsOnExit: false,
    );
    final harness = _LineRecordingHarness(ClaudeProtocolAdapter(), deferBreachTeardown: true)..setOutputCeiling(64);
    harness.attach(process);
    addTearDown(harness.dispose);

    stdoutController.add(List<int>.filled(128, 120));
    await pumpEventQueue();
    expect(harness.breach?.streamName, 'stdout');

    // Provider diagnostics on the quiet stream are what a bounded-output kill
    // is diagnosed from, so the breach must not silence them too.
    stderrController.add(utf8.encode('provider said why\n'));
    stdoutController.add(utf8.encode('{"type":"ignored"}\n'));
    await pumpEventQueue();

    expect(harness.stderrLines, ['provider said why']);
    expect(harness.rawLines, isEmpty);
    expect(harness.breach?.streamName, 'stdout');
  });

  test('a Claude turn flooded on stdout fails naming the stream and the ceiling', () async {
    final stdoutController = StreamController<List<int>>();
    final process = FakeProcess(
      stdoutController: stdoutController,
      completeExitOnKill: true,
      closeStreamsOnExit: false,
    );
    final harness = buildClaudeHarness(
      processFactory: capturingInitFactory(process: process),
      killGracePeriod: Duration.zero,
    );
    addTearDown(harness.dispose);
    await harness.start();
    harness.maxOutputBytesPerStream = 4096;

    final turn = harness.turn(
      sessionId: 'session-flood',
      messages: const [
        {'role': 'user', 'content': 'go'},
      ],
      systemPrompt: '',
    );
    await pumpEventQueue();
    stdoutController.add(List<int>.filled(5000, 120));

    await expectLater(
      turn,
      throwsA(
        isA<ProcessOutputLimitException>().having(
          (error) => error.message,
          'message',
          allOf(contains('stdout'), contains('4096')),
        ),
      ),
    );
    expect(process.killCalled, isTrue);
    expect(harness.isRootProcessTerminationConfirmed, isTrue);
  });

  test('a Codex turn flooded on stderr fails naming the stream and the ceiling', () async {
    final stderrController = StreamController<List<int>>();
    final process = FakeCodexProcess(stderrController: stderrController, completeExitOnKill: true);
    final harness = CodexHarness(
      cwd: '/tmp',
      processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async => process,
      commandProbe: defaultCommandProbe,
      delayFactory: noOpDelay,
      maxRetries: 0,
      environment: const {'OPENAI_API_KEY': 'sk-test-key'},
      killGracePeriod: Duration.zero,
    );
    addTearDown(harness.dispose);
    await startHarness(harness, process);
    harness.maxOutputBytesPerStream = 4096;

    final turn = harness.turn(
      sessionId: 'session-flood',
      messages: const [
        {'role': 'user', 'content': 'go'},
      ],
      systemPrompt: '',
    );
    await respondToLatestThreadStart(process);
    stderrController.add(List<int>.filled(5000, 120));

    await expectLater(
      turn,
      throwsA(
        isA<ProcessOutputLimitException>().having(
          (error) => error.message,
          'message',
          allOf(contains('stderr'), contains('4096')),
        ),
      ),
    );
    expect(process.killCalled, isTrue);
    expect(harness.isRootProcessTerminationConfirmed, isTrue);
  });

  test('completed protocol lines release the ceiling, so a reused process survives two turns', () async {
    final process = FakeProcess(
      stdoutController: StreamController<List<int>>(),
      completeExitOnKill: true,
      closeStreamsOnExit: false,
    );
    final harness = buildClaudeHarness(
      processFactory: capturingInitFactory(process: process),
      killGracePeriod: Duration.zero,
    );
    addTearDown(harness.dispose);
    await harness.start();

    final resultLine = jsonEncode({'type': 'result', 'result': 'ok', 'is_error': false, 'session_id': 'test-session'});
    // One turn's traffic fits; two turns' together does not unless lines release.
    harness.maxOutputBytesPerStream = resultLine.length + 10;

    Future<void> runTurn() async {
      final turn = harness.turn(
        sessionId: 'session-reuse',
        messages: const [
          {'role': 'user', 'content': 'go'},
        ],
        systemPrompt: '',
      );
      await pumpEventQueue();
      process.emitStdout(resultLine);
      await turn;
    }

    await runTurn();
    await runTurn();

    expect(process.killCalled, isFalse);
    expect(harness.state, WorkerState.idle);
  });

  test('a breach after a partial multi-byte prefix does not surface a decoder failure', () async {
    final stderrController = StreamController<List<int>>();
    final process = FakeProcess(
      stderrController: stderrController,
      completeExitOnKill: true,
      closeStreamsOnExit: false,
    );
    final harness = _LineRecordingHarness(ClaudeProtocolAdapter())..setOutputCeiling(64);
    harness.attach(process);
    addTearDown(harness.dispose);

    // Admitted prefix ends mid two-byte sequence, so flushing the decoder here
    // would raise "Unfinished UTF-8 octet sequence" into an unhandled error.
    stderrController.add([65, 0xC3]);
    stderrController.add(List<int>.filled(128, 120));
    await pumpEventQueue();

    expect(harness.failure, isA<ProcessOutputLimitException>());
    expect(harness.breach?.streamName, 'stderr');
    expect(process.killCalled, isTrue);
  });

  test('breach teardown deletes the generated MCP config holding the gateway token', () async {
    final stdoutController = StreamController<List<int>>();
    final process = FakeProcess(
      stdoutController: stdoutController,
      completeExitOnKill: true,
      closeStreamsOnExit: false,
    );
    List<String>? args;
    var spawns = 0;
    final harness = buildClaudeHarness(
      // The restart needs its own process: the breached one's stdout is spent.
      processFactory: (exe, spawnArgs, {workingDirectory, environment, includeParentEnvironment = true}) async {
        args = spawnArgs;
        final fake = spawns++ == 0 ? process : makeClaudeFakeProcess();
        scheduleMicrotask(() => fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}})));
        return fake;
      },
      harnessConfig: const HarnessLaunchOptions(
        mcpServerUrl: 'http://127.0.0.1:9/mcp',
        mcpGatewayToken: 'gateway-secret',
      ),
      killGracePeriod: Duration.zero,
    );
    addTearDown(harness.dispose);
    await harness.start();

    final configPath = args![args!.indexOf('--mcp-config') + 1];
    expect(File(configPath).readAsStringSync(), contains('gateway-secret'));

    harness.maxOutputBytesPerStream = 4096;
    final turn = harness.turn(
      sessionId: 'session-flood',
      messages: const [
        {'role': 'user', 'content': 'go'},
      ],
      systemPrompt: '',
    );
    await pumpEventQueue();
    stdoutController.add(List<int>.filled(5000, 120));
    await expectLater(turn, throwsA(isA<ProcessOutputLimitException>()));
    await pumpEventQueue();

    // The bearer token must not outlive the process it was written for: the
    // restart overwrites the tracked path, so anything left here is orphaned.
    // The deletion is deliberately not awaited by the caller, so a shutdown
    // that throws still removes the credential - poll rather than making
    // production await it, which would reinstate exactly that leak.
    await _expectDeleted(configPath);

    await harness.start();
    expect(args![args!.indexOf('--mcp-config') + 1], isNot(configPath));
    expect(File(configPath).existsSync(), isFalse);
  });

  test('a crash restart deletes the generated MCP config before overwriting its path', () async {
    final process = FakeProcess(
      stdoutController: StreamController<List<int>>(),
      completeExitOnKill: true,
      closeStreamsOnExit: false,
    );
    List<String>? args;
    var spawns = 0;
    final harness = buildClaudeHarness(
      processFactory: (exe, spawnArgs, {workingDirectory, environment, includeParentEnvironment = true}) async {
        args = spawnArgs;
        final restart = spawns++ > 0;
        final fake = restart ? makeClaudeFakeProcess() : process;
        scheduleMicrotask(() => fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}})));
        if (restart) {
          Future.delayed(const Duration(milliseconds: 20), () {
            fake.emitStdout(jsonEncode({'type': 'result', 'result': 'ok', 'is_error': false, 'session_id': 's'}));
          });
        }
        return fake;
      },
      harnessConfig: const HarnessLaunchOptions(
        mcpServerUrl: 'http://127.0.0.1:9/mcp',
        mcpGatewayToken: 'gateway-secret',
      ),
      killGracePeriod: Duration.zero,
    );
    addTearDown(harness.dispose);
    await harness.start();
    final configPath = args![args!.indexOf('--mcp-config') + 1];
    expect(File(configPath).readAsStringSync(), contains('gateway-secret'));

    // An ordinary provider death restarts through crash recovery, which never
    // stops first – so nothing but the start itself can retire the old file.
    process.exit(1);
    await pumpEventQueue();
    expect(harness.state, WorkerState.crashed);

    await harness.turn(
      sessionId: 'session-restart',
      messages: const [
        {'role': 'user', 'content': 'go'},
      ],
      systemPrompt: '',
    );

    expect(args![args!.indexOf('--mcp-config') + 1], isNot(configPath));
    expect(File(configPath).existsSync(), isFalse);
  });

  test('a stream that ends mid multi-byte sequence faults the harness instead of the isolate', () async {
    for (final stream in ['stdout', 'stderr']) {
      final controller = StreamController<List<int>>();
      final process = FakeProcess(
        stdoutController: stream == 'stdout' ? controller : null,
        stderrController: stream == 'stderr' ? controller : null,
        completeExitOnKill: true,
        closeStreamsOnExit: false,
      );
      final harness = _LineRecordingHarness(ClaudeProtocolAdapter());
      harness.attach(process);
      addTearDown(harness.dispose);

      // A provider killed mid-emoji leaves `utf8.decoder` holding a partial
      // sequence that only throws when the stream ends.
      controller.add([65, 0xC3]);
      await controller.close();
      await pumpEventQueue();

      expect(harness.failure, isA<ProcessStreamException>());
      expect((harness.failure! as ProcessStreamException).streamName, stream);
      expect((harness.failure! as ProcessStreamException).message, contains('Unfinished UTF-8 octet sequence'));
      expect(process.killCalled, isTrue);
    }
  });

  test('a Claude turn whose stdout ends mid-character fails naming the stream', () async {
    final stdoutController = StreamController<List<int>>();
    final process = FakeProcess(
      stdoutController: stdoutController,
      completeExitOnKill: true,
      closeStreamsOnExit: false,
    );
    final harness = buildClaudeHarness(
      processFactory: capturingInitFactory(process: process),
      killGracePeriod: Duration.zero,
    );
    addTearDown(harness.dispose);
    await harness.start();

    final turn = harness.turn(
      sessionId: 'session-truncated',
      messages: const [
        {'role': 'user', 'content': 'go'},
      ],
      systemPrompt: '',
    );
    await pumpEventQueue();
    stdoutController.add([65, 0xC3]);
    await stdoutController.close();

    await expectLater(
      turn,
      throwsA(
        isA<ProcessStreamException>().having(
          (error) => error.message,
          'message',
          allOf(contains('stdout'), contains('Unfinished UTF-8 octet sequence')),
        ),
      ),
    );
    expect(harness.isRootProcessTerminationConfirmed, isTrue);
  });

  test('a Codex turn whose stderr ends mid-character fails naming the stream', () async {
    final stderrController = StreamController<List<int>>();
    final process = FakeCodexProcess(stderrController: stderrController, completeExitOnKill: true);
    final harness = CodexHarness(
      cwd: '/tmp',
      processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async => process,
      commandProbe: defaultCommandProbe,
      delayFactory: noOpDelay,
      maxRetries: 0,
      environment: const {'OPENAI_API_KEY': 'sk-test-key'},
      killGracePeriod: Duration.zero,
    );
    addTearDown(harness.dispose);
    await startHarness(harness, process);

    final turn = harness.turn(
      sessionId: 'session-truncated',
      messages: const [
        {'role': 'user', 'content': 'go'},
      ],
      systemPrompt: '',
    );
    await respondToLatestThreadStart(process);
    stderrController.add([65, 0xC3]);
    await stderrController.close();

    await expectLater(
      turn,
      throwsA(
        isA<ProcessStreamException>().having(
          (error) => error.message,
          'message',
          allOf(contains('stderr'), contains('Unfinished UTF-8 octet sequence')),
        ),
      ),
    );
    expect(harness.isRootProcessTerminationConfirmed, isTrue);
  });

  test('completed Codex protocol lines release the ceiling, so a reused process survives two turns', () async {
    final process = FakeCodexProcess(completeExitOnKill: true);
    final harness = CodexHarness(
      cwd: '/tmp',
      processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async => process,
      commandProbe: defaultCommandProbe,
      delayFactory: noOpDelay,
      maxRetries: 0,
      environment: const {'OPENAI_API_KEY': 'sk-test-key'},
      killGracePeriod: Duration.zero,
    );
    addTearDown(harness.dispose);
    await startHarness(harness, process);
    // Generous enough for one turn's protocol traffic plus the padding line,
    // too small for two turns' worth together.
    harness.maxOutputBytesPerStream = 2000;

    Future<void> runTurn({required bool startsThread}) async {
      final turn = harness.turn(
        sessionId: 'session-reuse',
        messages: const [
          {'role': 'user', 'content': 'go'},
        ],
        systemPrompt: '',
      );
      if (startsThread) {
        await respondToLatestThreadStart(process);
      } else {
        await pumpEventQueue();
      }
      process.emitStdout('x' * 1500);
      process.emitTurnStarted();
      process.emitTurnCompleted(inputTokens: 1, outputTokens: 1);
      await turn;
    }

    await runTurn(startsThread: true);
    await runTurn(startsThread: false);

    expect(process.killCalled, isFalse);
    expect(harness.state, WorkerState.idle);
  });
}

/// Waits for [path] to disappear, or fails after ~2s.
///
/// The MCP config deletion runs from an unawaited `whenComplete`, so the
/// filesystem can lag the assertion under parallel load.
Future<void> _expectDeleted(String path) async {
  for (var i = 0; i < 200; i++) {
    if (!File(path).existsSync()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  fail('Expected $path to be deleted, but it still exists');
}
