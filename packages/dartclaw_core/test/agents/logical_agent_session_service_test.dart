import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
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

  _outputSchemaEnforcementTests();
}

LogicalAgentSessionService _sessions(AgentDefinition searchAgent) {
  return LogicalAgentSessionService(
    dispatch: ({required sessionId, required message, required agentId, required createSession}) async => 'ok',
    agents: {'search': searchAgent},
  );
}

/// Agent bound to `{title: string}` with `title` required.
AgentDefinition _schemaAgent({int maxResponseBytes = 5 * 1024 * 1024}) {
  final warns = <String>[];
  final agent = AgentDefinition.fromYaml('research', {
    'prompt': 'Research',
    'tools': ['web_search'],
    'max_response_bytes': maxResponseBytes,
    'output_schema': {
      'type': 'object',
      'properties': {
        'title': {'type': 'string'},
      },
      'required': ['title'],
    },
  }, warns);
  expect(warns, isEmpty);
  return agent;
}

LogicalAgentSessionService _schemaSessions(
  AgentDefinition agent,
  String reply, {
  ContentGuard? contentGuard,
  GuardAuditLogger? auditLogger,
  Future<void> Function(String sessionId)? discardSession,
}) => LogicalAgentSessionService(
  dispatch: ({required sessionId, required message, required agentId, required createSession}) async => reply,
  agents: {agent.id: agent},
  contentGuard: contentGuard,
  auditLogger: auditLogger,
  discardSession: discardSession,
);

String _text(Map<String, dynamic> result) => (result['content'] as List).first['text'] as String;

