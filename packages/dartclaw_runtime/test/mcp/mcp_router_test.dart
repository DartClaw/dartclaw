import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show McpClientConfig;
import 'package:dartclaw_runtime/src/auth/auth_rate_limiter.dart';
import 'package:dartclaw_runtime/src/mcp/mcp_router.dart';
import 'package:dartclaw_runtime/src/mcp/mcp_server.dart';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

class _ProfileTool implements McpTool {
  new(this.name, this.access);

  @override
  final String name;
  @override
  final McpToolAccess access;

  @override
  String get description => 'test tool $name';
  @override
  Map<String, dynamic> get inputSchema => {'type': 'object', 'properties': <String, dynamic>{}};

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async => ToolResult.text('called $name');
}

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
  McpToolAccess get access => McpToolAccess.read;

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

  group('mcpRoute with configured MCP clients', () {
    const clientToken = 'ide-client-token';
    const client = McpClientConfig(name: 'ide', tokenReference: r'${DARTCLAW_MCP_CLIENT_IDE}', token: clientToken);

    late McpProtocolHandler clientsHandler;
    late Handler routed;

    setUp(() {
      clientsHandler = McpProtocolHandler();
      for (final tool in [
        _ProfileTool('memory_search', McpToolAccess.read),
        _ProfileTool('kg_query', McpToolAccess.read),
        _ProfileTool('kg_add', McpToolAccess.write),
        _ProfileTool('brave_search', McpToolAccess.read),
      ]) {
        clientsHandler.registerTool(tool);
      }
      routed = mcpRoute(clientsHandler, gatewayToken: token, clients: const [client]);
    });

    Future<List<String>> toolNames(String bearer) async {
      final body = jsonEncode({'jsonrpc': '2.0', 'method': 'tools/list', 'id': 1});
      final response = await routed(post(body, authToken: bearer));
      final decoded = jsonDecode(await response.readAsString()) as Map<String, dynamic>;
      return ((decoded['result'] as Map<String, dynamic>)['tools'] as List)
          .map((tool) => (tool as Map<String, dynamic>)['name'] as String)
          .toList();
    }

    test('a client list without a gateway token is refused at construction', () {
      expect(() => mcpRoute(clientsHandler, requireLoopbackHost: true, clients: const [client]), throwsArgumentError);
    });

    test('the gateway token still reaches every registered tool', () async {
      expect(await toolNames(token), unorderedEquals(['memory_search', 'kg_query', 'kg_add', 'brave_search']));
    });

    test('a client token reaches the context-engine profile only', () async {
      expect(await toolNames(clientToken), unorderedEquals(['memory_search', 'kg_query']));
    });

    test('a client call outside the profile is refused without reaching the tool', () async {
      final body = jsonEncode({
        'jsonrpc': '2.0',
        'method': 'tools/call',
        'id': 1,
        'params': {'name': 'kg_add', 'arguments': <String, dynamic>{}},
      });
      final response = await routed(post(body, authToken: clientToken));
      final decoded = jsonDecode(await response.readAsString()) as Map<String, dynamic>;

      expect((decoded['error'] as Map<String, dynamic>)['code'], -32601);
      expect(decoded['result'], isNull);
    });

    test('an unrecognised bearer and a missing bearer are both 401', () async {
      final body = jsonEncode({'jsonrpc': '2.0', 'method': 'initialize', 'id': 1});

      expect((await routed(post(body, authToken: 'not-a-configured-token'))).statusCode, 401);
      expect((await routed(post(body))).statusCode, 401);
    });

    test("a removed client's token no longer authenticates once the route is rebuilt", () async {
      final withoutClient = mcpRoute(clientsHandler, gatewayToken: token);
      final body = jsonEncode({'jsonrpc': '2.0', 'method': 'initialize', 'id': 1});

      expect((await withoutClient(post(body, authToken: clientToken))).statusCode, 401);
      expect((await withoutClient(post(body, authToken: token))).statusCode, 200);
    });

    test('repeated failures are throttled by the same failed-auth limiter that protects the gateway token', () async {
      final limiter = AuthRateLimiter(maxAttempts: 2);
      final throttled = mcpRoute(clientsHandler, gatewayToken: token, clients: const [client], rateLimiter: limiter);
      final body = jsonEncode({'jsonrpc': '2.0', 'method': 'initialize', 'id': 1});

      expect((await throttled(post(body, authToken: 'wrong'))).statusCode, 401);
      expect((await throttled(post(body, authToken: 'wrong'))).statusCode, 401);
      expect((await throttled(post(body, authToken: 'wrong'))).statusCode, 429);
      // The throttle gates failures only, so a valid client credential still
      // succeeds — but it does not clear the window. The limiter is shared with
      // `authMiddleware` and keyed by remote alone, so a client token that reset
      // it would let the least-trusted credential the design admits disable the
      // control protecting the gateway token, the REST API and the web UI from
      // that address.
      expect((await throttled(post(body, authToken: clientToken))).statusCode, 200);
      expect((await throttled(post(body, authToken: 'wrong'))).statusCode, 429);
      // Only a gateway-token success clears it.
      expect((await throttled(post(body, authToken: token))).statusCode, 200);
      expect((await throttled(post(body, authToken: 'wrong'))).statusCode, 401);
    });
  });
}
