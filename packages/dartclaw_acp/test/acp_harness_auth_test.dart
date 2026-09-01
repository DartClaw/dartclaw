import 'package:dartclaw_acp/dartclaw_acp.dart';
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

    for (final unreadableResult in <Object?>[
      {'auth': 'unknown'},
      {'auth': <String, dynamic>{}},
      {'authentication': <String, dynamic>{}},
      {'authRequired': false, 'auth_required': true},
      {
        'authRequired': false,
        'auth': {'status': 'required'},
      },
      {
        'auth': {'authenticated': true, 'status': 'required'},
      },
      {
        'auth': {'authenticated': false, 'status': 'authenticated'},
      },
      {
        'authentication': {'authenticated': true, 'status': 'required'},
      },
      {
        'authentication': {'authenticated': false, 'status': 'authenticated'},
      },
      {
        'auth': {'required': true, 'authenticated': true},
      },
      {
        'authentication': {'required': true, 'status': 'authenticated'},
      },
      {
        'auth': {'required': 'false'},
      },
      'not-an-object',
    ]) {
      test('unreadable initialize auth state fails closed: $unreadableResult', () async {
        final process = FakeAcpProcess();
        final harness = _harnessFor(process);
        addTearDown(harness.dispose);

        final startFuture = harness.start();
        await process.respondTo('initialize', unreadableResult);

        await expectLater(
          startFuture,
          throwsA(isA<AcpHarnessException>().having((error) => error.code, 'code', 'ACP_AUTH_REQUIRED')),
        );
        expect(process.killCalled, isTrue);
      });
    }

    test('initialize without an auth field starts normally', () async {
      final process = FakeAcpProcess();
      final harness = _harnessFor(process);
      addTearDown(harness.dispose);

      final startFuture = harness.start();
      await process.respondTo('initialize', {'protocolVersion': 1});
      await startFuture;

      expect(harness.state, WorkerState.idle);
    });

    test('nested not-required states coexist with affirmative auth states', () async {
      final process = FakeAcpProcess();
      final harness = _harnessFor(process);
      addTearDown(harness.dispose);

      final startFuture = harness.start();
      await process.respondTo('initialize', {
        'auth': {'required': false, 'authenticated': true},
        'authentication': {'required': false, 'status': 'authenticated'},
      });
      await startFuture;

      expect(harness.state, WorkerState.idle);
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

    test('conflicting prompt auth carriers fail closed', () async {
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
        'authRequired': false,
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