void _outputSchemaEnforcementTests() {
  group('LogicalAgentSessionService output_schema enforcement', () {
    test('conforming output is returned unmodified', () async {
      final sessions = _schemaSessions(_schemaAgent(), '{"title":"x"}');

      final result = await sessions.handleSessionsSpawn({'agent': 'research', 'message': 'go'});

      expect(result['isError'], isNull);
      expect(_text(result), '{"title":"x"}');
    });

    test('an unknown property fails the turn naming its pointer', () async {
      final sessions = _schemaSessions(_schemaAgent(), '{"title":"x","extra":1}');

      final result = await sessions.handleSessionsSpawn({'agent': 'research', 'message': 'go'});

      expect(result['isError'], isTrue);
      expect(_text(result), contains('/unknown-'));
      expect(_text(result), isNot(contains('"title":"x"')));
    });

    test('a missing required property fails the turn naming its pointer', () async {
      final sessions = _schemaSessions(_schemaAgent(), '{}');

      final result = await sessions.handleSessionsSpawn({'agent': 'research', 'message': 'go'});

      expect(result['isError'], isTrue);
      expect(_text(result), contains('/title'));
    });

    test('prose and fenced JSON both fail as parse failures without echoing the result', () async {
      const marker = 'MARKER-SECRET-PAYLOAD';
      for (final reply in ['Here is the answer: $marker', '```json\n{"title":"$marker"}\n```']) {
        final sessions = _schemaSessions(_schemaAgent(), reply);

        final result = await sessions.handleSessionsSpawn({'agent': 'research', 'message': 'go'});

        expect(result['isError'], isTrue, reason: reply);
        expect(_text(result).toLowerCase(), contains('json'), reason: reply);
        expect(_text(result), isNot(contains(marker)), reason: reply);
        expect(_text(result).toLowerCase(), isNot(contains('output_schema violation')), reason: reply);
      }
    });

    test('duplicate object members fail even when their decoded names match only after escaping', () async {
      for (final reply in [
        '{"title":"first","title":"second"}',
        '{"nested":{"title":"first","title":"second"},"title":"outer"}',
        '{"title":"first","\\u0074itle":"second"}',
      ]) {
        final sessions = _schemaSessions(_schemaAgent(), reply);

        final result = await sessions.handleSessionsSpawn({'agent': 'research', 'message': 'go'});

        expect(result['isError'], isTrue, reason: reply);
        expect(_text(result), contains('duplicate object member'));
        expect(_text(result), isNot(contains('first')));
      }
    });

    test('conforming output over max_response_bytes fails rather than truncating', () async {
      final agent = _schemaAgent(maxResponseBytes: 64);
      final reply = '{"title":"${'x' * 100}"}';
      final sessions = _schemaSessions(agent, reply);

      final result = await sessions.handleSessionsSpawn({'agent': 'research', 'message': 'go'});

      expect(result['isError'], isTrue);
      expect(_text(result), contains('64'));
      expect(_text(result), isNot(contains('xxx')));
    });

    test('an agent without output_schema still truncates and succeeds', () async {
      const plain = AgentDefinition(id: 'plain', description: 'Plain', prompt: 'Plain', maxResponseBytes: 10);
      final sessions = _schemaSessions(plain, '12345678😀suffix');

      final result = await sessions.handleSessionsSpawn({'agent': 'plain', 'message': 'go'});

      expect(result['isError'], isNull);
      expect(_text(result), '12345678');
    });

    test('the content guard wins over a parse failure and its verdict is audited', () async {
      final audits = <String>[];
      final guard = ContentGuard(
        scan: ContentScan(classifier: FakeContentClassifier(result: 'prompt_injection')),
      );
      final sessions = _schemaSessions(
        _schemaAgent(),
        'not json at all',
        contentGuard: guard,
        auditLogger: _RecordingAuditLogger(audits),
      );

      final result = await sessions.handleSessionsSpawn({'agent': 'research', 'message': 'go'});

      expect(result['isError'], isTrue);
      expect(_text(result), contains('content-guard'));
      expect(audits.single, contains('block'));
    });

    test('a schema failure writes no audit entry of its own', () async {
      final audits = <String>[];
      final sessions = _schemaSessions(
        _schemaAgent(),
        '{"title":"x","extra":1}',
        contentGuard: ContentGuard(scan: ContentScan(classifier: FakeContentClassifier())),
        auditLogger: _RecordingAuditLogger(audits),
      );

      final result = await sessions.handleSessionsSpawn({'agent': 'research', 'message': 'go'});

      expect(result['isError'], isTrue);
      // Only the guard's own pass verdict — a schema rejection is not a guard verdict.
      expect(audits, equals(['pass content-guard beforeAgentSend']));
    });

    test('an oversize non-JSON result fails on parsing, not on size', () async {
      final agent = _schemaAgent(maxResponseBytes: 8);
      final sessions = _schemaSessions(agent, 'prose that is far longer than eight bytes');

      final result = await sessions.handleSessionsSpawn({'agent': 'research', 'message': 'go'});

      expect(result['isError'], isTrue);
      expect(_text(result).toLowerCase(), contains('json'));
      expect(_text(result), isNot(contains('8 bytes')));
    });

    test('an oversize unknown property name is bounded in the violation message', () async {
      final longKey = 'k' * 1024;
      final sessions = _schemaSessions(_schemaAgent(), '{"title":"x","$longKey":1}');

      final result = await sessions.handleSessionsSpawn({'agent': 'research', 'message': 'go'});

      expect(result['isError'], isTrue);
      expect(_text(result), contains(RegExp(r'/unknown-[0-9a-f]{16}')));
      expect(_text(result), isNot(contains('kkkk')));
    });

    test('a failed spawn under a schema discards its newly created session', () async {
      String? discarded;
      final sessions = _schemaSessions(
        _schemaAgent(),
        'not json',
        discardSession: (sessionId) async => discarded = sessionId,
      );

      await sessions.handleSessionsSpawn({'agent': 'research', 'message': 'go'});

      expect(discarded, startsWith('agent:research:logical:'));
    });
  });
}

class _RecordingAuditLogger extends GuardAuditLogger {
  new(this.records);

  final List<String> records;

  @override
  void logVerdict({
    required GuardVerdict verdict,
    required String guardName,
    required String guardCategory,
    required String hookPoint,
    required DateTime timestamp,
    String? rawProviderToolName,
    String? agentId,
    String? sessionId,
    String? channel,
    String? peerId,
    String? server,
    String? tool,
    String? decision,
    String? principal,
    String? credentialRef,
  }) => records.add('${verdict.isBlock ? 'block' : 'pass'} $guardName $hookPoint');
}
