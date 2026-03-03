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
    test('has correct name and schema', () {
      final delegate = SessionDelegate(
        dispatch: ({required sessionId, required message, required agentId}) async => '',
        limits: limits,
        agents: {'search': searchAgent},
      );
      final tool = SessionsSendTool(delegate: delegate);

      expect(tool.name, 'sessions_send');
      expect(tool.description, isNotEmpty);
      expect(tool.inputSchema['type'], 'object');
      final required = tool.inputSchema['required'] as List;
      expect(required, contains('agent'));
      expect(required, contains('message'));
    });

    test('successful delegation returns text', () async {
      final delegate = SessionDelegate(
        dispatch: ({required sessionId, required message, required agentId}) async {
          return 'Search result for: $message';
        },
        limits: limits,
        agents: {'search': searchAgent},
      );
      final tool = SessionsSendTool(delegate: delegate);

      final result = await tool.call({'agent': 'search', 'message': 'What is Dart?'});
      expect(result, 'Search result for: What is Dart?');
    });

    test('error result (unknown agent) returns error text', () async {
      final delegate = SessionDelegate(
        dispatch: ({required sessionId, required message, required agentId}) async => '',
        limits: limits,
        agents: {'search': searchAgent},
      );
      final tool = SessionsSendTool(delegate: delegate);

      final result = await tool.call({'agent': 'nonexistent', 'message': 'test'});
      expect(result, contains('Unknown agent'));
    });

    test('missing params returns error text', () async {
      final delegate = SessionDelegate(
        dispatch: ({required sessionId, required message, required agentId}) async => '',
        limits: limits,
        agents: {'search': searchAgent},
      );
      final tool = SessionsSendTool(delegate: delegate);

      final result = await tool.call({'agent': 'search'});
      expect(result, contains('Missing required params'));
    });
  });
}
