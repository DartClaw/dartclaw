@Tags(['component'])
library;

import 'dart:io';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowStep, WorkflowTaskType;
import 'package:dartclaw_workflow/src/workflow/workflow_view_helpers.dart' show stepStatusFromTask;
import 'package:test/test.dart';

import 'workflow_service_test_support.dart';

void main() {
  final h = WorkflowServiceTestHarness();
  setUp(h.setUp);
  tearDown(h.tearDown);

  test('parallel retry retains settled success for downstream gate', () async {
    final definition = h.makeDefinition(
      steps: const [
        WorkflowStep(id: 'ok', name: 'OK', taskType: WorkflowTaskType.bash, prompts: ['printf ok'], parallel: true),
        WorkflowStep(id: 'bad', name: 'Bad', taskType: WorkflowTaskType.bash, prompts: ['printf good'], parallel: true),
        WorkflowStep(
          id: 'after',
          name: 'After',
          taskType: WorkflowTaskType.bash,
          prompts: ['printf done'],
          entryGate: 'ok.status == success',
        ),
      ],
    );
    final run = await h.insertRun(
      id: 'parallel-retry',
      definition: definition,
      status: WorkflowRunStatus.failed,
      contextJson: {
        '_parallel.current.stepIds': ['ok', 'bad'],
        '_parallel.failed.stepIds': ['bad'],
        'data': {'ok.status': 'success', 'bad.status': 'failed', 'bad.error': 'old error'},
        'variables': <String, dynamic>{},
      },
      writeContextFile: true,
    );
    final retry = await h.workflowService.retry(run.id);
    final retryData = retry.contextJson['data'] as Map;
    expect(retryData['ok.status'], 'success');
    expect(retryData.containsKey('bad.status'), isFalse);
    expect(retryData.containsKey('bad.error'), isFalse);
    await h.waitForRunStatus(run.id, WorkflowRunStatus.completed);
    final complete = (await h.repository.getById(run.id))!;
    final data = complete.contextJson['data'] as Map;
    expect(data['ok.status'], 'success');
    expect(data['bad.status'], 'success');
    expect(data['after.status'], 'success');
  });

  test('resume projects the retried bash step as running', () async {
    final marker = '${h.tempDir.path}/ready';
    final definition = h.makeDefinition(
      steps: [
        WorkflowStep(id: 'retry', name: 'Retry', taskType: WorkflowTaskType.bash, prompts: ['test -f $marker']),
      ],
    );
    final run = await h.insertRun(
      id: 'paused-error',
      definition: definition,
      status: WorkflowRunStatus.paused,
      contextJson: {
        'data': {'retry.status': 'failed', 'retry.error': 'old error'},
        'variables': <String, dynamic>{},
      },
      errorMessage: 'old error',
      writeContextFile: true,
    );
    File(marker).writeAsStringSync('ready');
    final resumed = await h.workflowService.resume(run.id);
    expect(resumed.status, WorkflowRunStatus.running);
    expect((resumed.contextJson['data'] as Map).containsKey('retry.status'), isFalse);
    expect(stepStatusFromTask(resumed, 0, null, stepId: 'retry'), 'running');
    await h.waitForRunStatus(run.id, WorkflowRunStatus.completed);
  });
}
