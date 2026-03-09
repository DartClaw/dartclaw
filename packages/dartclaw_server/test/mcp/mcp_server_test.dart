import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/mcp/mcp_server.dart';
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
    'required': ['text'],
  };

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async =>
      ToolResult.text(args['text'] as String);
}

class _FailTool implements McpTool {
  @override
  String get name => 'fail';
  @override
  String get description => 'Always fails';
  @override
  Map<String, dynamic> get inputSchema => {'type': 'object', 'properties': {}};

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    throw StateError('intentional failure');
  }
}

class _ErrorTool implements McpTool {
  @override
  String get name => 'error_tool';
  @override
  String get description => 'Returns ToolResult.error';
  @override
  Map<String, dynamic> get inputSchema => {'type': 'object', 'properties': {}};

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async =>
      ToolResult.error('something went wrong');
}

class _SlowTool implements McpTool {
  @override
  String get name => 'slow';
  @override
  String get description => 'Waits briefly before returning';
  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'id': {'type': 'string'},
    },
  };

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return ToolResult.text('done-${args['id']}');
  }
}

void main() {
  late McpProtocolHandler handler;

  setUp(() {
    handler = McpProtocolHandler();
    handler.registerTool(_EchoTool());
  });

  String request(String method, {Object? id, Map<String, dynamic>? params}) {
    return jsonEncode({
      'jsonrpc': '2.0',
      'method': method,
      if (id != null) 'id': id, // ignore: use_null_aware_elements
      if (params != null) 'params': params, // ignore: use_null_aware_elements
    });
  }

  Map<String, dynamic> decode(String? response) {
    expect(response, isNotNull);
    return jsonDecode(response!) as Map<String, dynamic>;
  }

  group('McpProtocolHandler', () {
    test('initialize returns protocol version and capabilities', () async {
      final response = decode(await handler.handleRequest(request('initialize', id: 1)));
      expect(response['jsonrpc'], '2.0');
      expect(response['id'], 1);
      final result = response['result'] as Map<String, dynamic>;
      expect(result['protocolVersion'], '2025-03-26');
      expect(result['serverInfo']['name'], 'dartclaw');
      expect(result['capabilities']['tools'], isNotNull);
    });

    test('tools/list returns registered tools', () async {
      final response = decode(await handler.handleRequest(request('tools/list', id: 2)));
      final result = response['result'] as Map<String, dynamic>;
      final tools = result['tools'] as List;
      expect(tools, hasLength(1));
      final tool = tools[0] as Map<String, dynamic>;
      expect(tool['name'], 'echo');
      expect(tool['description'], 'Echoes input back');
      expect(tool['inputSchema'], isNotNull);
    });

    test('tools/call dispatches to correct handler', () async {
      final response = decode(await handler.handleRequest(
        request('tools/call', id: 3, params: {'name': 'echo', 'arguments': {'text': 'hello'}}),
      ));
      final result = response['result'] as Map<String, dynamic>;
      final content = result['content'] as List;
      expect(content[0]['text'], 'hello');
    });

    test('tools/call with unknown tool returns error', () async {
      final response = decode(await handler.handleRequest(
        request('tools/call', id: 4, params: {'name': 'nonexistent'}),
      ));
      expect(response['error'], isNotNull);
      expect((response['error'] as Map)['code'], -32602);
      expect((response['error'] as Map)['message'], contains('Unknown tool'));
    });

    test('tools/call with missing name returns error', () async {
      final response = decode(await handler.handleRequest(
        request('tools/call', id: 5, params: {}),
      ));
      expect(response['error'], isNotNull);
      expect((response['error'] as Map)['code'], -32602);
    });

    test('tools/call with tool failure returns isError result', () async {
      handler.registerTool(_FailTool());
      final response = decode(await handler.handleRequest(
        request('tools/call', id: 6, params: {'name': 'fail'}),
      ));
      final result = response['result'] as Map<String, dynamic>;
      expect(result['isError'], isTrue);
      final content = result['content'] as List;
      expect(content[0]['text'], contains('Tool execution failed'));
    });

    test('unknown method returns method not found error', () async {
      final response = decode(await handler.handleRequest(
        request('unknown/method', id: 7),
      ));
      expect(response['error'], isNotNull);
      expect((response['error'] as Map)['code'], -32601);
    });

    test('notification returns null (no response)', () async {
      final response = await handler.handleRequest(
        request('notifications/initialized'),
      );
      expect(response, isNull);
    });

    test('invalid JSON returns parse error', () async {
      final response = decode(await handler.handleRequest('not json'));
      expect(response['error'], isNotNull);
      expect((response['error'] as Map)['code'], -32700);
    });

    test('missing jsonrpc field returns invalid request', () async {
      final response = decode(await handler.handleRequest(
        jsonEncode({'method': 'initialize', 'id': 1}),
      ));
      expect(response['error'], isNotNull);
      expect((response['error'] as Map)['code'], -32600);
    });

    test('non-object body returns invalid request', () async {
      final response = decode(await handler.handleRequest(jsonEncode([1, 2, 3])));
      expect(response['error'], isNotNull);
      expect((response['error'] as Map)['code'], -32600);
    });

    test('registerTool after start throws', () async {
      await handler.handleRequest(request('initialize', id: 1));
      expect(() => handler.registerTool(_EchoTool()), throwsA(isA<StateError>()));
    });

    test('duplicate tool registration is skipped', () {
      // First echo already registered in setUp
      handler.registerTool(_EchoTool()); // should not throw
      expect(handler.toolNames, hasLength(1));
    });

    test('tool returning ToolResult.error produces isError response', () async {
      handler.registerTool(_ErrorTool());
      final response = decode(await handler.handleRequest(
        request('tools/call', id: 8, params: {'name': 'error_tool'}),
      ));
      expect(response['error'], isNull);
      final result = response['result'] as Map<String, dynamic>;
      expect(result['isError'], isTrue);
      final content = result['content'] as List;
      expect(content[0]['text'], 'something went wrong');
    });

    test('concurrent tool calls both complete', () async {
      handler.registerTool(_SlowTool());
      final futures = [
        handler.handleRequest(
          request('tools/call', id: 9, params: {'name': 'slow', 'arguments': {'id': 'a'}}),
        ),
        handler.handleRequest(
          request('tools/call', id: 10, params: {'name': 'slow', 'arguments': {'id': 'b'}}),
        ),
      ];
      final responses = await Future.wait(futures);
      final resultA = (jsonDecode(responses[0]!) as Map<String, dynamic>)['result'] as Map;
      final resultB = (jsonDecode(responses[1]!) as Map<String, dynamic>)['result'] as Map;
      expect((resultA['content'] as List)[0]['text'], 'done-a');
      expect((resultB['content'] as List)[0]['text'], 'done-b');
    });
  });
}
