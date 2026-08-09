import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/mcp/sessions_send_tool.dart';
import 'package:test/test.dart';

void main() {
  late SubagentLimits limits;
  late AgentDefinition searchAgent;

  setUp(() {
    limits = SubagentLimits(maxConcurrent: 2, maxSpawnDepth: 1, maxChildrenPerAgent: 2);
    searchAgent = AgentDefinition.searchAgent();
  });

  group('SessionsSendTool', () {
    test('requires a delegated session handle and message', () {
      final tool = SessionsSendTool(delegate: _delegate(limits, searchAgent));

      expect(tool.name, 'sessions_send');
      expect(tool.inputSchema['type'], 'object');
      expect(tool.inputSchema['required'], ['session_id', 'message']);
      expect((tool.inputSchema['properties'] as Map).containsKey('agent'), isFalse);
    });

    test('continues the selected delegated session', () async {
      String? dispatchedSession;
      var created = true;
      final delegate = SessionDelegate(
        dispatch: ({required sessionId, required message, required agentId, required createSession}) async {
          dispatchedSession = sessionId;
          created = createSession;
          return 'Search result for: $message';
        },
        limits: limits,
        agents: {'search': searchAgent},
      );
      final tool = SessionsSendTool(delegate: delegate);
      const sessionId = 'agent:search:delegated:018f82d5-99d1-7f8e-a4ea-4f6f72314b17';

      final result = await tool.call({'session_id': sessionId, 'message': 'What is Dart?'});

      expect(result, isA<ToolResultText>());
      expect((result as ToolResultText).content, 'Search result for: What is Dart?');
      expect(dispatchedSession, sessionId);
      expect(created, isFalse);
    });

    test('invalid session handle returns ToolResultError', () async {
      final tool = SessionsSendTool(delegate: _delegate(limits, searchAgent));

      final result = await tool.call({'session_id': 'unknown', 'message': 'test'});

      expect(result, isA<ToolResultError>());
      expect((result as ToolResultError).message, contains('delegated session'));
    });

    test('delegation failure returns ToolResultError', () async {
      final delegate = SessionDelegate(
        dispatch: ({required sessionId, required message, required agentId, required createSession}) async {
          throw StateError('Provider "claude" task pool unavailable; increase providers.claude.pool_size');
        },
        limits: limits,
        agents: {'search': searchAgent},
      );
      final tool = SessionsSendTool(delegate: delegate);

      final result = await tool.call({
        'session_id': 'agent:search:delegated:018f82d5-99d1-7f8e-a4ea-4f6f72314b17',
        'message': 'test',
      });

      expect(result, isA<ToolResultError>());
      expect((result as ToolResultError).message, contains('providers.claude.pool_size'));
    });
  });
}

SessionDelegate _delegate(SubagentLimits limits, AgentDefinition searchAgent) {
  return SessionDelegate(
    dispatch: ({required sessionId, required message, required agentId, required createSession}) async => 'ok',
    limits: limits,
    agents: {'search': searchAgent},
  );
}
