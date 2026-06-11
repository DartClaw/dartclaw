import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

import 'acp_test_support.dart';

void main() {
  group('ACP S03 auth handling', () {
    test('authenticated initialize continues without terminal interaction', () async {
      final process = FakeAcpProcess();
      final harness = _harnessFor(process);
      addTearDown(harness.dispose);

      final startFuture = harness.start();
      await process.respondTo('initialize', {
        'auth': {'status': 'authenticated'},
      });
      await startFuture;

      expect(harness.state, WorkerState.idle);
    });

    test('auth-required initialize returns ACP_AUTH_REQUIRED and closes the subprocess', () async {
      final process = FakeAcpProcess();
      final harness = _harnessFor(process);
      addTearDown(harness.dispose);

      final startFuture = harness.start();
      await process.respondTo('initialize', {
        'auth': {'status': 'required'},
      });

      await expectLater(
        startFuture,
        throwsA(isA<AcpHarnessException>().having((error) => error.code, 'code', 'ACP_AUTH_REQUIRED')),
      );
      expect(process.killCalled, isTrue);
    });

    test('auth-required prompt returns ACP_AUTH_REQUIRED and closes the subprocess', () async {
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
      await process.respondTo('session/prompt', {
        'auth': {'status': 'required'},
      });
      await process.respondTo('session/close', {});

      await expectLater(
        turnFuture,
        throwsA(isA<AcpHarnessException>().having((error) => error.code, 'code', 'ACP_AUTH_REQUIRED')),
      );
      expect(process.killCalled, isTrue);
      expect(harness.state, WorkerState.stopped);
    });

    test('auth-required prompt still stops when session close does not answer', () async {
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
      await process.respondTo('session/prompt', {
        'auth': {'status': 'required'},
      });
      await process.waitForRequest('session/close');

      await expectLater(
        turnFuture,
        throwsA(isA<AcpHarnessException>().having((error) => error.code, 'code', 'ACP_AUTH_REQUIRED')),
      );
      expect(process.killCalled, isTrue);
      expect(harness.state, WorkerState.stopped);
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
