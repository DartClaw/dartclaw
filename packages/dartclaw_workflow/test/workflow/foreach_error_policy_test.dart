@Tags(['component'])
library;

import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show OnErrorPolicy, OnFailurePolicy, WorkflowContext, WorkflowDefinition, WorkflowStep, WorkflowTaskType;
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart';

void main() {
  final h = WorkflowExecutorHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  WorkflowDefinition definition(String completedPath, String readyDir, {required OnErrorPolicy onError}) =>
      h.makeDefinition(
        steps: [
          const WorkflowStep(
            id: 'items',
            name: 'Items',
            taskType: WorkflowTaskType.foreach,
            mapOver: 'items',
            maxParallel: 2,
            foreachSteps: ['prepare', 'process'],
            onFailure: OnFailurePolicy.continueWorkflow,
          ),
          WorkflowStep(
            id: 'prepare',
            name: 'Prepare',
            taskType: WorkflowTaskType.bash,
            prompts: ["printf '%s' {{context.map.item}} >> '$completedPath'"],
          ),
          WorkflowStep(
            id: 'process',
            name: 'Process',
            taskType: WorkflowTaskType.bash,
            prompts: ['test -f $readyDir/{{context.map.item}}'],
            onError: onError,
          ),
          const WorkflowStep(
            id: 'after',
            name: 'After',
            taskType: WorkflowTaskType.bash,
            prompts: ['printf done'],
            entryGate: 'items.status == success',
          ),
        ],
      );

  test('foreach pause preserves successful items and child steps across resume', () async {
    final completedPath = '${h.tempDir.path}/completed';
    final readyDir = '${h.tempDir.path}/ready';
    Directory(readyDir).createSync();
    File('$readyDir/a').writeAsStringSync('ready');
    final workflow = definition(completedPath, readyDir, onError: OnErrorPolicy.pause);
    final run = h.makeRun(workflow);
    await h.repository.insert(run);
    await h.executor.execute(
      run,
      workflow,
      WorkflowContext(
        data: {
          'items': ['a', 'b'],
        },
      ),
    );
    final paused = (await h.repository.getById(run.id))!;
    expect(paused.status, WorkflowRunStatus.paused, reason: '${paused.contextJson}');
    expect(paused.errorMessage, contains('code 1'));
    expect(File(completedPath).readAsStringSync().split('').toSet(), {'a', 'b'});
    final before = File(completedPath).readAsStringSync();
    File('$readyDir/b').writeAsStringSync('ready');
    final running = paused.copyWith(status: WorkflowRunStatus.running);
    await h.repository.update(running);
    await h.executor.execute(
      running,
      workflow,
      WorkflowContext.fromJson(paused.contextJson),
      startFromStepIndex: paused.currentStepIndex,
      startCursor: paused.executionCursor,
    );
    final completed = (await h.repository.getById(run.id))!;
    expect(completed.status, WorkflowRunStatus.completed);
    expect(File(completedPath).readAsStringSync(), before);
  });

  test('foreach continue retains a failed item and does not satisfy a success gate', () async {
    final completedPath = '${h.tempDir.path}/completed';
    final readyDir = '${h.tempDir.path}/ready';
    Directory(readyDir).createSync();
    File('$readyDir/a').writeAsStringSync('ready');
    final workflow = definition(completedPath, readyDir, onError: OnErrorPolicy.continueWorkflow);
    final run = h.makeRun(workflow);
    await h.repository.insert(run);
    await h.executor.execute(
      run,
      workflow,
      WorkflowContext(
        data: {
          'items': ['a', 'b'],
        },
      ),
    );
    final completed = (await h.repository.getById(run.id))!;
    expect(completed.status, WorkflowRunStatus.completed);
    final data = completed.contextJson['data'] as Map;
    expect(data['process[1].status'], 'failed', reason: '${completed.contextJson}');
    expect(data['step.items.outcome'], 'failed');
    expect(data['after.status'], isNot('success'));
  });

  test('foreach child fail is terminal despite controller onFailure continue', () async {
    final completedPath = '${h.tempDir.path}/completed';
    final readyDir = '${h.tempDir.path}/ready';
    Directory(readyDir).createSync();
    final workflow = definition(completedPath, readyDir, onError: OnErrorPolicy.fail);
    final run = h.makeRun(workflow);
    await h.repository.insert(run);
    await h.executor.execute(
      run,
      workflow,
      WorkflowContext(
        data: {
          'items': ['a', 'b', 'c'],
        },
      ),
    );
    final failed = (await h.repository.getById(run.id))!;
    expect(failed.status, WorkflowRunStatus.failed);
    expect((failed.contextJson['data'] as Map)['process[0].status'], 'failed');
    expect(File(completedPath).readAsStringSync(), isNot(contains('c')));
  });
}
