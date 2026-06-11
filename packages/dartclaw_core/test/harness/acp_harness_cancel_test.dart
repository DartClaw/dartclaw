import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

import 'acp_test_support.dart';

void main() {
  group('ACP S05 cancellation and close', () {
    test('active cancel sends session/cancel and returns one terminal result', () async {
      final process = FakeAcpProcess();
      final harness = _harnessFor(process);
      addTearDown(harness.dispose);

      final startFuture = harness.start();
      await process.respondTo('initialize', {'protocolVersion': 1});
      await startFuture;

      final turnFuture = harness.turn(
        sessionId: 'session-1',
        messages: const [
          {'role': 'user', 'content': 'slow'},
        ],
        systemPrompt: '',
      );
      await process.respondTo('session/new', {'sessionId': 'acp-session-1'});
      await process.waitForRequest('session/prompt');
      final cancelFuture = harness.cancel();
      await process.respondTo('session/cancel', {});
      await cancelFuture;
      await process.respondTo('session/close', {});

      final result = await turnFuture;

      expect(result['stop_reason'], 'cancelled');
      expect(process.capturedStdinJson.map((message) => message['method']), contains('session/cancel'));
      expect(process.killCalled, isTrue);
      expect(harness.state, WorkerState.stopped);
    });

    test('session close failure does not leave harness busy', () async {
      final process = FakeAcpProcess();
      final harness = _harnessFor(process);
      addTearDown(harness.dispose);

      final startFuture = harness.start();
      await process.respondTo('initialize', {'protocolVersion': 1});
      await startFuture;

      final turnFuture = harness.turn(
        sessionId: 'session-1',
        messages: const [
          {'role': 'user', 'content': 'hello'},
        ],
        systemPrompt: '',
      );
      await process.respondTo('session/new', {'sessionId': 'acp-session-1'});
      await process.respondTo('session/prompt', {'text': 'done'});
      await process.failRequest('session/close', 'close failed');

      final result = await turnFuture;

      expect(result['response'], 'done');
      expect(harness.state, WorkerState.idle);
    });
  });
}

AcpHarness _harnessFor(FakeAcpProcess process) {
  return AcpHarness(
    cwd: '/',
    processFactory: (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async =>
        process,
  );
}
