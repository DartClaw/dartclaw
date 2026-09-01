import 'dart:convert';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/src/context/result_trimmer.dart';
import 'package:dartclaw_runtime/src/mcp/mcp_server.dart';
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
  McpToolAccess get access => McpToolAccess.read;

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async => ToolResult.text(args['text'] as String);
}

class _FailTool implements McpTool {
  @override
  String get name => 'fail';
  @override
  String get description => 'Always fails';
  @override
  Map<String, dynamic> get inputSchema => {'type': 'object', 'properties': {}};

  @override
  McpToolAccess get access => McpToolAccess.read;

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
  McpToolAccess get access => McpToolAccess.read;

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async => ToolResult.error('something went wrong');
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
  McpToolAccess get access => McpToolAccess.read;

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return ToolResult.text('done-${args['id']}');
  }
}

/// Returns exactly the text it was configured with, so a test can put a
/// payload of a chosen byte size through `tools/call` dispatch.
class _BulkTool implements McpTool {
  new(this.content);

  final String content;

  @override
  String get name => 'bulk';
  @override
  String get description => 'Returns a fixed payload';
  @override
  Map<String, dynamic> get inputSchema => {'type': 'object', 'properties': {}};

  @override
  McpToolAccess get access => McpToolAccess.read;

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async => ToolResult.text(content);
}

class _AllowAllPolicy implements McpCallerPolicy {
  @override
  bool allows(String toolName) => true;

  @override
  void onDenied(String toolName) {}
}

