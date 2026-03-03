import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/mcp/mcp_router.dart';
import 'package:dartclaw_server/src/mcp/mcp_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

class _EchoTool implements McpTool {
  @override
  String get name => 'echo';
  @override
  String get description => 'Echoes input back';
  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'text': {'type': 'string'},
    },
  };

  @override
  Future<String> call(Map<String, dynamic> args) async => args['text'] as String;
}

void main() {
  const token = 'test-gateway-token';
  late Handler handler;
  late McpProtocolHandler mcpHandler;

  setUp(() {
    mcpHandler = McpProtocolHandler();
    mcpHandler.registerTool(_EchoTool());
    handler = mcpRoute(mcpHandler, gatewayToken: token);
  });

  Request post(String body, {String? authToken, String contentType = 'application/json'}) {
    return Request(
      'POST',
      Uri.parse('http://localhost/mcp'),
      body: body,
      headers: {
        if (authToken != null) 'authorization': 'Bearer $authToken',
        'content-type': contentType,
      },
    );
  }

  Request get$({String? authToken}) {
    return Request(
      'GET',
      Uri.parse('http://localhost/mcp'),
      headers: {
        if (authToken != null) 'authorization': 'Bearer $authToken',
      },
    );
  }

  group('mcpRoute', () {
    test('POST with valid token returns JSON-RPC response', () async {
      final body = jsonEncode({
        'jsonrpc': '2.0',
        'method': 'initialize',
        'id': 1,
      });
      final response = await handler(post(body, authToken: token));
      expect(response.statusCode, 200);
      final responseBody = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(responseBody['jsonrpc'], '2.0');
      expect(responseBody['id'], 1);
      expect(responseBody['result'], isNotNull);
    });

    test('POST without auth returns 401', () async {
      final body = jsonEncode({'jsonrpc': '2.0', 'method': 'initialize', 'id': 1});
      final response = await handler(post(body));
      expect(response.statusCode, 401);
    });

    test('POST with wrong token returns 401', () async {
      final body = jsonEncode({'jsonrpc': '2.0', 'method': 'initialize', 'id': 1});
      final response = await handler(post(body, authToken: 'wrong-token'));
      expect(response.statusCode, 401);
    });

    test('POST with malformed auth header returns 401', () async {
      final body = jsonEncode({'jsonrpc': '2.0', 'method': 'initialize', 'id': 1});
      final request = Request(
        'POST',
        Uri.parse('http://localhost/mcp'),
        body: body,
        headers: {
          'authorization': 'Basic dXNlcjpwYXNz',
          'content-type': 'application/json',
        },
      );
      final response = await handler(request);
      expect(response.statusCode, 401);
    });

    test('POST with wrong Content-Type returns 415', () async {
      final body = jsonEncode({'jsonrpc': '2.0', 'method': 'initialize', 'id': 1});
      final response = await handler(post(body, authToken: token, contentType: 'text/plain'));
      expect(response.statusCode, 415);
    });

    test('GET returns 405', () async {
      final response = await handler(get$(authToken: token));
      expect(response.statusCode, 405);
    });

    test('notification returns 202 Accepted', () async {
      final body = jsonEncode({
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      });
      final response = await handler(post(body, authToken: token));
      expect(response.statusCode, 202);
    });

    test('tools/list returns registered tools', () async {
      final body = jsonEncode({
        'jsonrpc': '2.0',
        'method': 'tools/list',
        'id': 2,
      });
      final response = await handler(post(body, authToken: token));
      expect(response.statusCode, 200);
      final responseBody = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      final tools = (responseBody['result'] as Map)['tools'] as List;
      expect(tools, hasLength(1));
      expect((tools[0] as Map)['name'], 'echo');
    });

    test('tools/call dispatches correctly', () async {
      final body = jsonEncode({
        'jsonrpc': '2.0',
        'method': 'tools/call',
        'params': {'name': 'echo', 'arguments': {'text': 'world'}},
        'id': 3,
      });
      final response = await handler(post(body, authToken: token));
      expect(response.statusCode, 200);
      final responseBody = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      final content = (responseBody['result'] as Map)['content'] as List;
      expect((content[0] as Map)['text'], 'world');
    });
  });
}
