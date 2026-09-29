import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late FileExecutionStore store;
  late String path;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('dartclaw-file-execution-');
    path = '${directory.path}/execution.json';
    store = await FileExecutionStore.open(path);
  });

  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  test('checkpoint contents stay owner-only across atomic replacements', () async {
    expect((await File(path).stat()).mode & 0x1ff, 0x180);
    await store.update((state) {
      (state['goals'] as Map<String, dynamic>)['private'] = {'mission': 'private workflow context'};
    });
    expect((await File(path).stat()).mode & 0x1ff, 0x180);
  }, skip: Platform.isWindows ? 'POSIX file permissions' : false);

  test('transaction commits a task and linked execution and step across reopen', () async {
    final tasks = FileTaskRepository(store);
    final executions = FileAgentExecutionRepository(store);
    final steps = FileWorkflowStepExecutionRepository(store);
    final now = DateTime.utc(2026, 1, 1);
    final execution = AgentExecution(id: 'execution', provider: 'codex');
    final step = WorkflowStepExecution(
      taskId: 'task',
      agentExecutionId: execution.id,
      workflowRunId: 'run',
      stepIndex: 0,
      stepId: 'write',
    );
    final task = Task(
      id: 'task',
      title: 'Write result',
      description: 'Produce an artifact',
      createdAt: now,
      workflowRunId: 'run',
      stepIndex: 0,
      agentExecutionId: execution.id,
    );

    await store.transaction(() async {
      await executions.create(execution);
      await tasks.insert(task);
      await steps.create(step);
      expect((await tasks.getById(task.id))!.workflowStepExecution, step);
    });

    await store.close();
    store = await FileExecutionStore.open(path);
    final reopened = FileTaskRepository(store);
    final saved = (await reopened.getById(task.id))!;
    expect(saved.agentExecution, execution);
    expect(saved.workflowStepExecution, step);
    expect((await reopened.listByWorkflowRunIds(['run'])).single.id, task.id);
  });

  test('failed transaction leaves prior checkpoint unchanged', () async {
    final goals = FileGoalRepository(store);
    final before = await File(path).readAsString();

    await expectLater(
      store.transaction(() async {
        await goals.insert(Goal(id: 'goal', title: 'Goal', mission: 'Mission', createdAt: DateTime.utc(2026)));
        throw StateError('abort');
      }),
      throwsStateError,
    );

    expect(await File(path).readAsString(), before);
    expect(await goals.getById('goal'), isNull);
  });

  test('conditional mutation refuses stale versions and keeps disjoint config patches', () async {
    final tasks = FileTaskRepository(store);
    final task = Task(
      id: 'task',
      title: 'Work',
      description: 'Do work',
      status: TaskStatus.queued,
      createdAt: DateTime.utc(2026),
      configJson: {'first': 1},
    );
    await tasks.insert(task);
    final claimed = task.copyWith(status: TaskStatus.running);
    expect(await tasks.updateIfStatus(claimed, expectedStatus: TaskStatus.queued), isTrue);
    expect(await tasks.updateIfStatus(claimed, expectedStatus: TaskStatus.queued), isFalse);

    await Future.wait([
      tasks.mergeConfigJsonIfStatus('task', {'second': 2}, expectedStatus: TaskStatus.running),
      tasks.mergeConfigJsonIfStatus('task', {'third': 3}, expectedStatus: TaskStatus.running),
    ]);
    expect((await tasks.getById('task'))!.configJson, {'first': 1, 'second': 2, 'third': 3});
  });

  test('two handles serialize concurrent updates through one sidecar', () async {
    final second = await FileExecutionStore.open(path);
    try {
      await Future.wait(
        List.generate(20, (index) async {
          final target = index.isEven ? store : second;
          await target.update((state) async {
            final goals = state['goals'] as Map<String, dynamic>;
            goals['goal-$index'] = Goal(
              id: 'goal-$index',
              title: 'Goal $index',
              mission: 'Persist every writer',
              createdAt: DateTime.utc(2026),
            ).toJson();
          });
        }),
      );
      expect((await FileGoalRepository(store).list()).length, 20);
    } finally {
      await second.close();
    }
  });

  test('joined operations use one draft and reject a second handle in the same operation', () async {
    final second = await FileExecutionStore.open(path);
    try {
      await store.update((state) async {
        (state['goals'] as Map<String, dynamic>)['one'] = {'id': 'one'};
        expect(await store.read((draft) => (draft['goals'] as Map<String, dynamic>).containsKey('one')), isTrue);
        await expectLater(second.read((_) => true), throwsStateError);
        await expectLater(store.transaction(() async => true), throwsStateError);
        await expectLater(store.close(), throwsStateError);
      });
      expect(await store.read((state) => (state['goals'] as Map<String, dynamic>).containsKey('one')), isTrue);
    } finally {
      await second.close();
    }
  });

  test('separate processes preserve every writer under the sidecar lock', () async {
    final packageScript = File('test/storage/file_execution_writer.dart');
    final script =
        (packageScript.existsSync()
                ? packageScript
                : File('packages/dartclaw_core/test/storage/file_execution_writer.dart'))
            .absolute
            .path;
    final results = await Future.wait([
      Process.run(Platform.resolvedExecutable, [script, path, 'first']),
      Process.run(Platform.resolvedExecutable, [script, path, 'second']),
    ]);
    for (final result in results) {
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    }
    expect((await store.read((state) => state['goals'] as Map<String, dynamic>)).length, 20);
  });

  test('events and traces retain chronology and full filtered summary after reopen', () async {
    final events = TaskEventService.file(store);
    final traces = TurnTraceService.file(store);
    final now = DateTime.utc(2026, 1, 1);
    await events.insert(
      TaskEvent(
        id: 'later',
        taskId: 'task',
        timestamp: now.add(const Duration(minutes: 1)),
        kind: TaskEventKind.tokenUpdate,
      ),
    );
    await events.insert(TaskEvent(id: 'earlier', taskId: 'task', timestamp: now, kind: TaskEventKind.statusChanged));
    await traces.insert(
      TurnTrace(
        id: 'turn',
        sessionId: 'session',
        taskId: 'task',
        startedAt: now,
        endedAt: now.add(const Duration(seconds: 2)),
        inputTokens: 11,
        outputTokens: 7,
      ),
    );

    await store.close();
    store = await FileExecutionStore.open(path);
    expect((await TaskEventService.file(store).listForTask('task')).map((event) => event.id), ['earlier', 'later']);
    final result = await TurnTraceService.file(store).query(taskId: 'task', limit: 0);
    expect(result.traces, isEmpty);
    expect(result.summary.traceCount, 1);
    expect(result.summary.totalInputTokens, 11);
    expect(result.summary.totalDurationMs, 2000);
  });

  test('invalid existing checkpoint is refused without replacement', () async {
    await store.close();
    const invalid = '{"schemaVersion":2,"tasks":{}}';
    await File(path).writeAsString(invalid);

    await expectLater(FileExecutionStore.open(path), throwsA(isA<FormatException>()));
    expect(await File(path).readAsString(), invalid);
    store = await FileExecutionStore.open('${directory.path}/another.json');
  });
}
