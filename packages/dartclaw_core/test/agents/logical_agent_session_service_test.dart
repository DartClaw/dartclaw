import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  late AgentDefinition searchAgent;

  setUp(() {
    searchAgent = AgentDefinition.searchAgent();
  });

  group('LogicalAgentSessionService', () {
    test('sessions_spawn creates a new logical-agent session and returns its handle', () async {
      final calls = <({String sessionId, String message, String agentId, bool createSession})>[];
      final sessions = LogicalAgentSessionService(
        dispatch: ({required sessionId, required message, required agentId, required createSession}) async {
          calls.add((sessionId: sessionId, message: message, agentId: agentId, createSession: createSession));
          return 'Search result for: $message';
        },
        agents: {'search': searchAgent},
      );

      final result = await sessions.handleSessionsSpawn({'agent': 'search', 'message': 'What is Dart?'});

      expect(result['isError'], isNull);
      expect(result['sessionId'], startsWith('agent:search:logical:'));
      expect((result['content'] as List).first['text'], 'Search result for: What is Dart?');
      expect(calls.single.agentId, 'search');
      expect(calls.single.createSession, isTrue);
    });

    test('sessions_send resumes the logical-agent session returned by spawn', () async {
      final calls = <({String sessionId, String message, String agentId, bool createSession})>[];
      final sessions = LogicalAgentSessionService(
        dispatch: ({required sessionId, required message, required agentId, required createSession}) async {
          calls.add((sessionId: sessionId, message: message, agentId: agentId, createSession: createSession));
          return 'reply: $message';
        },
        agents: {'search': searchAgent},
      );
      final spawned = await sessions.handleSessionsSpawn({'agent': 'search', 'message': 'first'});
      final sessionId = spawned['sessionId'] as String;

      final sent = await sessions.handleSessionsSend({'session_id': sessionId, 'message': 'second'});

      expect(sent['isError'], isNull);
      expect((sent['content'] as List).first['text'], 'reply: second');
      expect(calls, hasLength(2));
      expect(calls.last.sessionId, sessionId);
      expect(calls.last.agentId, 'search');
      expect(calls.last.createSession, isFalse);
    });

    test('session handles encode agent IDs without changing the selected agent', () async {
      const agent = AgentDefinition(id: 'review:security', description: 'Review', prompt: 'Review');
      String? dispatchedAgent;
      final sessions = LogicalAgentSessionService(
        dispatch: ({required sessionId, required message, required agentId, required createSession}) async {
          dispatchedAgent = agentId;
          return 'ok';
        },
        agents: {agent.id: agent},
      );

      final spawned = await sessions.handleSessionsSpawn({'agent': agent.id, 'message': 'first'});
      final sessionId = spawned['sessionId'] as String;
      expect(sessionId, startsWith('agent:review%3Asecurity:logical:'));

      await sessions.handleSessionsSend({'session_id': sessionId, 'message': 'second'});
      expect(dispatchedAgent, agent.id);
    });

    test('sessions_spawn rejects an unknown agent', () async {
      final sessions = _sessions(searchAgent);

      final result = await sessions.handleSessionsSpawn({'agent': 'nonexistent', 'message': 'test'});

      expect(result['isError'], isTrue);
      expect((result['content'] as List).first['text'], contains('Unknown agent'));
    });

    test('sessions_spawn rejects an empty configured agent ID before dispatch', () async {
      var dispatched = false;
      const emptyAgent = AgentDefinition(id: '', description: 'Invalid', prompt: 'Invalid');
      final sessions = LogicalAgentSessionService(
        dispatch: ({required sessionId, required message, required agentId, required createSession}) async {
          dispatched = true;
          return 'unexpected';
        },
        agents: const {'': emptyAgent},
      );

      final result = await sessions.handleSessionsSpawn({'agent': '', 'message': 'test'});

      expect(result['isError'], isTrue);
      expect(dispatched, isFalse);
    });

    test('sessions_send rejects malformed or unknown session handles', () async {
      final sessions = _sessions(searchAgent);

      for (final sessionId in ['not-a-session', 'agent:missing:logical:123', 'agent:%ZZ:logical:123']) {
        final result = await sessions.handleSessionsSend({'session_id': sessionId, 'message': 'test'});
        expect(result['isError'], isTrue, reason: sessionId);
      }
    });

    test('spawn and send require their distinct parameters', () async {
      final sessions = _sessions(searchAgent);

      expect((await sessions.handleSessionsSpawn({'agent': 'search'}))['isError'], isTrue);
      expect((await sessions.handleSessionsSend({'agent': 'search', 'message': 'test'}))['isError'], isTrue);
    });

    test('logical-agent responses truncate at a valid UTF-8 boundary', () async {
      final smallAgent = AgentDefinition(
        id: 'search',
        description: 'test',
        prompt: 'test',
        allowedTools: {'WebSearch'},
        maxResponseBytes: 10,
      );
      final sessions = LogicalAgentSessionService(
        dispatch: ({required sessionId, required message, required agentId, required createSession}) async =>
            '12345678😀suffix',
        agents: {'search': smallAgent},
      );

      final result = await sessions.handleSessionsSpawn({'agent': 'search', 'message': 'test'});

      final text = (result['content'] as List).first['text'] as String;
      expect(text, '12345678');
      expect(utf8.encode(text).length, lessThanOrEqualTo(smallAgent.maxResponseBytes));
    });

    test('failed spawn discards its newly created session', () async {
      String? discardedSessionId;
      final sessions = LogicalAgentSessionService(
        dispatch: ({required sessionId, required message, required agentId, required createSession}) async {
          throw StateError('provider unavailable');
        },
        discardSession: (sessionId) async => discardedSessionId = sessionId,
        agents: {'search': searchAgent},
      );

      final result = await sessions.handleSessionsSpawn({'agent': 'search', 'message': 'test'});

      expect(result['isError'], isTrue);
      expect(discardedSessionId, startsWith('agent:search:logical:'));
    });
  });
}

LogicalAgentSessionService _sessions(AgentDefinition searchAgent) {
  return LogicalAgentSessionService(
    dispatch: ({required sessionId, required message, required agentId, required createSession}) async => 'ok',
    agents: {'search': searchAgent},
  );
}
