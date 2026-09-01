import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_runtime/src/server.dart' show ServerCoreDeps, ServerTurnDeps;
import 'package:dartclaw_runtime/src/server_composition.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' show Request;
import 'package:test/test.dart';

/// A client token authenticates `/mcp` and nothing else: it must never satisfy
/// the gateway bearer, mint a session cookie, or pass the `?token=` bootstrap,
/// because those are the whole web UI and REST API.
void main() {
  const gatewayToken = 'gateway-token-for-confinement';
  const clientToken = 'ide-client-token-for-confinement';

  late Directory tempDir;
  late DartclawServer server;

  setUpAll(() async {
    final uri = await Isolate.resolvePackageUri(Uri.parse('package:dartclaw_runtime/dartclaw_runtime.dart'));
    final libDir = File.fromUri(uri!).parent;
    initTemplates(p.join(libDir.path, 'src', 'templates'));
  });
  tearDownAll(() => resetTemplates());

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_mcp_confinement_');
    final sessions = SessionService(baseDir: tempDir.path);
    final messages = MessageService(baseDir: tempDir.path);
    final worker = FakeAgentHarness();
    server = composeServer(
      core: ServerCoreDeps(
        sessions: sessions,
        messages: messages,
        worker: worker,
        dataDir: tempDir.path,
        assetSource: AssetSource.embedded,
        gatewayToken: gatewayToken,
        tokenService: TokenService(token: gatewayToken),
        config: const DartclawConfig(
          gateway: GatewayConfig(
            token: gatewayToken,
            mcpClients: [
              McpClientConfig(name: 'ide', tokenReference: r'${DARTCLAW_MCP_CLIENT_IDE}', token: clientToken),
            ],
          ),
        ),
      ),
      turn: ServerTurnDeps(
        turns: composeServerTurns(
          sessions: sessions,
          messages: messages,
          worker: worker,
          behavior: BehaviorFileService(workspaceDir: p.join(tempDir.path, 'workspace')),
        ),
      ),
    );
  });

  tearDown(() async {
    await server.shutdown();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Request mcpPost(String bearer) => Request(
    'POST',
    Uri.parse('http://localhost/mcp'),
    body: jsonEncode({'jsonrpc': '2.0', 'method': 'initialize', 'id': 1}),
    headers: {'host': 'localhost', 'authorization': 'Bearer $bearer', 'content-type': 'application/json'},
  );

  test('the client token authenticates /mcp', () async {
    expect((await server.handler(mcpPost(clientToken))).statusCode, 200);
    expect((await server.handler(mcpPost(gatewayToken))).statusCode, 200);
    expect((await server.handler(mcpPost('neither-token'))).statusCode, 401);
  });

  test('the client token is rejected on a REST API route exactly as an invalid token is', () async {
    final asClient = await server.handler(
      Request('GET', Uri.parse('http://localhost/api/sessions'), headers: {'authorization': 'Bearer $clientToken'}),
    );
    final asGarbage = await server.handler(
      Request('GET', Uri.parse('http://localhost/api/sessions'), headers: {'authorization': 'Bearer nonsense'}),
    );

    expect(asClient.statusCode, 401);
    expect(asClient.statusCode, asGarbage.statusCode);
    expect(asClient.headers['set-cookie'], isNull);
  });

  test('the client token is rejected on a web UI page and issues no session cookie', () async {
    final response = await server.handler(
      Request(
        'GET',
        Uri.parse('http://localhost/sessions'),
        headers: {'authorization': 'Bearer $clientToken', 'accept': 'text/html'},
      ),
    );

    expect(response.statusCode, 302);
    expect(response.headers['location'], startsWith('/login'));
    expect(response.headers['set-cookie'], isNull);
  });

  test('the client token does not satisfy the ?token= bootstrap', () async {
    final asClient = await server.handler(Request('GET', Uri.parse('http://localhost/sessions?token=$clientToken')));
    final asOwner = await server.handler(Request('GET', Uri.parse('http://localhost/sessions?token=$gatewayToken')));

    expect(asClient.headers['set-cookie'], isNull);
    expect(asClient.statusCode, 401);
    expect(asOwner.headers['set-cookie'], isNotNull, reason: 'the gateway token still bootstraps a session');
  });
}
