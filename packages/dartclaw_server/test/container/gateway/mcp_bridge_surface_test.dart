import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' show CanonicalTool;
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

import 'gateway_test_support.dart';

const _canonicals = {
  'brave_search': CanonicalTool.webSearch,
  'web_fetch': CanonicalTool.webFetch,
  'sessions_spawn': CanonicalTool.sessionsSpawn,
};

void main() {
  late McpProtocolHandler registry;
  late List<String> called;

  setUp(() {
    called = [];
    registry = McpProtocolHandler()
      ..registerTool(RecordingMcpTool('brave_search', called))
      ..registerTool(RecordingMcpTool('web_fetch', called))
      ..registerTool(RecordingMcpTool('sessions_spawn', called))
      ..registerTool(RecordingMcpTool('kg_add', called));
  });

  group('bridged MCP discovery', () {
    test('exposes nothing to an authority with no configured allowlist', () async {
      final surface = _surface(registry, const {});

      expect(await _listTools(surface), isEmpty);
    });

    test('exposes only the implementations behind an allowed canonical name', () async {
      final surface = _surface(registry, {'web_search'});

      expect(await _listTools(surface), ['brave_search']);
    });

    test('resolves several canonical names at once', () async {
      final surface = _surface(registry, {'web_search', 'web_fetch'});

      expect(await _listTools(surface), containsAll(['brave_search', 'web_fetch']));
      expect(await _listTools(surface), isNot(contains('sessions_spawn')));
    });

    test('never exposes a tool that has no explicit canonical mapping', () async {
      // `mcp_call` is the canonical for every unmapped tool at once, so
      // honouring it would turn one allowlist entry into a registry-wide
      // wildcard covering outbound third-party MCP adapters.
      expect(await _listTools(_surface(registry, {'web_search'})), isNot(contains('kg_add')));
      expect(await _listTools(_surface(registry, {'mcp_call'})), isEmpty);
      expect((await _call(_surface(registry, {'mcp_call'}), 'kg_add'))['error'], isNotNull);
    });
  });

  group('bridged MCP authorization', () {
    test('dispatches an authorized call to the host implementation', () async {
      final surface = _surface(registry, {'web_search'});

      final response = await _call(surface, 'brave_search');

      expect(response['result'], isNotNull);
      expect(called, ['brave_search']);
    });

    test('denies an unapproved tool before it reaches the implementation', () async {
      final denials = <String>[];
      final surface = _surface(registry, {'web_search'}, onDenied: denials.add);

      // The client calls directly rather than relying on the filtered listing:
      // client-side suppression is not the enforcement point.
      final response = await _call(surface, 'sessions_spawn');

      expect(response['error'], isNotNull);
      expect(called, isEmpty);
      expect(denials, ['sessions_spawn']);
    });

    test('denies every tool when the authority has no allowlist', () async {
      final surface = _surface(registry, const {});

      expect((await _call(surface, 'brave_search'))['error'], isNotNull);
      expect(called, isEmpty);
    });

    test('answers a denied and an unregistered tool with the same shape', () async {
      final surface = _surface(registry, {'web_search'});

      final denied = (await _call(surface, 'sessions_spawn'))['error'] as Map<String, Object?>;
      final unknown = (await _call(surface, 'no_such_tool'))['error'] as Map<String, Object?>;

      // A scoped caller must not be able to tell "exists but denied" from
      // "does not exist" — only the echoed name differs.
      expect(denied['code'], unknown['code']);
      expect(denied['message'], 'Tool not available: sessions_spawn');
      expect(unknown['message'], 'Tool not available: no_such_tool');
    });

    test('two authorities on the same registry get their own policy', () async {
      final searcher = _surface(registry, {'web_search'});
      final fetcher = _surface(registry, {'web_fetch'});

      expect((await _call(searcher, 'brave_search'))['result'], isNotNull);
      expect((await _call(fetcher, 'brave_search'))['error'], isNotNull);
      expect((await _call(fetcher, 'web_fetch'))['result'], isNotNull);
      expect(called, ['brave_search', 'web_fetch']);
    });

    test('refuses a non-POST request', () async {
      final surface = _surface(registry, {'web_search'});

      await expectLater(
        surface.handle(_request(method: 'GET', body: '')),
        throwsA(isA<GatewayDenied>().having((e) => e.status, 'status', 405)),
      );
    });

    test('refuses a body beyond the bridged request cap', () async {
      final surface = _surface(registry, {'web_search'}, maxRequestBytes: 32);

      await expectLater(
        surface.handle(_request(body: 'x' * 128)),
        throwsA(isA<GatewayDenied>().having((e) => e.status, 'status', 413)),
      );
    });
  });
}

McpBridgeSurface _surface(
  McpProtocolHandler registry,
  Set<String> allowed, {
  void Function(String toolName)? onDenied,
  int maxRequestBytes = 1024 * 1024,
}) => McpBridgeSurface(
  handler: registry,
  principal: principal(logicalAgentId: 'search-agent'),
  allowedCanonicalTools: allowed,
  toolCanonicals: _canonicals,
  onDenied: onDenied == null ? null : (_, toolName) => onDenied(toolName),
  maxRequestBytes: maxRequestBytes,
);

GatewayRequest _request({String method = 'POST', required String body}) => GatewayRequest(
  principal: principal(),
  method: method,
  path: '/mcp',
  headers: const {},
  body: body.isEmpty ? const Stream<List<int>>.empty() : Stream.value(utf8.encode(body)),
);

Future<List<String>> _listTools(McpBridgeSurface surface) async {
  final response = await _exchange(surface, {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'});
  final tools = (response['result'] as Map<String, Object?>)['tools'] as List<Object?>;
  return [for (final tool in tools) (tool as Map<String, Object?>)['name'] as String];
}

Future<Map<String, Object?>> _call(McpBridgeSurface surface, String toolName) => _exchange(surface, {
  'jsonrpc': '2.0',
  'id': 2,
  'method': 'tools/call',
  'params': {'name': toolName, 'arguments': <String, Object?>{}},
});

Future<Map<String, Object?>> _exchange(McpBridgeSurface surface, Map<String, Object?> request) async {
  final response = await surface.handle(_request(body: jsonEncode(request)));
  expect(response.status, 200);
  final body = utf8.decode((await response.body.toList()).expand((chunk) => chunk).toList());
  return jsonDecode(body) as Map<String, Object?>;
}
