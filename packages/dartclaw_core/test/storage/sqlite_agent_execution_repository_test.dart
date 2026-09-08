import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  group('SqliteAgentExecutionRepository', () {
    late Database db;
    late SqliteBackend backend;
    late SqliteAgentExecutionRepository repository;

    setUp(() async {
      db = openTaskDbInMemory();
      backend = SqliteBackend(db);
      await SqliteSchemaGate.prepareTasks(backend, storeName: 'tasks.db');
      repository = SqliteAgentExecutionRepository(db);
    });

    tearDown(() async {
      await backend.close();
    });

    test('creates table and indexes', () {
      final names = db
          .select("SELECT name FROM sqlite_master WHERE type IN ('table', 'index') ORDER BY name")
          .map((row) => row['name'])
          .toList();

      expect(names, contains('agent_executions'));
      expect(names, contains('idx_agent_executions_session_id'));
      expect(names, contains('idx_agent_executions_provider'));
    });

    test('round-trips an execution with nullable fields', () async {
      final execution = AgentExecution(
        id: 'ae-1',
        sessionId: 'sess-1',
        provider: 'claude',
        model: 'claude-opus-4-7',
        budgetTokens: 50000,
        startedAt: DateTime.parse('2026-04-19T00:00:00Z'),
      );

      await repository.create(execution);

      expect(await repository.get('ae-1'), equals(execution));
    });

    test('lists by session ordered by started_at descending', () async {
      await repository.create(
        _execution(id: 'ae-1', sessionId: 'sess-A', startedAt: DateTime.parse('2026-04-19T00:00:00Z')),
      );
      await repository.create(
        _execution(id: 'ae-2', sessionId: 'sess-A', startedAt: DateTime.parse('2026-04-19T02:00:00Z')),
      );
      await repository.create(
        _execution(id: 'ae-3', sessionId: 'sess-A', startedAt: DateTime.parse('2026-04-19T01:00:00Z')),
      );
      await repository.create(
        _execution(id: 'ae-4', sessionId: 'sess-B', startedAt: DateTime.parse('2026-04-19T03:00:00Z')),
      );

      final rows = await repository.list(sessionId: 'sess-A');

      expect(rows.map((execution) => execution.id).toList(), ['ae-2', 'ae-3', 'ae-1']);
    });

    test('updates and deletes executions', () async {
      await repository.create(_execution(id: 'ae-1', sessionId: 'sess-A'));

      await repository.update(
        _execution(
          id: 'ae-1',
          sessionId: 'sess-B',
          provider: 'codex',
          model: 'gpt-5-codex',
          completedAt: DateTime.parse('2026-04-19T01:00:00Z'),
        ),
      );

      final updated = await repository.get('ae-1');
      expect(updated?.sessionId, 'sess-B');
      expect(updated?.provider, 'codex');
      expect(updated?.completedAt, DateTime.parse('2026-04-19T01:00:00Z'));

      await repository.delete('ae-1');
      expect(await repository.get('ae-1'), isNull);
    });

    test('duplicate id surfaces sqlite constraint error', () async {
      final execution = _execution(id: 'ae-1', sessionId: 'sess-A');
      await repository.create(execution);

      await expectLater(repository.create(execution), throwsA(isA<SqliteException>()));
    });
  });
}

AgentExecution _execution({
  required String id,
  required String sessionId,
  String provider = 'claude',
  String model = 'claude-opus-4-7',
  DateTime? startedAt,
  DateTime? completedAt,
}) {
  return AgentExecution(
    id: id,
    sessionId: sessionId,
    provider: provider,
    model: model,
    workspaceDir: '/tmp/$id',
    containerJson: '{"profile":"plain"}',
    budgetTokens: 50000,
    harnessMetaJson: '{"providerSessionId":"$id"}',
    startedAt: startedAt,
    completedAt: completedAt,
  );
}
