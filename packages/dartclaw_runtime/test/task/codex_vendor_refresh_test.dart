import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show CapturingFakeProcess;
import 'package:test/test.dart';

void main() {
  group('refreshCodexAuth', () {
    late CapturingFakeProcess server;
    late Map<String, String>? spawnEnvironment;

    setUp(() {
      server = CapturingFakeProcess(completeExitOnKill: true);
      spawnEnvironment = null;
    });

    /// Answers the request named [method] the way `codex app-server` does, once
    /// the driver has written it.
    Future<void> answer(String method, {bool asError = false}) async {
      for (var attempt = 0; attempt < 100; attempt++) {
        final request = server.capturedStdinJson.where((message) => message['method'] == method).lastOrNull;
        if (request != null) {
          server.emitStdout(
            jsonEncode(
              asError
                  ? {
                      'id': request['id'],
                      'error': <String, Object?>{'message': 'not initialized'},
                    }
                  : {
                      'id': request['id'],
                      'result': <String, Object?>{'authMethod': 'chatgpt'},
                    },
            ),
          );
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      fail('the driver never sent a "$method" request');
    }

    Future<void> refresh({
      Duration timeout = const Duration(seconds: 5),
      Map<String, String> baseEnvironment = const {'PATH': '/usr/bin'},
    }) => refreshCodexAuth(
      '/dedicated',
      timeout: timeout,
      baseEnvironment: baseEnvironment,
      processFactory: (executable, arguments, {workingDirectory, environment, includeParentEnvironment = true}) async {
        expect(executable, 'codex');
        expect(arguments, ['app-server']);
        spawnEnvironment = environment == null ? null : Map<String, String>.from(environment);
        return server;
      },
    );

    test('handshakes and asks for auth status without requesting the token back', () async {
      final driving = refresh();
      await answer('initialize');
      await answer('getAuthStatus');
      await driving;

      expect(server.capturedStdinJson.map((message) => message['method']), [
        'initialize',
        'initialized',
        'getAuthStatus',
      ]);
      expect(server.capturedStdinJson.first['params'], {
        'clientInfo': {'name': 'dartclaw', 'version': dartclawVersion},
      });
      // No refresh flag: the conditional form is what makes the call idempotent
      // and safe on every use, and no token is asked for in return.
      expect(server.capturedStdinJson.last['params'], {'includeToken': false});
      expect(server.capturedStdinJson.any((message) => message.containsKey('jsonrpc')), isFalse);
    });

    test('injects the dedicated store as an explicit overlay over a sanitized base', () async {
      final driving = refresh(
        baseEnvironment: const {'PATH': '/usr/bin', 'OPENAI_API_KEY': 'sk-host', 'CODEX_HOME': '/operator/.codex'},
      );
      await answer('initialize');
      await answer('getAuthStatus');
      await driving;

      expect(spawnEnvironment?['CODEX_HOME'], '/dedicated', reason: 'an operator export never wins over the store');
      expect(spawnEnvironment?.containsKey('OPENAI_API_KEY'), isFalse, reason: 'sanitize strips credential variables');
      expect(spawnEnvironment?['PATH'], '/usr/bin');
    });

    test('a refused auth-status request throws without relaying the vendor payload', () async {
      final driving = refresh();
      await answer('initialize');
      await answer('getAuthStatus', asError: true);

      await expectLater(
        driving,
        throwsA(isA<StateError>().having((error) => '$error', 'message', isNot(contains('not initialized')))),
      );
    });

    test('a server that never answers is bounded by the timeout', () async {
      await expectLater(refresh(timeout: const Duration(milliseconds: 50)), throwsA(isA<TimeoutException>()));
      expect(server.killCalled, isTrue, reason: 'the vendor process is not left running behind a timed-out drive');
    });
  });
}
