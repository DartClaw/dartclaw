import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/src/mcp/sessions_spawn_tool.dart';
import 'package:test/test.dart';

void main() {
  late AgentDefinition searchAgent;

  setUp(() {
    searchAgent = AgentDefinition.searchAgent();
  });

  group('SessionsSpawnTool', () {
    test('requires an agent and initial message', () {
      final tool = SessionsSpawnTool(sessions: _sessions(searchAgent));

      expect(tool.name, 'sessions_spawn');
      expect(tool.inputSchema['type'], 'object');
      expect(tool.inputSchema['required'], ['agent', 'message']);
      expect((tool.inputSchema['properties'] as Map).containsKey('session_id'), isFalse);
      final agentSchema = (tool.inputSchema['properties'] as Map)['agent'] as Map;
      expect(agentSchema['enum'], ['search']);
      expect(agentSchema['description'], contains(searchAgent.description));
    });

    test('returns the new session handle with the first result', () async {
      final tool = SessionsSpawnTool(sessions: _sessions(searchAgent));

      final result = await tool.call({'agent': 'search', 'message': 'What is Dart?'});

      expect(result, isA<ToolResultText>());
      final payload = jsonDecode((result as ToolResultText).content) as Map<String, dynamic>;
      expect(payload['session_id'], startsWith('agent:search:logical:'));
      expect(payload['result'], 'Search result for: What is Dart?');
    });

    test('unknown agent returns ToolResultError', () async {
      final tool = SessionsSpawnTool(sessions: _sessions(searchAgent));

      final result = await tool.call({'agent': 'nonexistent', 'message': 'test'});

      expect(result, isA<ToolResultError>());
      expect((result as ToolResultError).message, contains('Unknown agent'));
    });
  });
}

LogicalAgentSessionService _sessions(AgentDefinition searchAgent) {
  return LogicalAgentSessionService(
    dispatch: ({required sessionId, required message, required agentId, required createSession}) async =>
        'Search result for: $message',
    agents: {'search': searchAgent},
  );
}
