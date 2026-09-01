import 'package:dartclaw_acp/dartclaw_acp.dart';
import 'package:test/test.dart';

import 'acp_test_support.dart';

void main() {
  group('ACP S02 client JSON-RPC framing', () {
    test('records initialize session prompt cancel and close requests', () async {
      final process = FakeAcpProcess();
      final client = AcpClient(process.stdout, process.stdin);
      addTearDown(client.close);

      final initializeFuture = client.initialize();
      final initialize = await process.waitForRequest('initialize');
      expect(initialize['jsonrpc'], '2.0');
      final initializeParams = initialize['params'] as Map;
      expect(initializeParams, containsPair('protocolVersion', 1));
      expect(initializeParams['clientCapabilities'], {
        'fs': {'readTextFile': false, 'writeTextFile': false},
        'terminal': false,
      });
      expect(initializeParams, isNot(contains('capabilities')));
      await process.respondTo('initialize', {'protocolVersion': 1});
      await initializeFuture;

      final sessionFuture = client.createSession(cwd: '/repo');
      await process.respondTo('session/new', {'sessionId': 's1'});
      expect(await sessionFuture, 's1');

      final promptFuture = client.prompt(sessionId: 's1', text: 'hello');
      await process.respondTo('session/prompt', {'text': 'world'});
      expect((await promptFuture).text, 'world');

      final cancelFuture = client.cancel('s1');
      await process.respondTo('session/cancel', {});
      await cancelFuture;

      final closeFuture = client.closeSession('s1');
      await process.respondTo('session/close', {});
      await closeFuture;

      expect(process.capturedStdinJson.map((message) => message['method']), [
        'initialize',
        'session/new',
        'session/prompt',
        'session/cancel',
        'session/close',
      ]);
    });

    test('session/new without sessionId fails without using a substituted id', () async {
      final process = FakeAcpProcess();
      final client = AcpClient(process.stdout, process.stdin);
      addTearDown(client.close);

      final sessionFuture = client.createSession(cwd: '/repo');
      await process.respondTo('session/new', {});

      await expectLater(
        sessionFuture,
        throwsA(
          isA<AcpHarnessException>()
              .having((error) => error.code, 'code', 'ACP_PROTOCOL_VIOLATION')
              .having((error) => error.message, 'message', contains('sessionId')),
        ),
      );
      expect(
        process.capturedStdinJson.map((message) => message['method']),
        isNot(contains(anyOf('session/prompt', 'session/cancel', 'session/close'))),
      );
    });
  });
}
