import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/mcp/mcp_server.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Lightweight McpTool stubs — same names as real tools but no dependencies.
// This tests the protocol handler's registration + tools/list pipeline.
// ---------------------------------------------------------------------------

class _StubTool implements McpTool {
  @override
  final String name;
  @override
  final String description;
  @override
  final Map<String, dynamic> inputSchema;

  _StubTool(this.name, {String? description})
      : description = description ?? 'Stub $name',
        inputSchema = {'type': 'object', 'properties': {}};

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async =>
      ToolResult.text('ok');
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

String _request(String method, {Object? id, Map<String, dynamic>? params}) {
  return jsonEncode({
    'jsonrpc': '2.0',
    'method': method,
    if (id != null) 'id': id, // ignore: use_null_aware_elements
    if (params != null) 'params': params, // ignore: use_null_aware_elements
  });
}

Future<List<Map<String, dynamic>>> _toolsList(McpProtocolHandler handler) async {
  final raw = await handler.handleRequest(_request('tools/list', id: 1));
  final response = jsonDecode(raw!) as Map<String, dynamic>;
  final result = response['result'] as Map<String, dynamic>;
  return (result['tools'] as List).cast<Map<String, dynamic>>();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('MCP tool discovery', () {
    late McpProtocolHandler handler;

    setUp(() {
      handler = McpProtocolHandler();
    });

    test('tools/list returns all registered tools', () async {
      handler.registerTool(_StubTool('alpha'));
      handler.registerTool(_StubTool('beta'));
      handler.registerTool(_StubTool('gamma'));

      final tools = await _toolsList(handler);
      final names = tools.map((t) => t['name']).toSet();
      expect(names, containsAll(['alpha', 'beta', 'gamma']));
      expect(tools, hasLength(3));
    });

    test('tools/list includes memory, sessions, and web_fetch tools', () async {
      for (final name in [
        'memory_save',
        'memory_search',
        'memory_read',
        'sessions_send',
        'sessions_spawn',
        'web_fetch',
      ]) {
        handler.registerTool(_StubTool(name));
      }

      final tools = await _toolsList(handler);
      final names = tools.map((t) => t['name']).toSet();
      expect(names, containsAll([
        'memory_save',
        'memory_search',
        'memory_read',
        'sessions_send',
        'sessions_spawn',
        'web_fetch',
      ]));
      expect(tools, hasLength(6));
    });

    test('tools/list includes search tools when registered', () async {
      handler.registerTool(_StubTool('brave_search'));
      handler.registerTool(_StubTool('tavily_search'));

      final tools = await _toolsList(handler);
      final names = tools.map((t) => t['name']).toSet();
      expect(names, containsAll(['brave_search', 'tavily_search']));
    });

    test('tools/list includes custom tools via registerTool()', () async {
      handler.registerTool(_StubTool('memory_save'));
      handler.registerTool(_StubTool('web_fetch'));
      handler.registerTool(_StubTool('my_custom_tool',
          description: 'A custom tool registered via the SDK'));

      final tools = await _toolsList(handler);
      final names = tools.map((t) => t['name']).toSet();
      expect(names, contains('my_custom_tool'));

      final custom = tools.firstWhere((t) => t['name'] == 'my_custom_tool');
      expect(custom['description'], contains('custom tool'));
    });

    test('tools/list empty when no tools registered', () async {
      final tools = await _toolsList(handler);
      expect(tools, isEmpty);
    });
  });
}
