import 'package:dartclaw_config/dartclaw_config.dart' show WorkflowRunStatus;
import 'package:dartclaw_core/dartclaw_core.dart'
    show
        LoopIterationCompletedEvent,
        MapIterationCompletedEvent,
        MapStepCompletedEvent,
        ParallelGroupCompletedEvent,
        StepSkippedEvent,
        WorkflowApprovalRequestedEvent,
        WorkflowApprovalResolvedEvent,
        WorkflowLifecycleEvent,
        WorkflowRunStatusChangedEvent,
        WorkflowSerializationEnactedEvent,
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
      expect(event.outcome, isNull);
      expect(event.reason, isNull);
      expect(event.tokenCount, equals(12500));
    });

    test('carries outcome and reason for a failed step', () {
      final event = WorkflowStepCompletedEvent(
        runId: 'run-1',
        stepId: 'implement',
        stepName: 'Implement',
        stepIndex: 2,
        totalSteps: 6,
        taskId: 'task-1',
        success: false,
        outcome: 'failed',
        reason: 'Context window exceeded',
        tokenCount: 0,
        timestamp: DateTime(2026, 4, 1),
      );

      expect(event.success, isFalse);
      expect(event.outcome, equals('failed'));
      expect(event.reason, equals('Context window exceeded'));
    });
  });

  group('MapIterationCompletedEvent', () {
    test('carries blocked outcome and reason for a needsInput iteration', () {
      final event = MapIterationCompletedEvent(
        runId: 'run-1',
        stepId: 'story-pipeline',
        iterationIndex: 0,
        totalIterations: 2,
        itemId: 'S01',
        taskId: 'task-1',
        success: false,
        outcome: 'needsInput',
        reason: 'Docker Desktop must be started',
        tokenCount: 0,
        timestamp: DateTime(2026, 4, 1),
      );

      expect(event.success, isFalse);
      expect(event.outcome, equals('needsInput'));
      expect(event.reason, equals('Docker Desktop must be started'));
    });
  });

  group('MapStepCompletedEvent', () {
    test('defaults blockedCount to zero and accepts an explicit count', () {
      final withDefault = MapStepCompletedEvent(
        runId: 'run-1',
        stepId: 'fe',
        stepName: 'FE',
        totalIterations: 3,
        successCount: 2,
        failureCount: 1,
        cancelledCount: 0,
        totalTokens: 100,
        timestamp: DateTime(2026, 4, 1),
      );
      expect(withDefault.blockedCount, equals(0));

      final withBlocked = MapStepCompletedEvent(
        runId: 'run-1',
        stepId: 'fe',
        stepName: 'FE',
        totalIterations: 3,
        successCount: 1,
        failureCount: 0,
        cancelledCount: 0,
        blockedCount: 2,
        totalTokens: 100,
        timestamp: DateTime(2026, 4, 1),
      );
      expect(withBlocked.blockedCount, equals(2));
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

  group('WorkflowLifecycleEvent JSON', () {
    test('serializes step completion with optional fields omitted when null', () {
      final event = WorkflowStepCompletedEvent(
        runId: 'run-1',
        stepId: 'implement',
        stepName: 'Implement',
        stepIndex: 2,
        totalSteps: 4,
        taskId: 'task-1',
        success: true,
        tokenCount: 25,
        timestamp: DateTime.utc(2026, 4),
      );

      final json = event.toJson();

      expect(json, {
        'type': 'workflow_step_completed',
        'runId': 'run-1',
        'stepId': 'implement',
        'stepIndex': 2,
        'totalSteps': 4,
        'taskId': 'task-1',
        'success': true,
        'tokenCount': 25,
      });
      expect(WorkflowLifecycleEvent.fromJson(json).toJson(), json);
    });

    test('serializes non-success step outcomes without treating needsInput as failure', () {
      final event = WorkflowStepCompletedEvent(
        runId: 'run-1',
        stepId: 'implement',
        stepName: 'Implement',
        stepIndex: 2,
        totalSteps: 4,
        taskId: 'task-1',
        displayScope: 'S04',
        success: false,
        outcome: 'needsInput',
        reason: 'operator decision required',
        tokenCount: 0,
        timestamp: DateTime.utc(2026, 4),
      );

      final json = event.toJson();

      expect(json['outcome'], 'needsInput');
      expect(json['reason'], 'operator decision required');
      expect(json['displayScope'], 'S04');
      expect(WorkflowLifecycleEvent.fromJson(json).toJson(), json);
    });

    test('serializes map iteration display scope from item id', () {
      final event = MapIterationCompletedEvent(
        runId: 'run-1',
        stepId: 'story-pipeline',
        iterationIndex: 1,
        totalIterations: 2,
        itemId: 'S02',
        taskId: '',
        success: false,
        outcome: 'cancelled',
        reason: 'run teardown',
        tokenCount: 0,
        timestamp: DateTime.utc(2026, 4),
      );

      final json = event.toJson();

      expect(json['itemId'], 'S02');
      expect(json['displayScope'], 'S02');
      expect(json['outcome'], 'cancelled');
      expect(WorkflowLifecycleEvent.fromJson(json).toJson(), json);
    });

    test('serializes approval, skip, and serialization lifecycle events', () {
      final timestamp = DateTime.utc(2026, 4, 1, 12);
      final events = <WorkflowLifecycleEvent>[
        WorkflowApprovalRequestedEvent(
          runId: 'run-1',
          stepId: 'approve',
          message: 'Continue?',
          timeoutSeconds: 60,
          timestamp: timestamp,
        ),
        WorkflowApprovalResolvedEvent(runId: 'run-1', stepId: 'approve', approved: false, timestamp: timestamp),
        StepSkippedEvent(runId: 'run-1', stepId: 'optional', reason: 'entryGate false', timestamp: timestamp),
        WorkflowSerializationEnactedEvent(
          runId: 'run-1',
          foreachStepId: 'stories',
          failingIterationIndex: 1,
          failedAttemptNumber: 2,
          timestamp: timestamp,
        ),
      ];

      for (final event in events) {
        final json = event.toJson();
        expect(WorkflowLifecycleEvent.fromJson(json).toJson(), json);
      }
    });
  });
}
