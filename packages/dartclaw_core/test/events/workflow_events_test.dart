import 'package:dartclaw_config/dartclaw_config.dart' show WorkflowRunStatus;
import 'package:dartclaw_core/dartclaw_core.dart'
    show
        LoopIterationCompletedEvent,
        ParallelGroupCompletedEvent,
        WorkflowRunStatusChangedEvent,
        WorkflowStepCompletedEvent;
import 'package:test/test.dart';

void main() {
  group('WorkflowRunStatusChangedEvent', () {
    test('constructs with required fields', () {
      final event = WorkflowRunStatusChangedEvent(
        runId: 'run-1',
        definitionName: 'my-workflow',
        oldStatus: WorkflowRunStatus.running,
        newStatus: WorkflowRunStatus.completed,
        timestamp: DateTime(2026, 4, 1),
      );

      expect(event.runId, equals('run-1'));
      expect(event.definitionName, equals('my-workflow'));
      expect(event.oldStatus, equals(WorkflowRunStatus.running));
      expect(event.newStatus, equals(WorkflowRunStatus.completed));
      expect(event.errorMessage, isNull);
    });

    test('constructs with optional errorMessage', () {
      final event = WorkflowRunStatusChangedEvent(
        runId: 'run-2',
        definitionName: 'workflow',
        oldStatus: WorkflowRunStatus.running,
        newStatus: WorkflowRunStatus.paused,
        errorMessage: 'Step failed: step1',
        timestamp: DateTime.now(),
      );

      expect(event.errorMessage, equals('Step failed: step1'));
    });
  });

  group('WorkflowStepCompletedEvent', () {
    test('constructs with required fields', () {
      final event = WorkflowStepCompletedEvent(
        runId: 'run-1',
        stepId: 'step1',
        stepName: 'Research Step',
        stepIndex: 0,
        totalSteps: 3,
        taskId: 'task-abc',
        displayScope: 'S01',
        success: true,
        tokenCount: 12500,
        timestamp: DateTime(2026, 4, 1),
      );

      expect(event.runId, equals('run-1'));
      expect(event.stepId, equals('step1'));
      expect(event.stepName, equals('Research Step'));
      expect(event.stepIndex, equals(0));
      expect(event.totalSteps, equals(3));
      expect(event.taskId, equals('task-abc'));
      expect(event.displayScope, equals('S01'));
      expect(event.success, isTrue);
      expect(event.tokenCount, equals(12500));
    });
  });

  group('ParallelGroupCompletedEvent', () {
    test('constructs with required fields', () {
      final event = ParallelGroupCompletedEvent(
        runId: 'run-1',
        stepIds: ['step1', 'step2', 'step3'],
        successCount: 2,
        failureCount: 1,
        totalTokens: 5000,
        timestamp: DateTime(2026, 4, 1),
      );

      expect(event.runId, equals('run-1'));
      expect(event.stepIds, equals(['step1', 'step2', 'step3']));
      expect(event.successCount, equals(2));
      expect(event.failureCount, equals(1));
      expect(event.totalTokens, equals(5000));
    });
  });

  group('LoopIterationCompletedEvent', () {
    test('constructs with required fields', () {
      final event = LoopIterationCompletedEvent(
        runId: 'run-1',
        loopId: 'review-loop',
        iteration: 2,
        maxIterations: 5,
        gateResult: false,
        timestamp: DateTime(2026, 4, 1),
      );

      expect(event.runId, equals('run-1'));
      expect(event.loopId, equals('review-loop'));
      expect(event.iteration, equals(2));
      expect(event.maxIterations, equals(5));
      expect(event.gateResult, isFalse);
    });
  });
}
