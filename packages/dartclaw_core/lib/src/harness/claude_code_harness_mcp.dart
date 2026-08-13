part of 'claude_code_harness.dart';

extension _ClaudeCodeHarnessMcp on ClaudeCodeHarness {
  Future<void> _handleMcpMessage(String requestId, Map<String, dynamic> data) async {
    final message = data['message'];
    if (data['server_name'] != dartclawMcpServerName || message is! Map<String, dynamic>) {
      _writeMcpError(requestId, null, -32600, 'Invalid MCP request');
      return;
    }
    final id = message['id'];
    if (message['jsonrpc'] != '2.0' || message['method'] != 'tools/call') {
      _writeMcpError(requestId, id, -32601, 'Unsupported MCP method');
      return;
    }
    final params = message['params'];
    if (params is! Map<String, dynamic> || params['name'] is! String) {
      _writeMcpError(requestId, id, -32602, 'Invalid tool parameters');
      return;
    }
    final arguments = params['arguments'];
    if (arguments is! Map<String, dynamic>) {
      _writeMcpError(requestId, id, -32602, 'Tool arguments must be an object');
      return;
    }
    final name = params['name'] as String;
    final contextualHandler = switch (name) {
      'memory_apply' => onContextualMemoryApply,
      'memory_observe' => onContextualMemoryObserve,
      _ => null,
    };
    final handler = switch (name) {
      'memory_apply' => onMemoryApply,
      'memory_observe' => onMemoryObserve,
      'memory_search' => onMemorySearch,
      'memory_read' => onMemoryRead,
      _ => null,
    };
    if (handler == null && contextualHandler == null) {
      _writeMcpError(requestId, id, -32601, 'Unknown tool');
      return;
    }
    try {
      final copiedArguments = Map<String, dynamic>.of(arguments);
      final context = activeTurnContext;
      if (contextualHandler != null && context == null) {
        _writeMcpError(requestId, id, -32603, 'Active turn context required');
        return;
      }
      final result = contextualHandler != null
          ? await contextualHandler(copiedArguments, context!)
          : await handler!(copiedArguments);
      _writeMcpResponse(requestId, {'jsonrpc': '2.0', 'id': id, 'result': result});
    } on ArgumentError catch (error) {
      _writeMcpError(requestId, id, -32602, error.message?.toString() ?? 'Invalid tool arguments');
    } on Object catch (error, stackTrace) {
      ClaudeCodeHarness._log.warning('SDK MCP tool failed: ${params['name']}', error, stackTrace);
      _writeMcpError(requestId, id, -32603, 'Tool execution failed');
    }
  }

  void _writeMcpError(String requestId, Object? id, int code, String message) {
    _writeMcpResponse(requestId, {
      'jsonrpc': '2.0',
      'id': id,
      'error': {'code': code, 'message': message},
    });
  }

  void _writeMcpResponse(String requestId, Map<String, dynamic> response) {
    _writeSdkMcpLine({
      'type': 'control_response',
      'response': {
        'subtype': 'success',
        'request_id': requestId,
        'response': {'mcp_response': response},
      },
    });
  }
}
