import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/workflow/workflow_view_helpers.dart';
import 'package:test/test.dart';

WorkflowRun _makeRun({
  WorkflowRunStatus status = WorkflowRunStatus.running,
  int currentStepIndex = 0,
  Map<String, dynamic>? contextJson,
}) {
  final now = DateTime.parse('2026-03-24T10:00:00Z');
  return WorkflowRun(
    id: 'run-001',
    definitionName: 'test-workflow',
    status: status,
    startedAt: now,
    updatedAt: now,
    variablesJson: const {},
    definitionJson: const {},
    currentStepIndex: currentStepIndex,
    contextJson: contextJson ?? const {},
  );
}

Task _makeTask({
  String id = 'task-001',
  TaskStatus status = TaskStatus.running,
  int? stepIndex = 0,
  String? workflowRunId = 'run-001',
}) {
  return Task(
    id: id,
    title: 'Test',
    description: 'desc',
    type: TaskType.research,
    status: status,
    createdAt: DateTime.parse('2026-03-24T10:00:00Z'),
    stepIndex: stepIndex,
    workflowRunId: workflowRunId,
  );
}

void main() {
  group('stepStatusFromTask', () {
    final run = _makeRun(currentStepIndex: 1);

    test('null task at current step index returns running when workflow is running', () {
      expect(stepStatusFromTask(run, 1, null), 'running');
    });

    test('null task at non-current step returns pending', () {
      expect(stepStatusFromTask(run, 0, null), 'pending');
      expect(stepStatusFromTask(run, 2, null), 'pending');
    });

    test('null task when workflow is not running returns pending', () {
      final pausedRun = _makeRun(status: WorkflowRunStatus.paused, currentStepIndex: 1);
      expect(stepStatusFromTask(pausedRun, 1, null), 'pending');
    });

    test('draft/queued task -> queued', () {
      expect(stepStatusFromTask(run, 0, _makeTask(status: TaskStatus.draft)), 'queued');
      expect(stepStatusFromTask(run, 0, _makeTask(status: TaskStatus.queued)), 'queued');
    });

    test('running task -> running', () {
      expect(stepStatusFromTask(run, 0, _makeTask(status: TaskStatus.running)), 'running');
    });

    test('review task -> review', () {
      expect(stepStatusFromTask(run, 0, _makeTask(status: TaskStatus.review)), 'review');
    });

    test('accepted task -> completed', () {
      expect(stepStatusFromTask(run, 0, _makeTask(status: TaskStatus.accepted)), 'completed');
    });

    test('failed task -> failed', () {
      expect(stepStatusFromTask(run, 0, _makeTask(status: TaskStatus.failed)), 'failed');
    });

    test('cancelled task -> cancelled', () {
      expect(stepStatusFromTask(run, 0, _makeTask(status: TaskStatus.cancelled)), 'cancelled');
    });

    test('rejected task -> failed', () {
      expect(stepStatusFromTask(run, 0, _makeTask(status: TaskStatus.rejected)), 'failed');
    });

    test('interrupted task -> pending (fallback)', () {
      expect(stepStatusFromTask(run, 0, _makeTask(status: TaskStatus.interrupted)), 'pending');
    });
  });

  group('buildLoopInfo', () {
    test('empty loops returns empty list', () {
      final definition = WorkflowDefinition(
        name: 'test',
        description: '',
        steps: const [],
        variables: const {},
      );
      expect(buildLoopInfo(definition, {}), isEmpty);
    });

    test('returns loop membership with current iteration from context', () {
      final definition = WorkflowDefinition(
        name: 'test',
        description: '',
        steps: const [],
        variables: const {},
        loops: [
          const WorkflowLoop(
            id: 'review-loop',
            steps: ['implement', 'review'],
            maxIterations: 3,
            exitGate: 'approved == true',
          ),
        ],
      );
      final contextJson = {'loop.review-loop.iteration': 2};
      final result = buildLoopInfo(definition, contextJson);

      expect(result, hasLength(1));
      expect(result.first['loopId'], 'review-loop');
      expect(result.first['stepIds'], ['implement', 'review']);
      expect(result.first['maxIterations'], 3);
      expect(result.first['currentIteration'], 2);
    });

    test('defaults to 0 iterations when context key absent', () {
      final definition = WorkflowDefinition(
        name: 'test',
        description: '',
        steps: const [],
        variables: const {},
        loops: [
          const WorkflowLoop(
            id: 'loop-a',
            steps: ['step1'],
            maxIterations: 5,
            exitGate: 'done',
          ),
        ],
      );
      final result = buildLoopInfo(definition, {});
      expect(result.first['currentIteration'], 0);
    });
  });

  group('formatContextForDisplay', () {
    test('filters internal keys starting with _ or loop.', () {
      final result = formatContextForDisplay({
        '_internal': 'hidden',
        'loop.id.iteration': 'hidden',
        'public_key': 'visible',
      });
      expect(result, hasLength(1));
      expect(result.first['key'], 'public_key');
    });

    test('truncates long values at 500 chars', () {
      final longValue = 'x' * 600;
      final result = formatContextForDisplay({'key': longValue});
      expect(result.first['value'], endsWith('...'));
      expect((result.first['value'] as String).length, lessThanOrEqualTo(503));
    });

    test('marks isLong for values over 200 chars', () {
      final result200 = formatContextForDisplay({'k': 'a' * 201});
      final result100 = formatContextForDisplay({'k': 'a' * 100});
      expect(result200.first['isLong'], true);
      expect(result100.first['isLong'], false);
    });

    test('empty context returns empty list', () {
      expect(formatContextForDisplay({}), isEmpty);
    });
  });
}
