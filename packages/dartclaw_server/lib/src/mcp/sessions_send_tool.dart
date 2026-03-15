import 'package:dartclaw_core/dartclaw_core.dart';

import 'mcp_utils.dart';

/// MCP tool that delegates a synchronous query to a sub-agent via
/// [SessionDelegate.handleSessionsSend].
class SessionsSendTool implements McpTool {
  final SessionDelegate _delegate;

  SessionsSendTool({required SessionDelegate delegate}) : _delegate = delegate;

  @override
  String get name => 'sessions_send';

  @override
  String get description =>
      'Send a query to a sub-agent and wait for the result. '
      'Use for web search, information retrieval, or delegated tasks.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'agent': {'type': 'string', 'description': 'Agent ID (e.g. "search")'},
      'message': {'type': 'string', 'description': 'The query or instruction to send'},
    },
    'required': ['agent', 'message'],
  };

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final result = await _delegate.handleSessionsSend(args);
    return ToolResult.text(extractMcpText(result));
  }
}
