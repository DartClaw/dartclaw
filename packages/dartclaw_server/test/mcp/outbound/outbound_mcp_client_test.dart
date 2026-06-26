import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_server/src/mcp/outbound/outbound_mcp_client.dart';
import 'package:dartclaw_server/src/mcp/outbound/outbound_mcp_errors.dart';
import 'package:dartclaw_server/src/mcp/outbound/outbound_mcp_models.dart';
import 'package:dartclaw_server/src/mcp/outbound/outbound_mcp_transport.dart';
import 'package:test/test.dart';

void main() {
  group('OutboundMcpClient', () {
    test('S01 completes initialize, lists tools, and returns result content', () async {
      final transport = _ScriptedTransport();
      final client = OutboundMcpClient(
        serverName: 'stdio',
        transport: transport,
        timeout: const Duration(milliseconds: 50),
        maxResponseBytes: 1024,
      );

      final tools = await client.listTools();
      final result = await client.callTool(
        toolName: 'echo',
        arguments: {'text': 'hi'},
        caller: const OutboundMcpCaller(sessionId: 's1', principal: 'operator'),
      );

      expect(transport.methods, ['initialize', 'notifications/initialized', 'tools/list', 'tools/call']);
      expect(tools.single.name, 'echo');
      expect(result.isSuccess, isTrue);
      expect(result.content.single['text'], 'hi');
    });

    test('S03 preserves MCP isError content as a successful round-trip result', () async {
      final transport = _ScriptedTransport(
        callResult: {
          'content': [
            {'type': 'text', 'text': 'application error'},
          ],
          'isError': true,
        },
      );
      final client = OutboundMcpClient(
        serverName: 'stdio',
        transport: transport,
        timeout: const Duration(milliseconds: 50),
        maxResponseBytes: 1024,
      );

      final result = await client.callTool(
        toolName: 'echo',
        arguments: {'text': 'bad'},
        caller: const OutboundMcpCaller(sessionId: 's1'),
      );
      final next = await client.callTool(
        toolName: 'echo',
        arguments: {'text': 'next'},
        caller: const OutboundMcpCaller(sessionId: 's1'),
      );

      expect(result.isSuccess, isTrue);
      expect(result.isError, isTrue);
      expect(result.content.single['text'], 'application error');
      expect(next.isSuccess, isTrue);
    });

    test('S06 maps malformed and oversized responses to structured caller errors', () async {
      final malformed = OutboundMcpClient(
        serverName: 'bad',
        transport: _FailingTransport(const OutboundMcpException('malformed_response', 'bad frame')),
        timeout: const Duration(milliseconds: 50),
        maxResponseBytes: 1024,
      );
      final oversized = OutboundMcpClient(
        serverName: 'large',
        transport: _FailingTransport(const OutboundMcpException('response_too_large', 'too large')),
        timeout: const Duration(milliseconds: 50),
        maxResponseBytes: 1024,
      );

      final malformedResult = await malformed.callTool(
        toolName: 'echo',
        arguments: const {},
        caller: const OutboundMcpCaller(sessionId: 's1'),
      );
      final oversizedResult = await oversized.callTool(
        toolName: 'echo',
        arguments: const {},
        caller: const OutboundMcpCaller(sessionId: 's1'),
      );

      expect(malformedResult.error!.code, 'malformed_response');
      expect(malformedResult.content, isEmpty);
      expect(oversizedResult.error!.code, 'response_too_large');
      expect(oversizedResult.content, isEmpty);
    });

    test('S07 emits outboundCallTokens after transport dispatch', () async {
      final events = <OutboundMcpLifecycleEvent>[];
      final client = OutboundMcpClient(
        serverName: 'stdio',
        transport: _ScriptedTransport(
          callResult: {
            'content': [
              {'type': 'text', 'text': '12345678'},
            ],
            'outboundCallTokens': 7,
          },
        ),
        timeout: const Duration(milliseconds: 50),
        maxResponseBytes: 1024,
        observer: events.add,
      );

      final result = await client.callTool(
        toolName: 'echo',
        arguments: {'text': 'hi'},
        caller: const OutboundMcpCaller(sessionId: 'session-1', principal: 'principal-1'),
      );

      expect(result.outboundCallTokens, 7);
      expect(events.single.type, 'call-completed');
      expect(events.single.outboundCallTokens, 7);
    });
  });
}

final class _ScriptedTransport implements OutboundMcpTransport {
  final Map<String, dynamic> callResult;
  final methods = <String>[];

  _ScriptedTransport({
    this.callResult = const {
      'content': [
        {'type': 'text', 'text': 'hi'},
      ],
    },
  });

  @override
  Future<Map<String, dynamic>> sendRequest(
    String method,
    Map<String, dynamic> params, {
    required Duration timeout,
    required int maxResponseBytes,
  }) async {
    methods.add(method);
    return switch (method) {
      'initialize' => const {
        'protocolVersion': '2025-03-26',
        'serverInfo': {'name': 'fake'},
      },
      'tools/list' => const {
        'tools': [
          {'name': 'echo', 'description': 'Echoes input', 'inputSchema': {}},
        ],
      },
      'tools/call' => _withEcho(callResult, params),
      _ => throw const OutboundMcpException('protocol_error', 'unexpected method'),
    };
  }

  @override
  Future<void> sendNotification(
    String method,
    Map<String, dynamic> params, {
    required Duration timeout,
    required int maxResponseBytes,
  }) async {
    methods.add(method);
  }

  @override
  Future<bool> ping({required Duration timeout, required int maxResponseBytes}) async => true;

  @override
  Future<void> close() async {}
}

final class _FailingTransport implements OutboundMcpTransport {
  final OutboundMcpException error;

  const _FailingTransport(this.error);

  @override
  Future<Map<String, dynamic>> sendRequest(
    String method,
    Map<String, dynamic> params, {
    required Duration timeout,
    required int maxResponseBytes,
  }) async {
    if (method == 'initialize' || method == 'tools/list') {
      return const {'tools': []};
    }
    throw error;
  }

  @override
  Future<void> sendNotification(
    String method,
    Map<String, dynamic> params, {
    required Duration timeout,
    required int maxResponseBytes,
  }) async {}

  @override
  Future<bool> ping({required Duration timeout, required int maxResponseBytes}) async => true;

  @override
  Future<void> close() async {}
}

Map<String, dynamic> _withEcho(Map<String, dynamic> result, Map<String, dynamic> params) {
  if (jsonEncode(result).contains('"hi"')) return result;
  final arguments = params['arguments'];
  if (arguments is! Map || arguments['text'] == null || result['isError'] == true) {
    return result;
  }
  return {
    ...result,
    'content': [
      {'type': 'text', 'text': arguments['text']},
    ],
  };
}
