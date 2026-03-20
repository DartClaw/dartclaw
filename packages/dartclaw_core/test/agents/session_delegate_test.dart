import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  late SubagentLimits limits;
  late AgentDefinition searchAgent;

  setUp(() {
    limits = SubagentLimits(maxConcurrent: 2, maxSpawnDepth: 1, maxChildrenPerAgent: 2);
    searchAgent = AgentDefinition.searchAgent();
  });

  group('SessionDelegate', () {
    test('sessions_send dispatches and returns result', () async {
      final delegate = SessionDelegate(
        dispatch: ({required sessionId, required message, required agentId}) async {
          return 'Search result for: $message';
        },
        limits: limits,
        agents: {'search': searchAgent},
      );

      final result = await delegate.handleSessionsSend({'agent': 'search', 'message': 'What is Dart?'});

      expect(result['isError'], isNull);
      final content = result['content'] as List;
      expect(content.first['text'], 'Search result for: What is Dart?');
    });

    test('sessions_send returns error for unknown agent', () async {
      final delegate = SessionDelegate(
        dispatch: ({required sessionId, required message, required agentId}) async => '',
        limits: limits,
        agents: {'search': searchAgent},
      );

      final result = await delegate.handleSessionsSend({'agent': 'nonexistent', 'message': 'test'});

      expect(result['isError'], isTrue);
      final content = result['content'] as List;
      expect(content.first['text'], contains('Unknown agent'));
    });

    test('sessions_send returns error when at limit', () async {
      final tightLimits = SubagentLimits(maxConcurrent: 0);
      final delegate = SessionDelegate(
        dispatch: ({required sessionId, required message, required agentId}) async => '',
        limits: tightLimits,
        agents: {'search': searchAgent},
      );

      final result = await delegate.handleSessionsSend({'agent': 'search', 'message': 'test'});

      expect(result['isError'], isTrue);
      final content = result['content'] as List;
      expect(content.first['text'], contains('limit'));
    });

    test('sessions_send returns error for missing params', () async {
      final delegate = SessionDelegate(
        dispatch: ({required sessionId, required message, required agentId}) async => '',
        limits: limits,
        agents: {'search': searchAgent},
      );

      final result = await delegate.handleSessionsSend({'agent': 'search'});
      expect(result['isError'], isTrue);
    });

    test('sessions_send truncates oversized response', () async {
      final smallAgent = AgentDefinition(
        id: 'search',
        description: 'test',
        prompt: 'test',
        allowedTools: {'WebSearch'},
        maxResponseBytes: 10,
      );
      final delegate = SessionDelegate(
        dispatch: ({required sessionId, required message, required agentId}) async {
          return 'A' * 100;
        },
        limits: limits,
        agents: {'search': smallAgent},
      );

      final result = await delegate.handleSessionsSend({'agent': 'search', 'message': 'test'});

      final content = result['content'] as List;
      final text = content.first['text'] as String;
      expect(text.length, lessThanOrEqualTo(15)); // some slack for UTF-8
    });

    test('sessions_spawn returns session ID immediately', () async {
      final completer = Completer<void>();
      final delegate = SessionDelegate(
        dispatch: ({required sessionId, required message, required agentId}) async {
          await completer.future;
          return 'done';
        },
        limits: limits,
        agents: {'search': searchAgent},
      );

      final result = await delegate.handleSessionsSpawn({'agent': 'search', 'message': 'background search'});

      expect(result['isError'], isNull);
      final content = result['content'] as List;
      expect(content.first['text'], contains('Spawned session:'));

      // Allow background to complete
      completer.complete();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });

    test('sessions_send frees limit slot after completion', () async {
      final delegate = SessionDelegate(
        dispatch: ({required sessionId, required message, required agentId}) async => 'ok',
        limits: limits,
        agents: {'search': searchAgent},
      );

      await delegate.handleSessionsSend({'agent': 'search', 'message': 'a'});
      await delegate.handleSessionsSend({'agent': 'search', 'message': 'b'});

      expect(limits.totalActive, 0);
    });

    test('sessions_send frees limit slot on dispatch failure', () async {
      final delegate = SessionDelegate(
        dispatch: ({required sessionId, required message, required agentId}) async {
          throw Exception('network error');
        },
        limits: limits,
        agents: {'search': searchAgent},
      );

      final result = await delegate.handleSessionsSend({'agent': 'search', 'message': 'test'});

      expect(result['isError'], isTrue);
      expect(limits.totalActive, 0);
    });

    test('handler methods are directly callable', () async {
      final delegate = SessionDelegate(
        dispatch: ({required sessionId, required message, required agentId}) async => 'result text',
        limits: limits,
        agents: {'search': searchAgent},
      );

      final sendResult = await delegate.handleSessionsSend({'agent': 'search', 'message': 'test query'});
      expect(sendResult['isError'], isNull);
      final text = (sendResult['content'] as List).first['text'] as String;
      expect(text, contains('result text'));
    });
  });
}
