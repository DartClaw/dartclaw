import 'package:dartclaw_core/dartclaw_core.dart'
    show
        MapIterationCompletedEvent,
        MapStepCompletedEvent,
        StepSkippedEvent,
        WorkflowApprovalRequestedEvent,
        WorkflowApprovalResolvedEvent,
        WorkflowLifecycleEvent,
        WorkflowSerializationEnactedEvent,
        WorkflowStepCompletedEvent;
import 'package:test/test.dart';

void main() {
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
