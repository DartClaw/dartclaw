import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('McpToolRegistry', () {
    late McpToolRegistry registry;

    setUp(() {
      registry = McpToolRegistry();
    });

    test('register and dispatch returns result', () async {
      registry.registerServer('test-server', [
        McpToolDef(
          name: 'echo',
          description: 'Echoes input',
          inputSchema: {'type': 'object', 'properties': <String, dynamic>{}},
          handler: (args) async => {
            'content': [{'type': 'text', 'text': 'echo: ${args['text']}'}],
          },
        ),
      ]);

      final result = await registry.dispatch('echo', {'text': 'hello'});
      expect(result['content'], isA<List<dynamic>>());
      final text = (result['content'] as List).first['text'] as String;
      expect(text, 'echo: hello');
    });

    test('dispatch unknown tool returns error', () async {
      final result = await registry.dispatch('nonexistent', {});
      expect(result['isError'], true);
      final text = (result['content'] as List).first['text'] as String;
      expect(text, contains('Unknown tool'));
    });

    test('dispatch timeout returns error (no crash)', () async {
      registry.registerServer('slow-server', [
        McpToolDef(
          name: 'slow_tool',
          description: 'Takes forever',
          inputSchema: {'type': 'object', 'properties': <String, dynamic>{}},
          handler: (args) async {
            await Future<void>.delayed(const Duration(seconds: 10));
            return {'content': [{'type': 'text', 'text': 'done'}]};
          },
          timeout: const Duration(milliseconds: 50),
        ),
      ]);

      final result = await registry.dispatch('slow_tool', {});
      expect(result['isError'], true);
      final text = (result['content'] as List).first['text'] as String;
      expect(text, contains('timeout'));
    });

    test('toSdkMcpServers generates correct format', () {
      registry.registerServer('my-server', [
        McpToolDef(
          name: 'tool_a',
          description: 'Tool A',
          inputSchema: {'type': 'object', 'properties': {'x': {'type': 'string'}}},
          handler: (args) async => {},
        ),
        McpToolDef(
          name: 'tool_b',
          description: 'Tool B',
          inputSchema: {'type': 'object', 'properties': <String, dynamic>{}},
          handler: (args) async => {},
        ),
      ]);

      final servers = registry.toSdkMcpServers();
      expect(servers.containsKey('my-server'), isTrue);
      final server = servers['my-server'] as Map<String, dynamic>;
      expect(server['type'], 'sdk_mcp_server');
      final tools = server['tools'] as List;
      expect(tools.length, 2);
      expect(tools[0]['name'], 'tool_a');
      expect(tools[1]['name'], 'tool_b');
    });

    test('duplicate tool name skips second registration', () async {
      registry.registerServer('server-1', [
        McpToolDef(
          name: 'dup',
          description: 'First',
          inputSchema: {'type': 'object', 'properties': <String, dynamic>{}},
          handler: (args) async => {'content': [{'type': 'text', 'text': 'first'}]},
        ),
      ]);
      registry.registerServer('server-2', [
        McpToolDef(
          name: 'dup',
          description: 'Second',
          inputSchema: {'type': 'object', 'properties': <String, dynamic>{}},
          handler: (args) async => {'content': [{'type': 'text', 'text': 'second'}]},
        ),
      ]);

      // First registered wins
      final result = await registry.dispatch('dup', {});
      final text = (result['content'] as List).first['text'] as String;
      expect(text, 'first');
    });

    test('handler exception returns error result', () async {
      registry.registerServer('err-server', [
        McpToolDef(
          name: 'err_tool',
          description: 'Throws',
          inputSchema: {'type': 'object', 'properties': <String, dynamic>{}},
          handler: (args) async => throw StateError('boom'),
        ),
      ]);

      final result = await registry.dispatch('err_tool', {});
      expect(result['isError'], true);
      final text = (result['content'] as List).first['text'] as String;
      expect(text, contains('boom'));
    });

    test('isEmpty reflects registration state', () {
      expect(registry.isEmpty, isTrue);
      registry.registerServer('s', [
        McpToolDef(
          name: 't',
          description: '',
          inputSchema: {},
          handler: (args) async => {},
        ),
      ]);
      expect(registry.isEmpty, isFalse);
    });
  });
}
