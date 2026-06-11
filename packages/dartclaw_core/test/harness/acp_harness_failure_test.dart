import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

import 'acp_test_support.dart';

void main() {
  group('ACP S04 structured failures', () {
    test('spawn failure is structured as SPAWN_FAILED', () async {
      final harness = AcpHarness(
        cwd: '/',
        processFactory:
            (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async =>
                throw const ProcessException('missing-goose', [], 'not found'),
      );
      addTearDown(harness.dispose);

      await expectLater(
        harness.start(),
        throwsA(isA<AcpHarnessException>().having((error) => error.code, 'code', 'SPAWN_FAILED')),
      );
    });

    test('initialize failure is structured as ACP_INIT_FAILED and kills process', () async {
      final process = FakeAcpProcess();
      final harness = _harnessFor(process);
      addTearDown(harness.dispose);

      final startFuture = harness.start();
      await process.failRequest('initialize', 'bad init');

      await expectLater(
        startFuture,
        throwsA(isA<AcpHarnessException>().having((error) => error.code, 'code', 'ACP_INIT_FAILED')),
      );
      expect(process.killCalled, isTrue);
    });

    test('initialize failure escalates when the process ignores termination', () async {
      final process = FakeAcpProcess(completeExitOnKill: false);
      final harness = _harnessFor(process);
      addTearDown(harness.dispose);

      final startFuture = harness.start();
      await process.failRequest('initialize', 'bad init');

      await expectLater(
        startFuture,
        throwsA(isA<AcpHarnessException>().having((error) => error.code, 'code', 'ACP_INIT_FAILED')),
      );
      expect(process.killCalled, isTrue);
      expect(process.lastKillSignal, Platform.isWindows ? ProcessSignal.sigterm : ProcessSignal.sigkill);
    });

    test('mid-turn process exit is structured as ACP_PROCESS_EXITED with diagnostics', () async {
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
      process.emitStderr('crashed hard');
      process.exit(9);

      await expectLater(
        turnFuture,
        throwsA(
          isA<AcpHarnessException>()
              .having((error) => error.code, 'code', 'ACP_PROCESS_EXITED')
              .having((error) => error.diagnostics['stderr'], 'stderr', contains('crashed hard')),
        ),
      );
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