class _StrictTool implements McpTool {
  @override
  String get name => 'strict';
  @override
  String get description => 'Rejects unknown input';
  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'text': {'type': 'string'},
    },
    'required': ['text'],
    'additionalProperties': false,
  };

  @override
  McpToolAccess get access => McpToolAccess.read;

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async => ToolResult.text(args['text'] as String);
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
      final response = decode(
        await handler.handleRequest(
          request(
            'tools/call',
            id: 3,
            params: {
              'name': 'echo',
              'arguments': {'text': 'hello'},
            },
          ),
        ),
      );
      final result = response['result'] as Map<String, dynamic>;
      final content = result['content'] as List;
      expect(content[0]['text'], 'hello');
    });

    test('tools/call rejects unknown arguments for strict tool schemas', () async {
      handler.registerTool(_StrictTool());
      final response = decode(
        await handler.handleRequest(
          request(
            'tools/call',
            id: 31,
            params: {
              'name': 'strict',
              'arguments': {'text': 'hello', 'extra': true},
            },
          ),
        ),
      );

      expect(response['error'], isNotNull);
      expect((response['error'] as Map)['code'], -32602);
      expect((response['error'] as Map)['message'], contains('unknown argument "extra"'));
    });

    test('tools/call with unknown tool returns error', () async {
      final response = decode(
        await handler.handleRequest(request('tools/call', id: 4, params: {'name': 'nonexistent'})),
      );
      expect(response['error'], isNotNull);
      expect((response['error'] as Map)['code'], -32602);
      expect((response['error'] as Map)['message'], contains('Unknown tool'));
    });

    test('tools/call with missing name returns error', () async {
      final response = decode(await handler.handleRequest(request('tools/call', id: 5, params: {})));
      expect(response['error'], isNotNull);
      expect((response['error'] as Map)['code'], -32602);
    });

    test('tools/call with tool failure returns isError result', () async {
      handler.registerTool(_FailTool());
      final response = decode(await handler.handleRequest(request('tools/call', id: 6, params: {'name': 'fail'})));
      final result = response['result'] as Map<String, dynamic>;
      expect(result['isError'], isTrue);
      final content = result['content'] as List;
      expect(content[0]['text'], contains('Tool execution failed'));
    });

    test('unknown method returns method not found error', () async {
      final response = decode(await handler.handleRequest(request('unknown/method', id: 7)));
      expect(response['error'], isNotNull);
      expect((response['error'] as Map)['code'], -32601);
    });

    test('notification returns null (no response)', () async {
      final response = await handler.handleRequest(request('notifications/initialized'));
      expect(response, isNull);
    });

    test('invalid JSON returns parse error', () async {
      final response = decode(await handler.handleRequest('not json'));
      expect(response['error'], isNotNull);
      expect((response['error'] as Map)['code'], -32700);
    });

    test('missing jsonrpc field returns invalid request', () async {
      final response = decode(await handler.handleRequest(jsonEncode({'method': 'initialize', 'id': 1})));
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
      final response = decode(
        await handler.handleRequest(request('tools/call', id: 8, params: {'name': 'error_tool'})),
      );
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
          request(
            'tools/call',
            id: 9,
            params: {
              'name': 'slow',
              'arguments': {'id': 'a'},
            },
          ),
        ),
        handler.handleRequest(
          request(
            'tools/call',
            id: 10,
            params: {
              'name': 'slow',
              'arguments': {'id': 'b'},
            },
          ),
        ),
      ];
      final responses = await Future.wait(futures);
      final resultA = (jsonDecode(responses[0]!) as Map<String, dynamic>)['result'] as Map;
      final resultB = (jsonDecode(responses[1]!) as Map<String, dynamic>)['result'] as Map;
      expect((resultA['content'] as List)[0]['text'], 'done-a');
      expect((resultB['content'] as List)[0]['text'], 'done-b');
    });
  });

  group('tools/call result byte cap', () {
    // Deliberately not ResultTrimmer's own 50 KB default: every assertion below
    // must fail if the configured trimmer stops reaching the dispatch point.
    const cap = 8 * 1024;

    ResultTrimmer configuredTrimmer() => ResultTrimmer(maxBytes: cap);

    Future<String> callBulk(McpProtocolHandler target, {Object id = 100}) async {
      final response = decode(await target.handleRequest(request('tools/call', id: id, params: {'name': 'bulk'})));
      return (((response['result'] as Map)['content'] as List)[0]['text'] as String);
    }

    test('a 200 KB text result is delivered trimmed with the byte count the caller lost', () async {
      final payload = 'x' * (200 * 1024);
      final capped = McpProtocolHandler(resultTrimmer: configuredTrimmer())..registerTool(_BulkTool(payload));

      final text = await callBulk(capped);

      expect(text, isNot(payload));
      final marker = RegExp(r'\n\.\.\.\[trimmed (\d+) bytes\]\.\.\.\n').firstMatch(text)!;
      final kept = utf8.encode(text).length - marker.group(0)!.length;
      expect(int.parse(marker.group(1)!), (200 * 1024) - kept);
      expect(utf8.encode(text).length, lessThanOrEqualTo(cap));
    });

    test('a result between the configured cap and the default cap is trimmed', () async {
      final payload = 'x' * (20 * 1024);
      final capped = McpProtocolHandler(resultTrimmer: configuredTrimmer())..registerTool(_BulkTool(payload));

      final text = await callBulk(capped, id: 101);

      expect(text, contains('...[trimmed '));
      expect(utf8.encode(text).length, lessThanOrEqualTo(cap));
    });

    test('a scoped handler caps the same result, so a containerized caller cannot bypass it', () async {
      final payload = 'x' * (20 * 1024);
      final capped = McpProtocolHandler(resultTrimmer: configuredTrimmer())..registerTool(_BulkTool(payload));

      final text = await callBulk(capped.scopedTo(_AllowAllPolicy()), id: 102);

      expect(text, contains('...[trimmed '));
      expect(utf8.encode(text).length, lessThanOrEqualTo(cap));
    });

    test('an exactly-at-cap result round-trips byte-identical', () async {
      final payload = 'x' * cap;
      final capped = McpProtocolHandler(resultTrimmer: configuredTrimmer())..registerTool(_BulkTool(payload));

      expect(await callBulk(capped, id: 103), payload);
    });

    test('a ToolResult.error is delivered unchanged and still marked isError', () async {
      final capped = McpProtocolHandler(resultTrimmer: configuredTrimmer())..registerTool(_ErrorTool());

      final result =
          decode(await capped.handleRequest(request('tools/call', id: 104, params: {'name': 'error_tool'})))['result']
              as Map<String, dynamic>;

      expect(result['isError'], isTrue);
      expect((result['content'] as List)[0]['text'], 'something went wrong');
    });

    test('reconfiguring context.max_result_bytes changes what dispatch delivers', () async {
      final payload = 'x' * (20 * 1024);
      final trimmer = ResultTrimmer(maxBytes: 64 * 1024);
      final capped = McpProtocolHandler(resultTrimmer: trimmer)..registerTool(_BulkTool(payload));
      final scoped = capped.scopedTo(_AllowAllPolicy());

      expect(await callBulk(capped, id: 105), payload);
      expect(await callBulk(scoped, id: 106), payload);

      trimmer.reconfigure(
        ConfigDelta(
          previous: const DartclawConfig.defaults(),
          current: DartclawConfig(context: const ContextConfig(maxResultBytes: cap)),
          changedKeys: const {'context.*'},
        ),
      );

      expect(await callBulk(capped, id: 107), contains('...[trimmed '));
      expect(await callBulk(scoped, id: 108), contains('...[trimmed '));
    });
  });
}
