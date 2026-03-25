import 'dart:async';

import 'package:dartclaw_core/src/harness/claude_code_harness.dart';
import 'package:dartclaw_core/src/harness/codex_harness.dart';
import 'package:dartclaw_core/src/harness/process_types.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

CodexHarness _buildHarness({
  required FakeCodexProcess Function() processFactory,
  DelayFactory delayFactory = noOpDelay,
  int maxRetries = 5,
  Duration baseBackoff = const Duration(seconds: 5),
}) {
  return CodexHarness(
    cwd: '/tmp',
    executable: 'codex',
    processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async =>
        processFactory(),
    commandProbe: defaultCommandProbe,
    delayFactory: delayFactory,
    maxRetries: maxRetries,
    baseBackoff: baseBackoff,
    environment: const {'OPENAI_API_KEY': 'sk-test-key'},
  );
}

void main() {
  group('CodexHarness crash recovery + capabilities', () {
    test('crash transitions to WorkerState.crashed', () async {
      final process = FakeCodexProcess();
      final harness = _buildHarness(processFactory: () => process);
      addTearDown(() async => harness.dispose());

      await startHarness(harness, process);
      expect(harness.state, WorkerState.idle);

      process.exit(1);
      await pumpEventLoop();

      expect(harness.state, WorkerState.crashed);
    });

    test('crash recovery uses exponential backoff across repeated crashes', () async {
      final firstProcess = FakeCodexProcess();
      final secondProcess = FakeCodexProcess();
      final thirdProcess = FakeCodexProcess();
      final delays = <Duration>[];
      final processes = <FakeCodexProcess>[firstProcess, secondProcess, thirdProcess];
      var spawnIndex = 0;
      final harness = _buildHarness(
        processFactory: () => processes[spawnIndex++],
        delayFactory: (duration) async {
          delays.add(duration);
        },
      );
      addTearDown(() async => harness.dispose());

      await startHarness(harness, firstProcess);

      firstProcess.exit(1);
      await pumpEventLoop();
      expect(harness.state, WorkerState.crashed);

      final recoveryTurn = harness.turn(
        sessionId: 'sess-backoff',
        messages: [
          {'role': 'user', 'content': 'first recovery'},
        ],
        systemPrompt: 'test',
      );

      await waitForSentMessage(secondProcess, 'initialize');
      secondProcess.exit(1);
      await pumpEventLoop();

      await waitForSentMessage(thirdProcess, 'initialize');
      thirdProcess.emitInitializeResponse(id: latestRequestId(thirdProcess, 'initialize'));
      await respondToLatestThreadStart(thirdProcess, threadId: 'thread-third');
      thirdProcess.emitTurnStarted();
      thirdProcess.emitTurnCompleted(inputTokens: 3, outputTokens: 5);
      await recoveryTurn;

      expect(delays, [const Duration(seconds: 5), const Duration(seconds: 10)]);
    });

    test('max retries exceeded throws StateError', () async {
      final process = FakeCodexProcess();
      final harness = _buildHarness(processFactory: () => process, maxRetries: 0);
      addTearDown(() async => harness.dispose());

      await startHarness(harness, process);

      process.exit(1);
      await pumpEventLoop();

      expect(harness.state, WorkerState.crashed);

      await expectLater(
        harness.turn(
          sessionId: 'sess-max-retries',
          messages: [
            {'role': 'user', 'content': 'try again'},
          ],
          systemPrompt: 'test',
        ),
        throwsA(isA<StateError>().having((error) => error.message, 'message', contains('max retries exceeded'))),
      );
    });

    test('successful turn after crash resets crash count to base backoff', () async {
      final firstProcess = FakeCodexProcess();
      final secondProcess = FakeCodexProcess();
      final thirdProcess = FakeCodexProcess();
      final delays = <Duration>[];
      final processes = <FakeCodexProcess>[firstProcess, secondProcess, thirdProcess];
      var spawnIndex = 0;
      final harness = _buildHarness(
        processFactory: () => processes[spawnIndex++],
        delayFactory: (duration) async {
          delays.add(duration);
        },
      );
      addTearDown(() async => harness.dispose());

      await startHarness(harness, firstProcess);

      firstProcess.exit(1);
      await pumpEventLoop();

      final firstRecovery = harness.turn(
        sessionId: 'sess-reset-backoff',
        messages: [
          {'role': 'user', 'content': 'recover once'},
        ],
        systemPrompt: 'test',
      );

      await waitForSentMessage(secondProcess, 'initialize');
      secondProcess.emitInitializeResponse(id: latestRequestId(secondProcess, 'initialize'));
      await respondToLatestThreadStart(secondProcess, threadId: 'thread-second');
      secondProcess.emitTurnStarted();
      secondProcess.emitTurnCompleted(inputTokens: 1, outputTokens: 2);
      await firstRecovery;

      secondProcess.exit(1);
      await pumpEventLoop();

      final secondRecovery = harness.turn(
        sessionId: 'sess-reset-backoff',
        messages: [
          {'role': 'user', 'content': 'recover twice'},
        ],
        systemPrompt: 'test',
      );

      await waitForSentMessage(thirdProcess, 'initialize');
      thirdProcess.emitInitializeResponse(id: latestRequestId(thirdProcess, 'initialize'));
      await respondToLatestThreadStart(thirdProcess, threadId: 'thread-third');
      thirdProcess.emitTurnStarted();
      thirdProcess.emitTurnCompleted(inputTokens: 3, outputTokens: 4);
      await secondRecovery;

      expect(delays, [const Duration(seconds: 5), const Duration(seconds: 5)]);
    });

    test('new thread is created after a crash recovery turn', () async {
      final firstProcess = FakeCodexProcess();
      final secondProcess = FakeCodexProcess();
      final harness = _buildHarness(
        processFactory: (() {
          var callCount = 0;
          return () {
            callCount += 1;
            return callCount == 1 ? firstProcess : secondProcess;
          };
        })(),
      );
      addTearDown(() async => harness.dispose());

      await startHarness(harness, firstProcess);

      final firstTurn = harness.turn(
        sessionId: 'sess-thread',
        messages: [
          {'role': 'user', 'content': 'before crash'},
        ],
        systemPrompt: 'test',
      );
      await pumpEventLoop();
      await respondToLatestThreadStart(firstProcess, threadId: 'thread-a');
      firstProcess.emitTurnCompleted(inputTokens: 1, outputTokens: 1);
      await firstTurn;

      final firstThreadStart = firstProcess.sentMessages.singleWhere((message) => message['method'] == 'thread/start');
      final firstThreadId = (firstThreadStart['params'] as Map<String, dynamic>)['thread_id'] as String;

      firstProcess.exit(1);
      await pumpEventLoop();
      expect(harness.state, WorkerState.crashed);

      final recoveryTurn = harness.turn(
        sessionId: 'sess-thread',
        messages: [
          {'role': 'user', 'content': 'after crash'},
        ],
        systemPrompt: 'test',
      );

      await waitForSentMessage(secondProcess, 'initialize');
      secondProcess.emitInitializeResponse(id: latestRequestId(secondProcess, 'initialize'));
      await respondToLatestThreadStart(secondProcess, threadId: 'thread-b');
      secondProcess.emitTurnStarted();
      secondProcess.emitTurnCompleted(inputTokens: 2, outputTokens: 3);

      await expectLater(recoveryTurn, completes);

      final secondThreadStart = secondProcess.sentMessages.singleWhere(
        (message) => message['method'] == 'thread/start',
      );
      final secondThreadId = (secondThreadStart['params'] as Map<String, dynamic>)['thread_id'] as String;
      expect(secondThreadId, isNot(equals(firstThreadId)));
    });

    test('stale process exit is ignored after intentional restart', () async {
      final firstExitCode = Completer<int>();
      final firstProcess = FakeCodexProcess(exitCodeFuture: firstExitCode.future);
      final secondProcess = FakeCodexProcess();
      final processes = <FakeCodexProcess>[firstProcess, secondProcess];
      var spawnIndex = 0;
      final harness = _buildHarness(
        processFactory: () => processes[spawnIndex++],
      );
      addTearDown(() async => harness.dispose());

      await startHarness(harness, firstProcess);
      await harness.stop();
      expect(harness.state, WorkerState.stopped);

      await startHarness(harness, secondProcess);
      expect(harness.state, WorkerState.idle);

      firstExitCode.complete(1);
      await pumpEventLoop();
      expect(harness.state, WorkerState.idle);
    });

    test('CodexHarness reports capability defaults', () {
      final harness = CodexHarness(cwd: '/tmp');
      final dynamic dynamicHarness = harness;

      expect(dynamicHarness.supportsCostReporting, isFalse);
      expect(dynamicHarness.supportsToolApproval, isTrue);
      expect(dynamicHarness.supportsStreaming, isTrue);
      expect(dynamicHarness.supportsCachedTokens, isTrue);
    });

    test('ClaudeCodeHarness reports capability defaults', () {
      final harness = ClaudeCodeHarness(cwd: '/tmp');
      final dynamic dynamicHarness = harness;

      expect(dynamicHarness.supportsCostReporting, isTrue);
      expect(dynamicHarness.supportsToolApproval, isTrue);
      expect(dynamicHarness.supportsStreaming, isTrue);
      expect(dynamicHarness.supportsCachedTokens, isFalse);
    });

    test('FakeAgentHarness capability configuration is constructor-driven', () {
      final harness =
          Function.apply(FakeAgentHarness.new, const [], <Symbol, dynamic>{
                #supportsCostReporting: false,
                #supportsToolApproval: false,
                #supportsStreaming: false,
                #supportsCachedTokens: true,
              })
              as FakeAgentHarness;

      final dynamic dynamicHarness = harness;
      expect(dynamicHarness.supportsCostReporting, isFalse);
      expect(dynamicHarness.supportsToolApproval, isFalse);
      expect(dynamicHarness.supportsStreaming, isFalse);
      expect(dynamicHarness.supportsCachedTokens, isTrue);
    });
  });
}
