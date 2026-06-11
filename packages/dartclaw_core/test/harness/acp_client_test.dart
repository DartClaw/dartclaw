import 'package:dartclaw_core/dartclaw_core.dart';
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
      expect(initialize['params'], containsPair('protocolVersion', 1));
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
  });
}
