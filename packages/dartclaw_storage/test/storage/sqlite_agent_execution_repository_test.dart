import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  group('SqliteAgentExecutionRepository', () {
    late Database db;
    late SqliteAgentExecutionRepository repository;

    setUp(() {
      db = openTaskDbInMemory();
      repository = SqliteAgentExecutionRepository(db);
    });

    tearDown(() {
      db.close();
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

  group('SqliteTaskRepository migration', () {
    test('migrates an S31-style tasks database by moving runtime columns onto AgentExecution', () async {
      final tempDir = await Directory.systemTemp.createTemp('dartclaw-s34-migration-');
      final dbPath = p.join(tempDir.path, 'tasks.db');

      try {
        final preS32Db = openTaskDb(dbPath);
        preS32Db.execute('''
          CREATE TABLE tasks (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            description TEXT NOT NULL,
            type TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'draft',
            version INTEGER NOT NULL DEFAULT 1,
            goal_id TEXT,
            session_id TEXT,
            acceptance_criteria TEXT,
            config_json TEXT NOT NULL DEFAULT '{}',
            worktree_json TEXT,
            created_at TEXT NOT NULL,
            started_at TEXT,
            completed_at TEXT,
            created_by TEXT,
            provider TEXT,
            project_id TEXT,
            max_tokens INTEGER,
            workflow_run_id TEXT,
            step_index INTEGER,
            max_retries INTEGER NOT NULL DEFAULT 0,
            retry_count INTEGER NOT NULL DEFAULT 0
          )
        ''');
        preS32Db.execute('''
          INSERT INTO tasks (
            id, title, description, type, status, version, goal_id, session_id,
            acceptance_criteria, config_json, worktree_json, created_at,
            started_at, completed_at, created_by, provider, project_id,
            max_tokens, workflow_run_id, step_index, max_retries, retry_count
          ) VALUES (
            'task-1', 'Title', 'Description', 'coding', 'draft', 1, 'goal-1', 'sess-1',
            'ship it', '{"model":"claude-opus-4"}', NULL, '2026-04-19T00:00:00Z',
            NULL, NULL, 'tester', 'claude', '_local',
            50000, 'run-1', 0, 0, 0
          )
        ''');
        preS32Db.close();

        // Re-open with the post-S34 `SqliteTaskRepository`, which runs the
        // migration that drops `session_id`/`provider`/`max_tokens` from
        // `tasks`, extracts `model` out of `config_json`, and backfills an
        // `agent_executions` row linked via `agent_execution_id`.
        final migratedDb = openTaskDb(dbPath);
        SqliteTaskRepository(migratedDb);

        final columns = migratedDb
            .select('PRAGMA table_info(tasks)')
            .map((row) => row['name'] as String)
            .toSet();
        expect(columns, contains('agent_execution_id'));
        expect(columns, isNot(contains('session_id')), reason: 'S34 drops session_id from tasks');
        expect(columns, isNot(contains('provider')), reason: 'S34 drops provider from tasks');
        expect(columns, isNot(contains('max_tokens')), reason: 'S34 drops max_tokens from tasks');

        final row = migratedDb.select('SELECT * FROM tasks WHERE id = ?', ['task-1']).single;
        expect(row['agent_execution_id'], isNotNull);
        final configJson = jsonDecode(row['config_json'] as String) as Map<String, dynamic>;
        expect(configJson.containsKey('model'), isFalse, reason: 'model is extracted to AgentExecution');

        // Runtime fields now live on the linked AgentExecution row.
        final aeRow = migratedDb
            .select('SELECT * FROM agent_executions WHERE id = ?', [row['agent_execution_id']])
            .single;
        expect(aeRow['session_id'], 'sess-1');
        expect(aeRow['provider'], 'claude');
        expect(aeRow['model'], 'claude-opus-4');
        expect(aeRow['budget_tokens'], 50000);

        // Migration is idempotent — re-running on the post-S34 DB is a no-op.
        SqliteTaskRepository(migratedDb);
        final secondPass = migratedDb
            .select('SELECT agent_execution_id FROM tasks WHERE id = ?', ['task-1'])
            .single;
        expect(secondPass['agent_execution_id'], row['agent_execution_id']);
        migratedDb.close();
      } finally {
        await tempDir.delete(recursive: true);
      }
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
