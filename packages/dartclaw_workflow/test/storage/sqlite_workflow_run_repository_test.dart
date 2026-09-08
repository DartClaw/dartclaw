import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        SqliteWorkflowRunRepository,
        WorkflowExecutionCursor,
        WorkflowExecutionCursorNodeType,
        WorkflowRun,
        WorkflowWorktreeBinding;
import 'package:logging/logging.dart';
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
  WorkflowExecutionCursor? executionCursor,
  List<WorkflowWorktreeBinding> workflowWorktrees = const [],
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
    executionCursor: executionCursor,
    workflowWorktrees: workflowWorktrees,
  );
}

void main() {
  group('SqliteWorkflowRunRepository', () {
    late DatabaseBackend backend;
    late SqliteWorkflowRunRepository repository;

    setUp(() async {
      backend = await openPreparedTaskBackend();
      repository = SqliteWorkflowRunRepository(backend);
    });

    tearDown(() async {
      await backend.close();
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
        );
        await repository.insert(run);
        final loaded = await repository.getById(run.id);
        expect(loaded!.completedAt, completedAt);
        expect(loaded.errorMessage, 'some error');
      });

      test('execution cursor round-trips through SQLite storage', () async {
        final run = _buildRun(
          executionCursor: WorkflowExecutionCursor.foreach(
            stepId: 'foreach-step',
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
        expect(loaded?.executionCursor?.nodeType, WorkflowExecutionCursorNodeType.foreach);
        expect(loaded?.executionCursor?.nodeId, 'foreach-step');
        expect(loaded?.executionCursor?.completedIndices, [0, 1]);
        expect(loaded?.executionCursor?.failedIndices, [1]);
      });

      test('a row whose cursor names the retired "map" node type hydrates without a cursor', () async {
        final run = _buildRun(
          id: 'run-legacy-map-cursor',
          status: WorkflowRunStatus.running,
          executionCursor: WorkflowExecutionCursor.foreach(stepId: 'ms', stepIndex: 4, totalItems: 3),
        );
        await repository.insert(run);
        // Rewrite the persisted cursor to what an earlier version wrote for a
        // plain `map_over` controller.
        await backend.execute('UPDATE workflow_runs SET execution_cursor_json = ? WHERE id = ?', [
          '{"nodeType":"map","nodeId":"ms","stepIndex":4,"totalItems":3,"completedIndices":[0]}',
          run.id,
        ]);

        final records = <LogRecord>[];
        final logSub = Logger.root.onRecord.listen(records.add);
        final loaded = await repository.getById(run.id);
        await logSub.cancel();

        expect(loaded, isNotNull, reason: 'the run must hydrate rather than throw out of deserialization');
        expect(loaded?.executionCursor, isNull);
        expect(loaded?.status, WorkflowRunStatus.running);
        expect(
          records.where((r) => r.level >= Level.WARNING).map((r) => r.message),
          anyElement(allOf(contains('nodeType'), contains('map'))),
        );
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
        expect(all.map((run) => run.id), ['r3', 'r2', 'r1']);
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

    group('worktree bindings', () {
      const binding = WorkflowWorktreeBinding(
        key: 'story-a',
        path: '/tmp/worktrees/story-a',
        branch: 'story-a',
        workflowRunId: 'run-1',
      );

      test('persists the items wrapper JSON shape', () async {
        await repository.insert(_buildRun(workflowWorktrees: const [binding]));

        final row = (await backend.query('SELECT workflow_worktree_json FROM workflow_runs WHERE id = ?', [
          'run-1',
        ])).single;
        expect(
          row['workflow_worktree_json'],
          '{"items":[{"key":"story-a","path":"/tmp/worktrees/story-a","branch":"story-a","workflowRunId":"run-1"}]}',
        );
      });

      test('getWorktreeBindings preserves legacy single-binding decoding', () async {
        await repository.insert(_buildRun());
        await backend.execute('UPDATE workflow_runs SET workflow_worktree_json = ? WHERE id = ?', [
          '{"key":"story-a","path":"/tmp/worktrees/story-a","branch":"story-a","workflowRunId":"run-1"}',
          'run-1',
        ]);

        final bindings = await repository.getWorktreeBindings('run-1');
        expect(bindings, hasLength(1));
        expect(bindings.single.toJson(), binding.toJson());
      });

      test('set and get preserve bindings while update with no bindings keeps stored JSON', () async {
        final run = _buildRun();
        await repository.insert(run);
        await repository.setWorktreeBinding(run.id, binding);

        expect((await repository.getWorktreeBinding(run.id))?.toJson(), binding.toJson());
        expect((await repository.getWorktreeBindings(run.id)).single.toJson(), binding.toJson());

        await repository.update(run.copyWith(status: WorkflowRunStatus.running));
        expect((await repository.getWorktreeBindings(run.id)).single.toJson(), binding.toJson());
      });

      test('setWorktreeBinding throws for a missing run', () async {
        await expectLater(
          repository.setWorktreeBinding('missing', binding),
          throwsA(isA<ArgumentError>().having((error) => error.message, 'message', 'Workflow run not found: missing')),
        );
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
  });
}
