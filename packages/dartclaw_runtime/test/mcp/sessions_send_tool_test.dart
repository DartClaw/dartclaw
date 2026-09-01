import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/src/mcp/sessions_send_tool.dart';
import 'package:test/test.dart';

void main() {
  late AgentDefinition searchAgent;

  setUp(() {
    searchAgent = AgentDefinition.searchAgent();
  });

  group('SessionsSendTool', () {
    test('requires a logical-agent session handle and message', () {
      final tool = SessionsSendTool(sessions: _sessions(searchAgent));

      expect(tool.name, 'sessions_send');
      expect(tool.inputSchema['type'], 'object');
      expect(tool.inputSchema['required'], ['session_id', 'message']);
      expect((tool.inputSchema['properties'] as Map).containsKey('agent'), isFalse);
    });

    test('continues the selected logical-agent session', () async {
      String? dispatchedSession;
      var created = true;
      final sessions = LogicalAgentSessionService(
        dispatch: ({required sessionId, required message, required agentId, required createSession}) async {
          dispatchedSession = sessionId;
          created = createSession;
          return 'Search result for: $message';
        },
        agents: {'search': searchAgent},
      );
      final tool = SessionsSendTool(sessions: sessions);
      const sessionId = 'agent:search:logical:018f82d5-99d1-7f8e-a4ea-4f6f72314b17';

      final result = await tool.call({'session_id': sessionId, 'message': 'What is Dart?'});

      expect(result, isA<ToolResultText>());
      expect((result as ToolResultText).content, 'Search result for: What is Dart?');
      expect(dispatchedSession, sessionId);
      expect(created, isFalse);
    });

    test('invalid session handle returns ToolResultError', () async {
      final tool = SessionsSendTool(sessions: _sessions(searchAgent));

      final result = await tool.call({'session_id': 'unknown', 'message': 'test'});

      expect(result, isA<ToolResultError>());
      expect((result as ToolResultError).message, contains('logical-agent session'));
    });

    test('logical-agent session failure returns ToolResultError', () async {
      final sessions = LogicalAgentSessionService(
        dispatch: ({required sessionId, required message, required agentId, required createSession}) async {
          throw StateError('Provider "claude" worker capacity unavailable; increase providers.claude.pool_size');
        },
        agents: {'search': searchAgent},
      );
      final tool = SessionsSendTool(sessions: sessions);

      final result = await tool.call({
        'session_id': 'agent:search:logical:018f82d5-99d1-7f8e-a4ea-4f6f72314b17',
        'message': 'test',
      });

      expect(result, isA<ToolResultError>());
      expect((result as ToolResultError).message, contains('providers.claude.pool_size'));
    });
  });
}

LogicalAgentSessionService _sessions(AgentDefinition searchAgent) {
  return LogicalAgentSessionService(
    dispatch: ({required sessionId, required message, required agentId, required createSession}) async => 'ok',
    agents: {'search': searchAgent},
  );
}
