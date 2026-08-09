import 'dart:convert';

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
    test('sessions_spawn creates a new delegated session and returns its handle', () async {
      final calls = <({String sessionId, String message, String agentId, bool createSession})>[];
      final delegate = SessionDelegate(
        dispatch: ({required sessionId, required message, required agentId, required createSession}) async {
          calls.add((sessionId: sessionId, message: message, agentId: agentId, createSession: createSession));
          return 'Search result for: $message';
        },
        limits: limits,
        agents: {'search': searchAgent},
      );

      final result = await delegate.handleSessionsSpawn({'agent': 'search', 'message': 'What is Dart?'});

      expect(result['isError'], isNull);
      expect(result['sessionId'], startsWith('agent:search:delegated:'));
      expect((result['content'] as List).first['text'], 'Search result for: What is Dart?');
      expect(calls.single.agentId, 'search');
      expect(calls.single.createSession, isTrue);
    });

    test('sessions_send resumes the delegated session returned by spawn', () async {
      final calls = <({String sessionId, String message, String agentId, bool createSession})>[];
      final delegate = SessionDelegate(
        dispatch: ({required sessionId, required message, required agentId, required createSession}) async {
          calls.add((sessionId: sessionId, message: message, agentId: agentId, createSession: createSession));
          return 'reply: $message';
        },
        limits: limits,
        agents: {'search': searchAgent},
      );
      final spawned = await delegate.handleSessionsSpawn({'agent': 'search', 'message': 'first'});
      final sessionId = spawned['sessionId'] as String;

      final sent = await delegate.handleSessionsSend({'session_id': sessionId, 'message': 'second'});

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
      final delegate = SessionDelegate(
        dispatch: ({required sessionId, required message, required agentId, required createSession}) async {
          dispatchedAgent = agentId;
          return 'ok';
        },
        limits: limits,
        agents: {agent.id: agent},
      );

      final spawned = await delegate.handleSessionsSpawn({'agent': agent.id, 'message': 'first'});
      final sessionId = spawned['sessionId'] as String;
      expect(sessionId, startsWith('agent:review%3Asecurity:delegated:'));

      await delegate.handleSessionsSend({'session_id': sessionId, 'message': 'second'});
      expect(dispatchedAgent, agent.id);
    });

    test('sessions_spawn rejects an unknown agent', () async {
      final delegate = _delegate(limits, searchAgent);

      final result = await delegate.handleSessionsSpawn({'agent': 'nonexistent', 'message': 'test'});

      expect(result['isError'], isTrue);
      expect((result['content'] as List).first['text'], contains('Unknown agent'));
    });

    test('sessions_spawn rejects an empty configured agent ID before dispatch', () async {
      var dispatched = false;
      const emptyAgent = AgentDefinition(id: '', description: 'Invalid', prompt: 'Invalid');
      final delegate = SessionDelegate(
        dispatch: ({required sessionId, required message, required agentId, required createSession}) async {
          dispatched = true;
          return 'unexpected';
        },
        limits: limits,
        agents: const {'': emptyAgent},
      );

      final result = await delegate.handleSessionsSpawn({'agent': '', 'message': 'test'});

      expect(result['isError'], isTrue);
      expect(dispatched, isFalse);
    });

    test('sessions_send rejects malformed or unknown session handles', () async {
      final delegate = _delegate(limits, searchAgent);

      for (final sessionId in ['not-a-session', 'agent:missing:delegated:123']) {
        final result = await delegate.handleSessionsSend({'session_id': sessionId, 'message': 'test'});
        expect(result['isError'], isTrue, reason: sessionId);
      }
    });

    test('spawn and send require their distinct parameters', () async {
      final delegate = _delegate(limits, searchAgent);

      expect((await delegate.handleSessionsSpawn({'agent': 'search'}))['isError'], isTrue);
      expect((await delegate.handleSessionsSend({'agent': 'search', 'message': 'test'}))['isError'], isTrue);
    });

    test('delegation returns an error when the global limit is reached', () async {
      final delegate = _delegate(SubagentLimits(maxConcurrent: 0), searchAgent);

      final result = await delegate.handleSessionsSpawn({'agent': 'search', 'message': 'test'});

      expect(result['isError'], isTrue);
      expect((result['content'] as List).first['text'], contains('limit'));
    });

    test('delegation truncates oversized responses at a valid UTF-8 boundary', () async {
      final smallAgent = AgentDefinition(
        id: 'search',
        description: 'test',
        prompt: 'test',
        allowedTools: {'WebSearch'},
        maxResponseBytes: 10,
      );
      final delegate = SessionDelegate(
        dispatch: ({required sessionId, required message, required agentId, required createSession}) async =>
            '12345678😀suffix',
        limits: limits,
        agents: {'search': smallAgent},
      );

      final result = await delegate.handleSessionsSpawn({'agent': 'search', 'message': 'test'});

      final text = (result['content'] as List).first['text'] as String;
      expect(text, '12345678');
      expect(utf8.encode(text).length, lessThanOrEqualTo(smallAgent.maxResponseBytes));
    });

    test('delegation frees its limit slot after success and failure', () async {
      var shouldThrow = false;
      final delegate = SessionDelegate(
        dispatch: ({required sessionId, required message, required agentId, required createSession}) async {
          if (shouldThrow) throw Exception('network error');
          return 'ok';
        },
        limits: limits,
        agents: {'search': searchAgent},
      );

      await delegate.handleSessionsSpawn({'agent': 'search', 'message': 'success'});
      expect(limits.totalActive, 0);
      shouldThrow = true;
      final failed = await delegate.handleSessionsSpawn({'agent': 'search', 'message': 'failure'});
      expect(failed['isError'], isTrue);
      expect(limits.totalActive, 0);
    });

    test('failed spawn discards its newly created session', () async {
      String? discardedSessionId;
      final delegate = SessionDelegate(
        dispatch: ({required sessionId, required message, required agentId, required createSession}) async {
          throw StateError('provider unavailable');
        },
        discardSession: (sessionId) async => discardedSessionId = sessionId,
        limits: limits,
        agents: {'search': searchAgent},
      );

      final result = await delegate.handleSessionsSpawn({'agent': 'search', 'message': 'test'});

      expect(result['isError'], isTrue);
      expect(discardedSessionId, startsWith('agent:search:delegated:'));
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
