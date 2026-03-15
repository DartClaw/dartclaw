import 'package:dartclaw_core/dartclaw_core.dart';

import 'mcp_utils.dart';

/// MCP tool that spawns a background sub-agent task via
/// [SessionDelegate.handleSessionsSpawn].
class SessionsSpawnTool implements McpTool {
  final SessionDelegate _delegate;

  SessionsSpawnTool({required SessionDelegate delegate}) : _delegate = delegate;

  @override
  String get name => 'sessions_spawn';

  @override
  String get description =>
      'Spawn a background sub-agent task. Returns a session ID '
      'immediately without waiting for completion.';

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
    final result = await _delegate.handleSessionsSpawn(args);
    return ToolResult.text(extractMcpText(result));
  }
}
