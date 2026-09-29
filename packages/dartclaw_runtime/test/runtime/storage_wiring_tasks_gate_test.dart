@Tags(['integration'])
library;

import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/runtime/storage_wiring.dart';
import 'package:test/test.dart';

import '../../../dartclaw_core/test/storage/postgres_live_support.dart';

void main() {
  test('PostgreSQL storage is prepared before repositories are used', () async {
    await withPostgresBackend((backend, _) async {
      final root = Directory.systemTemp.createTempSync('storage-wiring-task-gate-');
      final wiring = _wiring(root, backend);
      try {
        await wiring.wire();

        final marker = (await backend.query('SELECT id, epoch FROM dartclaw_schema')).single;
        expect([marker['id'], marker['epoch']], [1, 1]);
        final tables = (await backend.query('''
          SELECT table_name
          FROM information_schema.tables
          WHERE table_schema = current_schema()
        ''')).map((row) => row['table_name']).toSet();
        expect(
          tables,
          containsAll([
            'agent_executions',
            'workflow_step_executions',
            'tasks',
            'task_artifacts',
            'goals',
            'task_events',
            'turns',
            'kg_facts',
            'workflow_runs',
          ]),
        );
      } finally {
        await wiring.dispose();
        if (root.existsSync()) root.deleteSync(recursive: true);
      }
    });
  });

  test('preparing an existing PostgreSQL store preserves domain rows', () async {
    await withPostgresBackend((backend, _) async {
      await PostgresSchemaGate.prepare(backend, databaseIdentity: 'storage-wiring-existing');
      final repository = DatabaseTaskRepository(backend);
      await repository.insert(
        Task(
          id: 'task-1',
          title: 'Existing',
          description: 'Preserve me',
          status: TaskStatus.draft,
          createdAt: DateTime.utc(2026, 9, 8),
        ),
      );
      final root = Directory.systemTemp.createTempSync('storage-wiring-task-existing-');
      final wiring = _wiring(root, backend);
      try {
        await wiring.wire();
        final retained = await wiring.taskRepository.getById('task-1');
        expect(retained?.title, 'Existing');
        expect(retained?.description, 'Preserve me');
        expect((await backend.query('SELECT epoch FROM dartclaw_schema WHERE id = 1')).single['epoch'], 1);
      } finally {
        await wiring.dispose();
        if (root.existsSync()) root.deleteSync(recursive: true);
      }
    });
  });

  test('an incompatible PostgreSQL schema is refused without mutating it', () async {
    await withPostgresBackend((backend, _) async {
      await backend.execute('CREATE TABLE unrelated_tasks (id text PRIMARY KEY, title text NOT NULL)');
      await backend.execute("INSERT INTO unrelated_tasks (id, title) VALUES ('legacy-1', 'Legacy')");
      final root = Directory.systemTemp.createTempSync('storage-wiring-task-incompatible-');
      final wiring = _wiring(root, _NonClosingBackend(backend));
      try {
        await expectLater(wiring.wire(), throwsA(isA<_Exit>().having((error) => error.code, 'code', 1)));
        expect(await backend.query('SELECT id, title FROM unrelated_tasks'), [
          {'id': 'legacy-1', 'title': 'Legacy'},
        ]);
        expect(await backend.query("SELECT to_regclass('dartclaw_schema') AS relation"), [
          {'relation': null},
        ]);
      } finally {
        if (root.existsSync()) root.deleteSync(recursive: true);
      }
    });
  });
}

StorageWiring _wiring(Directory root, DatabaseBackend backend) => StorageWiring(
  config: DartclawConfig(server: ServerConfig(dataDir: root.path)),
  eventBus: EventBus(),
  taskBackendFactory: (_) async => backend,
  exitFn: (code) => throw _Exit(code),
  personalMemoryEnabled: false,
);

final class _NonClosingBackend implements DatabaseBackend {
  const new(this.delegate);

  final DatabaseBackend delegate;

  @override
  Future<void> close() async {}

  @override
  Future<int> execute(String sql, [List<Object?> parameters = const []]) => delegate.execute(sql, parameters);

  @override
  Future<DatabaseStatement> prepare(String sql) => delegate.prepare(sql);

  @override
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?> parameters = const []]) =>
      delegate.query(sql, parameters);

  @override
  Future<T> transaction<T>(Future<T> Function(DatabaseBackend tx) body) =>
      delegate.transaction((tx) => body(_NonClosingBackend(tx)));
}

final class _Exit implements Exception {
  const new(this.code);

  final int code;
}
