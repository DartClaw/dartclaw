import 'package:dartclaw_core/dartclaw_core.dart';

import 'mcp_utils.dart';

/// MCP tool that continues an existing delegated agent session.
class SessionsSendTool implements McpTool {
  final SessionDelegate _delegate;

  SessionsSendTool({required SessionDelegate delegate}) : _delegate = delegate;

  @override
  String get name => 'sessions_send';

  @override
  String get description =>
      'Send a message to an existing delegated session and wait for the result. '
      'Use sessions_spawn to create the session first.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'session_id': {'type': 'string', 'description': 'Delegated session handle returned by sessions_spawn'},
      'message': {'type': 'string', 'description': 'The follow-up message to send'},
    },
    'required': ['session_id', 'message'],
    'additionalProperties': false,
  };

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final result = await _delegate.handleSessionsSend(args);
    final text = extractMcpText(result);
    return result['isError'] == true ? ToolResult.error(text) : ToolResult.text(text);
  }
}
