import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  group('InMemoryAgentExecutionRepository', () {
    test('stores executions, filters them, and disposes cleanly', () async {
      final repo = InMemoryAgentExecutionRepository();
      final older = _execution(id: 'ae-1', sessionId: 'sess-A', startedAt: DateTime.parse('2026-04-19T00:00:00Z'));
      final newer = _execution(id: 'ae-2', sessionId: 'sess-B', startedAt: DateTime.parse('2026-04-19T01:00:00Z'));

      await repo.create(older);
      await repo.create(newer);

      expect((await repo.list()).map((execution) => execution.id).toList(), ['ae-2', 'ae-1']);
      expect((await repo.list(sessionId: 'sess-A')).single.id, 'ae-1');

      await repo.dispose();
      expect(repo.disposed, isTrue);
    });

    test('matches sqlite repository behavior for core CRUD flows', () async {
      final db = openTaskDbInMemory();
      final sqliteRepo = SqliteAgentExecutionRepository(db);
      final memoryRepo = InMemoryAgentExecutionRepository();

      try {
        final sqliteState = await _exerciseRepository(sqliteRepo);
        final memoryState = await _exerciseRepository(memoryRepo);

        expect(memoryState, equals(sqliteState));
      } finally {
        db.close();
        await memoryRepo.dispose();
      }
    });
  });
}

Future<Map<String, Object?>> _exerciseRepository(AgentExecutionRepository repository) async {
  await repository.create(
    _execution(id: 'ae-1', sessionId: 'sess-A', provider: 'claude', startedAt: DateTime.parse('2026-04-19T00:00:00Z')),
  );
  await repository.create(
    _execution(id: 'ae-2', sessionId: 'sess-A', provider: 'codex', startedAt: DateTime.parse('2026-04-19T01:00:00Z')),
  );
  await repository.create(
    _execution(id: 'ae-3', sessionId: 'sess-B', provider: 'claude', startedAt: DateTime.parse('2026-04-19T02:00:00Z')),
  );

  await repository.update(
    _execution(
      id: 'ae-2',
      sessionId: 'sess-A',
      provider: 'codex',
      model: 'gpt-5-codex',
      startedAt: DateTime.parse('2026-04-19T01:00:00Z'),
      completedAt: DateTime.parse('2026-04-19T03:00:00Z'),
    ),
  );

  await repository.delete('missing');

  return {
    'all': (await repository.list()).map((execution) => execution.toJson()).toList(),
    'sessA': (await repository.list(sessionId: 'sess-A')).map((execution) => execution.toJson()).toList(),
    'providerCodex': (await repository.list(provider: 'codex')).map((execution) => execution.toJson()).toList(),
    'missing': await repository.get('missing'),
  };
}

AgentExecution _execution({
  required String id,
  required String sessionId,
  String provider = 'claude',
  String? model = 'claude-opus-4-7',
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
