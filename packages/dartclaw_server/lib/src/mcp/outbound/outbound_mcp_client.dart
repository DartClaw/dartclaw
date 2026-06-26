import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' show ToolResult, ToolResultError, ToolResultText;

import 'outbound_mcp_errors.dart';
import 'outbound_mcp_models.dart';
import 'outbound_mcp_transport.dart';

final class OutboundMcpClient {
  final String serverName;
  final OutboundMcpTransport _transport;
  final Duration _timeout;
  final int _maxResponseBytes;
  final OutboundMcpObserver? _observer;
  var _initialized = false;
  List<OutboundMcpTool> _tools = const [];

  OutboundMcpClient({
    required this.serverName,
    required OutboundMcpTransport transport,
    required Duration timeout,
    required int maxResponseBytes,
    OutboundMcpObserver? observer,
  }) : _transport = transport,
       _timeout = timeout,
       _maxResponseBytes = maxResponseBytes,
       _observer = observer;

  Future<List<OutboundMcpTool>> listTools() async {
    await _ensureInitialized();
    return _tools;
  }

  Future<OutboundMcpCallResult> callTool({
    required String toolName,
    required Map<String, dynamic> arguments,
    required OutboundMcpCaller caller,
  }) async {
    try {
      await _ensureInitialized();
      final result = await _transport.sendRequest(
        'tools/call',
        {'name': toolName, 'arguments': arguments},
        timeout: _timeout,
        maxResponseBytes: _maxResponseBytes,
      );
      final content = _contentList(result['content']);
      final tokens = _tokenCount(result);
      _observer?.call(
        OutboundMcpLifecycleEvent(
          serverName: serverName,
          type: 'call-completed',
          timestamp: DateTime.now(),
          outboundCallTokens: tokens,
        ),
      );
      return OutboundMcpCallResult(
        serverName: serverName,
        toolName: toolName,
        content: content,
        isError: result['isError'] == true,
        outboundCallTokens: tokens,
      );
    } on OutboundMcpException catch (error) {
      _emitFailure(error.code);
      return _failureResult(toolName: toolName, code: error.code, message: error.message);
    } on TimeoutException catch (error) {
      return _failureResult(toolName: toolName, code: 'timeout', message: error.message ?? 'MCP request timed out');
    } catch (error) {
      _emitFailure('guard_or_dispatch_error');
      return _failureResult(toolName: toolName, code: 'guard_or_dispatch_error', message: error.toString());
    }
  }

  Future<bool> ping() => _transport.ping(timeout: _timeout, maxResponseBytes: _maxResponseBytes);

  Future<void> close() => _transport.close();

  OutboundMcpCallResult _failureResult({required String toolName, required String code, required String message}) {
    return OutboundMcpCallResult(
      serverName: serverName,
      toolName: toolName,
      content: const [],
      outboundCallTokens: 0,
      error: OutboundMcpError(code: code, message: message, serverName: serverName),
    );
  }

  void _emitFailure(String detail) {
    _observer?.call(
      OutboundMcpLifecycleEvent(serverName: serverName, type: 'failure', detail: detail, timestamp: DateTime.now()),
    );
  }

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    await _transport.sendRequest(
      'initialize',
      {
        'protocolVersion': '2025-03-26',
        'clientInfo': {'name': 'dartclaw', 'version': '0.19.0'},
        'capabilities': const <String, dynamic>{},
      },
      timeout: _timeout,
      maxResponseBytes: _maxResponseBytes,
    );
    await _transport.sendNotification(
      'notifications/initialized',
      const {},
      timeout: _timeout,
      maxResponseBytes: _maxResponseBytes,
    );
    _tools = _parseTools(
      await _transport.sendRequest('tools/list', const {}, timeout: _timeout, maxResponseBytes: _maxResponseBytes),
    );
    _initialized = true;
  }
}

List<OutboundMcpTool> _parseTools(Map<String, dynamic> result) {
  final rawTools = result['tools'];
  if (rawTools is! List) return const [];
  return [
    for (final raw in rawTools)
      if (raw is Map)
        OutboundMcpTool(
          name: raw['name']?.toString() ?? '',
          description: raw['description']?.toString(),
          inputSchema: raw['inputSchema'] is Map ? Map<String, dynamic>.from(raw['inputSchema'] as Map) : const {},
        ),
  ].where((tool) => tool.name.isNotEmpty).toList(growable: false);
}

List<Map<String, dynamic>> _contentList(Object? content) {
  if (content is! List) return const [];
  return [
    for (final item in content)
      if (item is Map) Map<String, dynamic>.from(item),
  ];
}

int _tokenCount(Map<String, dynamic> result) {
  for (final key in const ['outboundCallTokens', 'tokenCount', 'tokens']) {
    final value = result[key];
    if (value is int && value > 0) return value;
    if (value is num && value > 0) return value.ceil();
  }
  return estimateOutboundCallTokens(result);
}

ToolResult toToolResult(OutboundMcpCallResult result) {
  if (!result.isSuccess) {
    return ToolResult.error(result.error!.message);
  }
  final text = result.content.map((item) => item['text']?.toString()).whereType<String>().join('\n');
  return result.isError ? ToolResultError(text) : ToolResultText(text);
}
