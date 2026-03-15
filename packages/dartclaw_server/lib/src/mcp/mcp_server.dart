import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

import '../version.dart';

/// MCP protocol handler implementing JSON-RPC 2.0 over Streamable HTTP.
///
/// Handles `initialize`, `notifications/initialized`, `tools/list`, and
/// `tools/call` methods. Tools are registered at startup via [registerTool].
class McpProtocolHandler {
  static final _log = Logger('McpProtocolHandler');

  static const _protocolVersion = '2025-03-26';
  static const _serverName = 'dartclaw';

  final Map<String, McpTool> _tools = {};
  bool _started = false;

  /// Register a tool. Must be called before the server starts handling requests.
  void registerTool(McpTool tool) {
    if (_started) {
      throw StateError('Cannot register tools after server has started handling requests');
    }
    if (_tools.containsKey(tool.name)) {
      _log.warning('Tool "${tool.name}" already registered — skipping duplicate');
      return;
    }
    _tools[tool.name] = tool;
  }

  /// Mark the handler as started (called when first request arrives or server starts).
  void markStarted() {
    _started = true;
  }

  /// List of registered tool names (for diagnostics).
  List<String> get toolNames => _tools.keys.toList();

  /// Handle a JSON-RPC request string and return a JSON-RPC response string.
  /// Returns null for notifications (no response needed).
  Future<String?> handleRequest(String body) async {
    _started = true;

    Object? parsed;
    try {
      parsed = jsonDecode(body);
    } on FormatException {
      return _errorResponse(null, -32700, 'Parse error');
    }

    if (parsed is! Map<String, dynamic>) {
      return _errorResponse(null, -32600, 'Invalid Request');
    }

    final jsonrpc = parsed['jsonrpc'];
    if (jsonrpc != '2.0') {
      return _errorResponse(parsed['id'], -32600, 'Invalid Request: missing jsonrpc "2.0"');
    }

    final method = parsed['method'];
    if (method is! String) {
      return _errorResponse(parsed['id'], -32600, 'Invalid Request: missing method');
    }

    final id = parsed['id']; // null for notifications
    final params = parsed['params'] as Map<String, dynamic>? ?? {};

    // Notifications (no id) — handle but don't respond
    if (id == null) {
      await _handleNotification(method, params);
      return null;
    }

    return _handleMethod(method, params, id as Object);
  }

  Future<void> _handleNotification(String method, Map<String, dynamic> params) async {
    switch (method) {
      case 'notifications/initialized':
        _log.fine('Client initialized notification received');
      default:
        _log.fine('Unknown notification: $method');
    }
  }

  Future<String> _handleMethod(String method, Map<String, dynamic> params, Object id) async {
    switch (method) {
      case 'initialize':
        return _handleInitialize(id);
      case 'tools/list':
        return _handleToolsList(id);
      case 'tools/call':
        return _handleToolsCall(params, id);
      default:
        return _errorResponse(id, -32601, 'Method not found: $method');
    }
  }

  String _handleInitialize(Object id) {
    final result = {
      'protocolVersion': _protocolVersion,
      'capabilities': {
        'tools': {'listChanged': false},
      },
      'serverInfo': {'name': _serverName, 'version': dartclawVersion},
    };
    return _successResponse(id, result);
  }

  String _handleToolsList(Object id) {
    final tools = _tools.values
        .map((t) => {'name': t.name, 'description': t.description, 'inputSchema': t.inputSchema})
        .toList();
    return _successResponse(id, {'tools': tools});
  }

  Future<String> _handleToolsCall(Map<String, dynamic> params, Object id) async {
    final name = params['name'] as String?;
    if (name == null) {
      return _errorResponse(id, -32602, 'Invalid params: missing "name"');
    }

    final tool = _tools[name];
    if (tool == null) {
      return _errorResponse(id, -32602, 'Unknown tool: $name');
    }

    final args = params['arguments'] as Map<String, dynamic>? ?? {};

    ToolResult result;
    try {
      result = await tool.call(args).timeout(const Duration(seconds: 120));
    } on TimeoutException {
      _log.warning('Tool "$name" timed out');
      result = ToolResult.error('Tool "$name" timed out after 120 seconds');
    } catch (e) {
      _log.warning('Tool "$name" threw exception: $e');
      result = ToolResult.error('Tool execution failed: $e');
    }

    return switch (result) {
      ToolResultText(:final content) => _successResponse(id, {
        'content': [
          {'type': 'text', 'text': content},
        ],
      }),
      ToolResultError(:final message) => _successResponse(id, {
        'content': [
          {'type': 'text', 'text': message},
        ],
        'isError': true,
      }),
    };
  }

  static String _successResponse(Object id, Object result) {
    return jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result});
  }

  static String _errorResponse(Object? id, int code, String message) {
    return jsonEncode({
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': code, 'message': message},
    });
  }
}
