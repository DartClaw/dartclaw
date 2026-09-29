import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'workflow_service_test_support.dart';

void main() {
  late Directory directory;
  late FileExecutionStore store;
  late FileWorkflowRunRepository repository;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('workflow_file_store_');
    store = await FileExecutionStore.open(p.join(directory.path, 'execution.json'));
    repository = FileWorkflowRunRepository(store);
  });

  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  WorkflowRun run(String id) => WorkflowRun(
    id: id,
    definitionName: 'test-workflow',
    status: WorkflowRunStatus.paused,
    startedAt: DateTime.utc(2026, 1, 1),
    updatedAt: DateTime.utc(2026, 1, 1),
    contextJson: const {'approval': 'required'},
    variablesJson: const {'FEATURE': 'persist across processes'},
    definitionJson: const {'name': 'test-workflow', 'steps': []},
    totalTokens: 73,
    tokenUsageComplete: false,
    currentStepIndex: 2,
    executionCursor: WorkflowExecutionCursor.foreach(
      stepId: 'implement',
      stepIndex: 2,
      totalItems: 3,
      completedIndices: [0],
      resultSlots: ['done', null, null],
      completedSubStepIdsByIndex: {
        1: ['plan'],
      },
    ),
  );

  test('reopening retains the resume cursor, accounting and authored definition', () async {
    final original = run('resume-me');
    await repository.insert(original);
    await store.close();
    store = await FileExecutionStore.open(p.join(directory.path, 'execution.json'));
    repository = FileWorkflowRunRepository(store);

    expect((await repository.getById(original.id))!.toJson(), original.toJson());
  });

  test('a failed transaction does not publish a partial workflow checkpoint', () async {
    await repository.insert(run('existing'));
    await expectLater(
      store.transaction(() async {
        await repository.update(run('existing').copyWith(status: WorkflowRunStatus.completed));
        await repository.insert(run('uncommitted'));
        throw StateError('step creation failed');
      }),
      throwsStateError,
    );

    expect((await repository.getById('existing'))!.status, WorkflowRunStatus.paused);
    expect(await repository.getById('uncommitted'), isNull);
  });

  test('an unsupported persisted cursor fails instead of replaying settled work', () async {
    await repository.insert(run('unsupported'));
    await store.update((state) {
      final runs = state['workflowRuns'] as Map<String, dynamic>;
      final saved = runs['unsupported'] as Map<String, dynamic>;
      (saved['executionCursor'] as Map<String, dynamic>)['nodeType'] = 'future-node';
    });
    final checkpoint = File(store.path);
    final before = await checkpoint.readAsString();

    await expectLater(repository.getById('unsupported'), throwsFormatException);
    await expectLater(repository.list(), throwsFormatException);
    expect(await checkpoint.readAsString(), before);
  });

  test('status observation sees control changes from an independent handle', () async {
    await repository.insert(run('controlled').copyWith(status: WorkflowRunStatus.running));
    final otherStore = await FileExecutionStore.open(store.path);
    addTearDown(otherStore.close);
    final other = FileWorkflowRunRepository(otherStore);
    final observations = repository.watchStatus('controlled').asBroadcastStream();
    final running = observations.first;
    expect(await running, WorkflowRunStatus.running);
    final paused = observations.firstWhere((status) => status == WorkflowRunStatus.paused);
    await other.update(run('controlled'));
    expect(await paused.timeout(const Duration(seconds: 5)), WorkflowRunStatus.paused);
    final cancelled = observations.firstWhere((status) => status == WorkflowRunStatus.cancelled);
    await other.update(run('controlled').copyWith(status: WorkflowRunStatus.cancelled));
    expect(await cancelled.timeout(const Duration(seconds: 5)), WorkflowRunStatus.cancelled);
  });

  test('status observation cancels while the status stays paused', () async {
    await repository.insert(run('paused'));
    final first = Completer<WorkflowRunStatus>();
    final subscription = repository.watchStatus('paused').listen(first.complete);
    expect(await first.future, WorkflowRunStatus.paused);
    await subscription.cancel().timeout(const Duration(seconds: 2));
  });

  for (final control in [WorkflowRunStatus.paused, WorkflowRunStatus.cancelled]) {
    test('$control preserves latest progress and refuses stale executor writes', () async {
      final original = run('controlled').copyWith(status: WorkflowRunStatus.running);
      await repository.insert(original);
      final otherStore = await FileExecutionStore.open(store.path);
      addTearDown(otherStore.close);
      final controller = FileWorkflowRunRepository(otherStore);
      final stale = (await controller.getById(original.id))!;
      await repository.update(original.copyWith(currentStepIndex: 3, totalTokens: 100));

      final stopped = await controller.transitionStatus(original.id, expectedStatus: stale.status, status: control);
      expect(stopped!.currentStepIndex, 3);
      expect(stopped.totalTokens, 100);
      expect(
        await repository.update(
          original.copyWith(status: WorkflowRunStatus.completed),
          expectedStatus: WorkflowRunStatus.running,
        ),
        isFalse,
      );
      expect((await repository.getById(original.id))!.status, control);
    });
  }

  test('only one controller may claim a paused run for execution', () async {
    final paused = run('resume-once');
    await repository.insert(paused);
    final otherStore = await FileExecutionStore.open(store.path);
    addTearDown(otherStore.close);
    final other = FileWorkflowRunRepository(otherStore);
    final running = paused.copyWith(status: WorkflowRunStatus.running);
    final results = await Future.wait([
      repository.update(running, expectedStatus: WorkflowRunStatus.paused),
      other.update(running, expectedStatus: WorkflowRunStatus.paused),
    ]);
    expect(results.where((applied) => applied), hasLength(1));
  });

  test('a stale approval decision cannot replace a decision at the same status', () async {
    final original = run('approval');
    await repository.insert(original);
    final accepted = original.copyWith(
      contextJson: const {
        'data': {'gate.approval.status': 'approved'},
      },
      updatedAt: original.updatedAt.add(const Duration(microseconds: 1)),
    );
    expect(
      await repository.update(accepted, expectedStatus: original.status, expectedUpdatedAt: original.updatedAt),
      isTrue,
    );
    final rejected = original.copyWith(
      contextJson: const {
        'data': {'gate.approval.status': 'rejected'},
      },
    );
    expect(
      await repository.update(rejected, expectedStatus: original.status, expectedUpdatedAt: original.updatedAt),
      isFalse,
    );
    expect((await repository.getById(original.id))!.contextJson, accepted.contextJson);
  });

  test('resume retains a checkpointed approval when its context sidecar is stale', () async {
    final harness = WorkflowServiceTestHarness();
    await harness.setUp();
    harness.repository = repository;
    final service = harness.lifecycleOnlyService();
    addTearDown(() => harness.tearDown(currentService: service));
    final definition = WorkflowDefinition(
      name: 'approval-recovery',
      description: 'Resume after approval checkpoint publication',
      steps: const [
        WorkflowStep(id: 'done', name: 'Done', taskType: WorkflowTaskType.bash, prompts: ['echo done']),
      ],
    );
    final approved = WorkflowRun(
      id: 'approval-recovery',
      definitionName: definition.name,
      status: WorkflowRunStatus.awaitingApproval,
      startedAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
      definitionJson: definition.toJson(),
      contextJson: const {
        'data': {'gate.approval.status': 'approved'},
      },
    );
    await repository.insert(approved);
    harness.writeContextSnapshot(approved.id, const {
      'data': {'gate.approval.status': 'pending'},
    });

    await service.resume(approved.id);
    await harness.waitForRunStatus(approved.id, WorkflowRunStatus.completed);
    final completed = (await repository.getById(approved.id))!;
    expect((completed.contextJson['data'] as Map)['gate.approval.status'], 'approved');
  });

  test('concurrent worktree bindings survive independent repository instances', () async {
    await repository.insert(run('parallel'));
    final otherStore = await FileExecutionStore.open(p.join(directory.path, 'execution.json'));
    addTearDown(otherStore.close);
    final other = FileWorkflowRunRepository(otherStore);
    const first = WorkflowWorktreeBinding(key: 'one', path: '/one', branch: 'one', workflowRunId: 'parallel');
    const second = WorkflowWorktreeBinding(key: 'two', path: '/two', branch: 'two', workflowRunId: 'parallel');

    await Future.wait([repository.setWorktreeBinding('parallel', first), other.setWorktreeBinding('parallel', second)]);
    await repository.update(run('parallel').copyWith(status: WorkflowRunStatus.running));

    expect((await other.getWorktreeBindings('parallel')).map((binding) => binding.key), containsAll(['one', 'two']));
    expect((await other.getById('parallel'))!.status, WorkflowRunStatus.running);
  });

  test('listing filters and ties remain stable after deletion', () async {
    await repository.insert(run('a'));
    await repository.insert(run('b'));
    await repository.insert(run('c').copyWith(status: WorkflowRunStatus.completed, definitionName: 'different'));

    expect((await repository.list()).map((run) => run.id), ['c', 'b', 'a']);
    expect((await repository.list(status: WorkflowRunStatus.paused)).map((run) => run.id), ['b', 'a']);
    expect((await repository.list(definitionName: 'different')).single.id, 'c');
    await repository.delete('b');
    expect((await repository.list()).map((run) => run.id), ['c', 'a']);
    await expectLater(repository.insert(run('a')), throwsArgumentError);
  });
}
