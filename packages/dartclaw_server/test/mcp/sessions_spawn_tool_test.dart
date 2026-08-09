import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/mcp/sessions_spawn_tool.dart';
import 'package:test/test.dart';

void main() {
  late SubagentLimits limits;
  late AgentDefinition searchAgent;

  setUp(() {
    limits = SubagentLimits(maxConcurrent: 2, maxSpawnDepth: 1, maxChildrenPerAgent: 2);
    searchAgent = AgentDefinition.searchAgent();
  });

  group('SessionsSpawnTool', () {
    test('requires an agent and initial message', () {
      final tool = SessionsSpawnTool(delegate: _delegate(limits, searchAgent));

      expect(tool.name, 'sessions_spawn');
      expect(tool.inputSchema['type'], 'object');
      expect(tool.inputSchema['required'], ['agent', 'message']);
      expect((tool.inputSchema['properties'] as Map).containsKey('session_id'), isFalse);
    });

    test('returns the new session handle with the first result', () async {
      final tool = SessionsSpawnTool(delegate: _delegate(limits, searchAgent));

      final result = await tool.call({'agent': 'search', 'message': 'What is Dart?'});

      expect(result, isA<ToolResultText>());
      final payload = jsonDecode((result as ToolResultText).content) as Map<String, dynamic>;
      expect(payload['session_id'], startsWith('agent:search:delegated:'));
      expect(payload['result'], 'Search result for: What is Dart?');
    });

    test('unknown agent returns ToolResultError', () async {
      final tool = SessionsSpawnTool(delegate: _delegate(limits, searchAgent));

      final result = await tool.call({'agent': 'nonexistent', 'message': 'test'});

      expect(result, isA<ToolResultError>());
      expect((result as ToolResultError).message, contains('Unknown agent'));
    });
  });
}

SessionDelegate _delegate(SubagentLimits limits, AgentDefinition searchAgent) {
  return SessionDelegate(
    dispatch: ({required sessionId, required message, required agentId, required createSession}) async =>
        'Search result for: $message',
    limits: limits,
    agents: {'search': searchAgent},
  );
}
