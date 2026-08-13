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
  Future<ToolResult> call(Map<String, dynamic> args) async => ToolResult.text(args['text'] as String);
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

  Request post(
    String body, {
    String? authToken,
    String contentType = 'application/json',
    String host = 'localhost',
    String? origin,
  }) {
    return Request(
      'POST',
      Uri.parse('http://localhost/mcp'),
      body: body,
      headers: {
        'host': host,
        'origin': ?origin,
        if (authToken != null) 'authorization': 'Bearer $authToken',
        'content-type': contentType,
      },
    );
  }

  Request get$({String? authToken}) {
    return Request(
      'GET',
      Uri.parse('http://localhost/mcp'),
      headers: {if (authToken != null) 'authorization': 'Bearer $authToken'},
    );
  }

  group('mcpRoute', () {
    test('bearerless route cannot be created without loopback Host validation', () {
      expect(() => mcpRoute(mcpHandler), throwsArgumentError);
    });

    test('POST with valid token returns JSON-RPC response', () async {
      final body = jsonEncode({'jsonrpc': '2.0', 'method': 'initialize', 'id': 1});
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

    test('POST without auth succeeds when no gateway token is configured', () async {
      final unauthenticatedHandler = mcpRoute(mcpHandler, requireLoopbackHost: true);
      final body = jsonEncode({'jsonrpc': '2.0', 'method': 'initialize', 'id': 1});

      final response = await unauthenticatedHandler(post(body));

      expect(response.statusCode, 200);
    });

    test('bearerless access rejects non-loopback and malformed Host values', () async {
      final unauthenticatedHandler = mcpRoute(mcpHandler, requireLoopbackHost: true);
      final body = jsonEncode({'jsonrpc': '2.0', 'method': 'initialize', 'id': 1});

      for (final host in [
        'localhost.evil.example',
        '127.0.0.1.evil.example',
        'localhost@evil.example',
        'localhost/path',
        'localhost?query',
        'localhost#fragment',
        'bad host',
      ]) {
        final response = await unauthenticatedHandler(post(body, host: host));
        expect(response.statusCode, 403, reason: host);
      }
    });

    test('browser access requires an exact loopback Origin host', () async {
      final unauthenticatedHandler = mcpRoute(mcpHandler, requireLoopbackHost: true);
      final body = jsonEncode({'jsonrpc': '2.0', 'method': 'initialize', 'id': 1});

      for (final origin in [
        'http://localhost.evil.example:3333',
        'http://127.0.0.1.evil.example:3333',
        'http://localhost@evil.example:3333',
        'not a uri',
      ]) {
        final response = await unauthenticatedHandler(post(body, origin: origin));
        expect(response.statusCode, 403, reason: origin);
      }
      expect((await unauthenticatedHandler(post(body, origin: 'http://localhost:3333'))).statusCode, 200);
      expect(
        (await unauthenticatedHandler(post(body, host: '[::1]:3333', origin: 'http://[::1]:3333'))).statusCode,
        200,
      );
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
        headers: {'authorization': 'Basic dXNlcjpwYXNz', 'content-type': 'application/json'},
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
      final body = jsonEncode({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
      final response = await handler(post(body, authToken: token));
      expect(response.statusCode, 202);
    });

    test('tools/list returns registered tools', () async {
      final body = jsonEncode({'jsonrpc': '2.0', 'method': 'tools/list', 'id': 2});
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
        'params': {
          'name': 'echo',
          'arguments': {'text': 'world'},
        },
        'id': 3,
      });
      final response = await handler(post(body, authToken: token));
      expect(response.statusCode, 200);
      final responseBody = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      final content = (responseBody['result'] as Map)['content'] as List;
      expect((content[0] as Map)['text'], 'world');
    });

    test('oversized body without Content-Length is rejected with 413', () async {
      // Simulates a chunked or header-omitted delivery exceeding 1 MiB.
      // The header check alone would not catch this — the bounded stream read must.
      final oversize = 'x' * (1024 * 1024 + 1);
      final request = Request(
        'POST',
        Uri.parse('http://localhost/mcp'),
        body: oversize,
        headers: {
          'authorization': 'Bearer $token',
          'content-type': 'application/json',
          // Deliberately omit content-length to prove the read-time limit fires.
        },
      );
      final response = await handler(request);
      expect(response.statusCode, 413);
      final responseBody = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      expect(responseBody['error'], contains('Payload too large'));
    });
  });
}
