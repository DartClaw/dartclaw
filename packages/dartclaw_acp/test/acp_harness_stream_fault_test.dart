import 'dart:async';

import 'package:dartclaw_acp/dartclaw_acp.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

import 'acp_test_support.dart';

void main() {
  group('ACP stream faults', () {
    test('a turn whose stdout ends mid-character fails naming the stream', () async {
      final stdoutController = StreamController<List<int>>();
      final process = FakeAcpProcess(stdoutController: stdoutController, closeStreamsOnExit: false);
      final harness = _harnessFor(process);
      addTearDown(harness.dispose);

      final startFuture = harness.start();
      await process.respondTo('initialize', {'protocolVersion': 1});
      await startFuture;

      final turn = harness.turn(
        sessionId: 'session-truncated',
        messages: const [
          {'role': 'user', 'content': 'go'},
        ],
        systemPrompt: '',
      );
      await process.respondTo('session/new', {'sessionId': 'acp-session-1'});
      await process.waitForRequest('session/prompt');

      // A provider killed mid-emoji leaves `utf8.decoder` holding a partial
      // sequence that only throws when the stream ends.
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
      // Teardown is started by the fault and runs past the failed turn.
      await pumpEventQueue();
      expect(process.killCalled, isTrue);
      expect(harness.isRootProcessTerminationConfirmed, isTrue);
    });

    test('a turn whose stderr ends mid-character fails naming the stream', () async {
      final stderrController = StreamController<List<int>>();
      final process = FakeAcpProcess(stderrController: stderrController, closeStreamsOnExit: false);
      final harness = _harnessFor(process);
      addTearDown(harness.dispose);

      final startFuture = harness.start();
      await process.respondTo('initialize', {'protocolVersion': 1});
      await startFuture;

      final turn = harness.turn(
        sessionId: 'session-truncated',
        messages: const [
          {'role': 'user', 'content': 'go'},
        ],
        systemPrompt: '',
      );
      await process.respondTo('session/new', {'sessionId': 'acp-session-1'});
      await process.waitForRequest('session/prompt');

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
      // Teardown is started by the fault and runs past the failed turn.
      await pumpEventQueue();
      expect(process.killCalled, isTrue);
      expect(harness.isRootProcessTerminationConfirmed, isTrue);
    });

    test('a fault on a replaced process leaves the running agent alone', () async {
      final firstStderr = StreamController<List<int>>();
      final first = FakeAcpProcess(stderrController: firstStderr, closeStreamsOnExit: false);
      final second = FakeAcpProcess();
      final spawned = <FakeAcpProcess>[first, second];
      final harness = AcpHarness(
        cwd: '/',
        terminationGracePeriod: Duration.zero,
        processFactory: (
          executable,
          arguments, {
          workingDirectory,
          environment,
          includeParentEnvironment = true,
        }) async => spawned.removeAt(0),
      );
      addTearDown(harness.dispose);

      final firstStart = harness.start();
      await first.respondTo('initialize', {'protocolVersion': 1});
      await firstStart;
      await harness.stop();

      final secondStart = harness.start();
      await second.respondTo('initialize', {'protocolVersion': 1});
      await secondStart;

      // The replaced process still owns a live stderr subscription: nothing
      // cancels it, so its death rattle must not reach the running agent.
      firstStderr.add([65, 0xC3]);
      await firstStderr.close();
      await pumpEventQueue();

      expect(second.killCalled, isFalse);
      expect(harness.state, WorkerState.idle);
    });

    test('a fault during the handshake fails start without waiting out the initialize timeout', () async {
      final stderrController = StreamController<List<int>>();
      final process = FakeAcpProcess(stderrController: stderrController, closeStreamsOnExit: false);
      final harness = AcpHarness(
        cwd: '/',
        terminationGracePeriod: Duration.zero,
        initializeTimeout: const Duration(seconds: 30),
        processFactory: (
          executable,
          arguments, {
          workingDirectory,
          environment,
          includeParentEnvironment = true,
        }) async => process,
      );
      addTearDown(harness.dispose);

      final startFuture = harness.start();
      await process.waitForRequest('initialize');
      stderrController.add([65, 0xC3]);
      await stderrController.close();

      await expectLater(
        startFuture.timeout(const Duration(seconds: 5)),
        throwsA(isA<AcpHarnessException>().having((error) => error.code, 'code', 'ACP_INIT_FAILED')),
      );
      expect(process.killCalled, isTrue);
    });
  });
}

AcpHarness _harnessFor(FakeAcpProcess process) {
  return AcpHarness(
    cwd: '/',
    turnTimeout: const Duration(seconds: 5),
    terminationGracePeriod: Duration.zero,
    processFactory: (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async =>
        process,
  );
}
