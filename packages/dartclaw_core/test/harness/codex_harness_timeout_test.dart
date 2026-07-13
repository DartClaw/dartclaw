import 'dart:async';
import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart' show PlatformCapabilities;
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  test('Codex timeout finishes teardown before an immediate next turn restarts', () async {
    final timedOut = FakeCodexProcess(completeExitOnKill: true);
    final recovered = FakeCodexProcess(completeExitOnKill: true, pid: 4243);
    final processes = [timedOut, recovered];
    var spawnIndex = 0;
    final harness = CodexHarness(
      cwd: '/tmp',
      executable: 'codex',
      processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async =>
          processes[spawnIndex++],
      commandProbe: defaultCommandProbe,
      delayFactory: noOpDelay,
      environment: const {'OPENAI_API_KEY': 'sk-test-key'},
      killGracePeriod: Duration.zero,
      turnTimeout: const Duration(milliseconds: 200),
    );
    addTearDown(() async => harness.dispose());
    await startHarness(harness, timedOut);

    final timedOutTurn = harness.turn(
      sessionId: 'timed-out',
      messages: const [
        {'role': 'user', 'content': 'never starts'},
      ],
      systemPrompt: '',
    );
    await waitForSentMessage(timedOut, 'thread/start');
    await expectLater(timedOutTurn, throwsA(isA<TimeoutException>()));
    expect(harness.state, WorkerState.stopped);

    final recoveredTurn = harness.turn(
      sessionId: 'recovered',
      messages: const [
        {'role': 'user', 'content': 'works'},
      ],
      systemPrompt: '',
    );
    await waitForSentMessage(recovered, 'initialize');
    recovered.emitInitializeResponse(id: latestRequestId(recovered, 'initialize'));
    await waitForSentMessage(recovered, 'thread/start');
    recovered.emitThreadStartResponse(id: latestRequestId(recovered, 'thread/start'));
    await waitForSentMessage(recovered, 'turn/start');
    recovered.emitTurnCompleted(inputTokens: 1, outputTokens: 1);

    expect(await recoveredTurn, containsPair('stop_reason', 'completed'));
    expect(spawnIndex, 2);
  });

  test('busy stop requests Windows hard termination only once', () async {
    final process = FakeCodexProcess(completeExitOnKill: true);
    final harness = CodexHarness(
      cwd: '/tmp',
      executable: 'codex',
      processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async => process,
      commandProbe: defaultCommandProbe,
      delayFactory: noOpDelay,
      environment: const {'OPENAI_API_KEY': 'sk-test-key'},
      killGracePeriod: Duration.zero,
      platformCapabilities: PlatformCapabilities(
        operatingSystem: 'windows',
        environment: const {'USERPROFILE': r'C:\Users\dev'},
      ),
    );
    addTearDown(() async => harness.dispose());
    await startHarness(harness, process);

    final turn = harness.turn(
      sessionId: 'busy-windows-stop',
      messages: const [
        {'role': 'user', 'content': 'wait'},
      ],
      systemPrompt: '',
    );
    await waitForSentMessage(process, 'thread/start');
    process.emitThreadStartResponse(id: latestRequestId(process, 'thread/start'));
    await waitForSentMessage(process, 'turn/start');
    final turnExpectation = expectLater(turn, throwsStateError);
    await harness.stop();

    await turnExpectation;
    expect(process.killSignals, [ProcessSignal.sigterm]);
    await expectLater(harness.start(), throwsStateError);
  });
}
