import 'package:dartclaw_core/dartclaw_core.dart'
    show WorkflowExecutionCursor, WorkflowExecutionCursorNodeType, WorkflowRun, WorkflowRunStatus;
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

WorkflowRun _buildRun({
  String id = 'run-1',
  String definitionName = 'test-workflow',
  WorkflowRunStatus status = WorkflowRunStatus.pending,
  Map<String, dynamic>? contextJson,
  Map<String, String>? variablesJson,
  Map<String, dynamic>? definitionJson,
  DateTime? completedAt,
  String? errorMessage,
  String? currentLoopId,
  int? currentLoopIteration,
  WorkflowExecutionCursor? executionCursor,
}) {
  final now = DateTime.parse('2026-01-01T10:00:00Z');
  return WorkflowRun(
    id: id,
    definitionName: definitionName,
    status: status,
    contextJson: contextJson ?? const {},
    variablesJson: variablesJson ?? const {},
    startedAt: now,
    updatedAt: now,
    completedAt: completedAt,
    errorMessage: errorMessage,
    definitionJson: definitionJson ?? const {},
    currentLoopId: currentLoopId,
    currentLoopIteration: currentLoopIteration,
    executionCursor: executionCursor,
  );
}

void main() {
  group('SqliteWorkflowRunRepository', () {
    late Database db;
    late SqliteWorkflowRunRepository repository;

    setUp(() {
      db = sqlite3.openInMemory();
      repository = SqliteWorkflowRunRepository(db);
    });

    tearDown(() {
      db.close();
    });

    group('schema', () {
      test('creates workflow_runs table and indexes', () {
        final tables = db.select("SELECT name FROM sqlite_master WHERE type IN ('table', 'index') ORDER BY name");
        final names = tables.map((r) => r['name']).toList();
        expect(names, contains('workflow_runs'));
        expect(names, contains('idx_workflow_runs_status'));
        expect(names, contains('idx_workflow_runs_definition'));
      });

      test('schema creation is idempotent', () {
        // Creating a second repository with the same db must not throw
        expect(() => SqliteWorkflowRunRepository(db), returnsNormally);
      });
    });

    group('insert and getById', () {
      test('round-trips basic run', () async {
        final run = _buildRun();
        await repository.insert(run);
        final loaded = await repository.getById(run.id);

        expect(loaded, isNotNull);
        expect(loaded!.id, run.id);
        expect(loaded.definitionName, run.definitionName);
        expect(loaded.status, WorkflowRunStatus.pending);
        expect(loaded.totalTokens, 0);
        expect(loaded.currentStepIndex, 0);
      });

      test('getById returns null for nonexistent id', () async {
        expect(await repository.getById('nonexistent'), isNull);
      });

      test('contextJson round-trips through JSON encoding', () async {
        final run = _buildRun(contextJson: {'key': 'value', 'num': 42});
        await repository.insert(run);
        final loaded = await repository.getById(run.id);
        expect(loaded!.contextJson['key'], 'value');
        expect(loaded.contextJson['num'], 42);
      });

      test('variablesJson round-trips', () async {
        final run = _buildRun(variablesJson: {'VAR': 'hello', 'ENV': 'prod'});
        await repository.insert(run);
        final loaded = await repository.getById(run.id);
        expect(loaded!.variablesJson['VAR'], 'hello');
        expect(loaded.variablesJson['ENV'], 'prod');
      });

      test('definitionJson round-trips', () async {
        final run = _buildRun(definitionJson: {'name': 'test', 'steps': []});
        await repository.insert(run);
        final loaded = await repository.getById(run.id);
        expect(loaded!.definitionJson['name'], 'test');
      });

      test('nullable fields persist correctly', () async {
        final completedAt = DateTime.parse('2026-01-01T11:00:00Z');
        final run = _buildRun(
          status: WorkflowRunStatus.completed,
          completedAt: completedAt,
          errorMessage: 'some error',
          currentLoopId: 'loop-1',
          currentLoopIteration: 2,
        );
        await repository.insert(run);
        final loaded = await repository.getById(run.id);
        expect(loaded!.completedAt, completedAt);
        expect(loaded.errorMessage, 'some error');
        expect(loaded.currentLoopId, 'loop-1');
        expect(loaded.currentLoopIteration, 2);
      });

      test('execution cursor round-trips through SQLite storage', () async {
        final run = _buildRun(
          executionCursor: WorkflowExecutionCursor.map(
            stepId: 'map-step',
            stepIndex: 2,
            totalItems: 3,
            completedIndices: const [0, 1],
            failedIndices: const [1],
            resultSlots: const [
              'ok',
              {'error': true, 'message': 'failed'},
              null,
            ],
          ),
        );
        await repository.insert(run);

        final loaded = await repository.getById(run.id);
        expect(loaded?.executionCursor?.nodeType, WorkflowExecutionCursorNodeType.map);
        expect(loaded?.executionCursor?.nodeId, 'map-step');
        expect(loaded?.executionCursor?.completedIndices, [0, 1]);
        expect(loaded?.executionCursor?.failedIndices, [1]);
      });
    });

    group('list', () {
      setUp(() async {
        await repository.insert(_buildRun(id: 'r1', status: WorkflowRunStatus.running));
        await repository.insert(_buildRun(id: 'r2', status: WorkflowRunStatus.completed, definitionName: 'wf-b'));
        await repository.insert(_buildRun(id: 'r3', status: WorkflowRunStatus.pending));
      });

      test('list with no filters returns all runs', () async {
        final all = await repository.list();
        expect(all.length, 3);
      });

      test('list filtered by status returns correct subset', () async {
        final running = await repository.list(status: WorkflowRunStatus.running);
        expect(running.length, 1);
        expect(running[0].id, 'r1');
      });

      test('list filtered by definitionName returns correct subset', () async {
        final wfb = await repository.list(definitionName: 'wf-b');
        expect(wfb.length, 1);
        expect(wfb[0].id, 'r2');
      });

      test('list filtered by both status and definitionName', () async {
        final result = await repository.list(status: WorkflowRunStatus.completed, definitionName: 'wf-b');
        expect(result.length, 1);
        expect(result[0].id, 'r2');
      });
    });

    group('update', () {
      test('update changes mutable fields', () async {
        final run = _buildRun();
        await repository.insert(run);

        final updated = run.copyWith(status: WorkflowRunStatus.running, totalTokens: 500, currentStepIndex: 1);
        await repository.update(updated);

        final loaded = await repository.getById(run.id);
        expect(loaded!.status, WorkflowRunStatus.running);
        expect(loaded.totalTokens, 500);
        expect(loaded.currentStepIndex, 1);
      });
    });

    group('delete', () {
      test('delete removes run', () async {
        final run = _buildRun();
        await repository.insert(run);
        await repository.delete(run.id);
        expect(await repository.getById(run.id), isNull);
      });
    });

    group('S36 legacy paused → awaitingApproval / failed migration', () {
      // Uses a dedicated in-memory DB per test so the migration ledger is
      // fresh (the shared setUp already runs the migration on its db).
      late Database migrationDb;

      setUp(() {
        migrationDb = sqlite3.openInMemory();
        // Seed minimal workflow_runs table matching the repository schema.
        migrationDb.execute('''
          CREATE TABLE workflow_runs (
            id TEXT PRIMARY KEY,
            definition_name TEXT,
            status TEXT,
            context_json TEXT,
            variables_json TEXT,
            started_at TEXT,
            updated_at TEXT,
            completed_at TEXT,
            error_message TEXT,
            total_tokens INTEGER DEFAULT 0,
            current_step_index INTEGER DEFAULT 0,
            definition_json TEXT,
            execution_cursor_json TEXT,
            current_loop_id TEXT,
            current_loop_iteration INTEGER
          )
        ''');
      });

      tearDown(() {
        migrationDb.close();
      });

      test('reclassifies paused rows: with pending approval → awaitingApproval, without → failed', () async {
        migrationDb.execute('''
          INSERT INTO workflow_runs (id, definition_name, status, context_json, variables_json,
            started_at, updated_at, definition_json)
          VALUES ('run-approval', 'wf', 'paused',
            '{"_approval.pending.stepId":"gate"}', '{}',
            '2026-01-01T10:00:00Z', '2026-01-01T10:00:00Z', '{}')
        ''');
        migrationDb.execute('''
          INSERT INTO workflow_runs (id, definition_name, status, context_json, variables_json,
            started_at, updated_at, definition_json)
          VALUES ('run-failure', 'wf', 'paused',
            '{}', '{}',
            '2026-01-01T10:00:00Z', '2026-01-01T10:00:00Z', '{}')
        ''');

        final repo = SqliteWorkflowRunRepository(migrationDb);

        expect((await repo.getById('run-approval'))?.status, WorkflowRunStatus.awaitingApproval);
        expect((await repo.getById('run-failure'))?.status, WorkflowRunStatus.failed);
      });

      test('migration runs once and does not touch later user-initiated paused rows', () async {
        // First construction applies the migration (nothing to reclassify).
        final repo = SqliteWorkflowRunRepository(migrationDb);

        // After migration: a legitimately paused run must not be reclassified on re-open.
        await repo.insert(_buildRun(id: 'post-migration-paused', status: WorkflowRunStatus.paused));

        final repo2 = SqliteWorkflowRunRepository(migrationDb);
        expect((await repo2.getById('post-migration-paused'))?.status, WorkflowRunStatus.paused);
      });
    });
  });
}
