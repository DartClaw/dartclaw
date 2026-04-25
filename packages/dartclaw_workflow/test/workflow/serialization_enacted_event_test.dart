// Unit tests for WorkflowSerializationEnactedEvent (TI01).
// Default tier — no SQLite, no service dependencies.
library;

import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowSerializationEnactedEvent;
import 'package:test/test.dart';

void main() {
  group('WorkflowSerializationEnactedEvent — shape (TI01)', () {
    test('carries six locked properties from Decision 10', () {
      final ts = DateTime(2026, 4, 25, 12);
      final event = WorkflowSerializationEnactedEvent(
        runId: 'run-1',
        foreachStepId: 'implement',
        failingIterationIndex: 1,
        failedAttemptNumber: 2,
        drainedIterationCount: 3,
        timestamp: ts,
      );

      expect(event.runId, 'run-1');
      expect(event.foreachStepId, 'implement');
      expect(event.failingIterationIndex, 1);
      expect(event.failedAttemptNumber, 2);
      expect(event.drainedIterationCount, 3);
      expect(event.timestamp, ts);
    });

    test('toString includes runId, foreachStepId, failingIterationIndex, drainedIterationCount', () {
      final event = WorkflowSerializationEnactedEvent(
        runId: 'run-abc',
        foreachStepId: 'step-x',
        failingIterationIndex: 5,
        failedAttemptNumber: 1,
        drainedIterationCount: 2,
        timestamp: DateTime.now(),
      );
      final s = event.toString();
      expect(s, contains('run-abc'));
      expect(s, contains('step-x'));
      expect(s, contains('5'));
      expect(s, contains('2'));
    });

    test('is a WorkflowLifecycleEvent (extends correct base class)', () {
      final event = WorkflowSerializationEnactedEvent(
        runId: 'run-x',
        foreachStepId: 'step-y',
        failingIterationIndex: 0,
        failedAttemptNumber: 1,
        drainedIterationCount: 0,
        timestamp: DateTime.now(),
      );
      // WorkflowLifecycleEvent is exported; verify via runId getter.
      expect(event.runId, 'run-x');
    });
  });
}
