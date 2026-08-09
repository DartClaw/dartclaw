import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';

import 'mcp_utils.dart';

/// MCP tool that creates a delegated agent session and runs its first turn.
class SessionsSpawnTool implements McpTool {
  final SessionDelegate _delegate;

  SessionsSpawnTool({required SessionDelegate delegate}) : _delegate = delegate;

  @override
  String get name => 'sessions_spawn';

  @override
  String get description =>
      'Create a new delegated agent session, wait for its first result, and return a session handle for follow-up messages.';

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'agent': {'type': 'string', 'description': 'Configured agent ID (e.g. "search")'},
      'message': {'type': 'string', 'description': 'The initial query or instruction'},
    },
    'required': ['agent', 'message'],
    'additionalProperties': false,
  };

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final result = await _delegate.handleSessionsSpawn(args);
    final text = extractMcpText(result);
    if (result['isError'] == true) return ToolResult.error(text);
    return ToolResult.text(jsonEncode({'session_id': result['sessionId'], 'result': text}));
  }
}
