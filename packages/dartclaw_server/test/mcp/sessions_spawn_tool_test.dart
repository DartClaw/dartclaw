import 'dart:async';

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
    test('has correct name and schema', () {
      final delegate = SessionDelegate(
        dispatch: ({required sessionId, required message, required agentId}) async => '',
        limits: limits,
        agents: {'search': searchAgent},
      );
      final tool = SessionsSpawnTool(delegate: delegate);

      expect(tool.name, 'sessions_spawn');
      expect(tool.description, isNotEmpty);
      expect(tool.inputSchema['type'], 'object');
      final required = tool.inputSchema['required'] as List;
      expect(required, contains('agent'));
      expect(required, contains('message'));
    });

    test('successful spawn returns session ID text', () async {
      final completer = Completer<void>();
      final delegate = SessionDelegate(
        dispatch: ({required sessionId, required message, required agentId}) async {
          await completer.future;
          return 'done';
        },
        limits: limits,
        agents: {'search': searchAgent},
      );
      final tool = SessionsSpawnTool(delegate: delegate);

      final result = await tool.call({'agent': 'search', 'message': 'background task'});
      expect(result, isA<ToolResultText>());
      expect((result as ToolResultText).content, contains('Spawned session:'));

      // Allow background to complete
      completer.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    test('error result (unknown agent) returns error text', () async {
      final delegate = SessionDelegate(
        dispatch: ({required sessionId, required message, required agentId}) async => '',
        limits: limits,
        agents: {'search': searchAgent},
      );
      final tool = SessionsSpawnTool(delegate: delegate);

      final result = await tool.call({'agent': 'nonexistent', 'message': 'test'});
      expect(result, isA<ToolResultText>());
      expect((result as ToolResultText).content, contains('Unknown agent'));
    });
  });
}
