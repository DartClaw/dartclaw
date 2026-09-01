import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';

import 'mcp_utils.dart';

/// MCP tool that creates a logical-agent session and runs its first turn.
class SessionsSpawnTool implements McpTool {
  final LogicalAgentSessionService _sessions;

  new({required LogicalAgentSessionService sessions}) : _sessions = sessions;

  @override
  String get name => 'sessions_spawn';

  @override
  String get description =>
      'Create a logical-agent session, wait for its first result, and return a session handle for follow-up messages.';

  @override
  Map<String, dynamic> get inputSchema {
    final agents = _sessions.agents;
    final ids = agents.keys.toList()..sort();
    final available = ids.map((id) => '$id: ${agents[id]!.description}').join('; ');
    return {
      'type': 'object',
      'properties': {
        'agent': {
          'type': 'string',
          if (ids.isNotEmpty) 'enum': ids,
          'description': ids.isEmpty
              ? 'Configured logical agent ID'
              : 'Configured logical agent. Available: $available',
        },
        'message': {'type': 'string', 'description': 'The initial query or instruction'},
      },
      'required': ['agent', 'message'],
      'additionalProperties': false,
    };
  }

  @override
  McpToolAccess get access => McpToolAccess.write;

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final result = await _sessions.handleSessionsSpawn(args);
    final text = extractMcpText(result);
    if (result['isError'] == true) return ToolResult.error(text);
    return ToolResult.text(jsonEncode({'session_id': result['sessionId'], 'result': text}));
  }
}
