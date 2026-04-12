import 'package:dartclaw_models/dartclaw_models.dart';
import 'package:test/test.dart';

WorkflowRun buildRun({
  WorkflowRunStatus status = WorkflowRunStatus.pending,
  DateTime? completedAt,
  String? errorMessage,
}) {
  final now = DateTime.parse('2026-01-01T00:00:00Z');
  return WorkflowRun(
    id: 'run-1',
    definitionName: 'my-workflow',
    status: status,
    startedAt: now,
    updatedAt: now,
    completedAt: completedAt,
    errorMessage: errorMessage,
  );
}

void main() {
  group('WorkflowRunStatus', () {
    test('terminal returns true for completed', () {
      expect(WorkflowRunStatus.completed.terminal, true);
    });

    test('terminal returns true for failed', () {
      expect(WorkflowRunStatus.failed.terminal, true);
    });

    test('terminal returns true for cancelled', () {
      expect(WorkflowRunStatus.cancelled.terminal, true);
    });

    test('terminal returns false for pending', () {
      expect(WorkflowRunStatus.pending.terminal, false);
    });

    test('terminal returns false for running', () {
      expect(WorkflowRunStatus.running.terminal, false);
    });

    test('terminal returns false for paused', () {
      expect(WorkflowRunStatus.paused.terminal, false);
    });
  });

  group('WorkflowRun', () {
    test('round-trips via toJson/fromJson with all fields', () {
      final now = DateTime.parse('2026-01-01T10:00:00Z');
      final completedAt = DateTime.parse('2026-01-01T11:00:00Z');
      final run = WorkflowRun(
        id: 'run-42',
        definitionName: 'pipeline',
        status: WorkflowRunStatus.completed,
        contextJson: {'key': 'value'},
        variablesJson: {'VAR': 'hello'},
        startedAt: now,
        updatedAt: now,
        completedAt: completedAt,
        errorMessage: null,
        totalTokens: 1234,
        currentStepIndex: 3,
        definitionJson: {'name': 'pipeline', 'steps': []},
        currentLoopId: 'loop-1',
        currentLoopIteration: 2,
      );
      final json = run.toJson();
      final restored = WorkflowRun.fromJson(json);

      expect(restored.id, 'run-42');
      expect(restored.definitionName, 'pipeline');
      expect(restored.status, WorkflowRunStatus.completed);
      expect(restored.contextJson['key'], 'value');
      expect(restored.variablesJson['VAR'], 'hello');
      expect(restored.startedAt, now);
      expect(restored.updatedAt, now);
      expect(restored.completedAt, completedAt);
      expect(restored.errorMessage, isNull);
      expect(restored.totalTokens, 1234);
      expect(restored.currentStepIndex, 3);
      expect(restored.definitionJson['name'], 'pipeline');
      expect(restored.currentLoopId, 'loop-1');
      expect(restored.currentLoopIteration, 2);
    });

    test('round-trips with minimal fields (defaults)', () {
      final run = buildRun();
      final restored = WorkflowRun.fromJson(run.toJson());
      expect(restored.totalTokens, 0);
      expect(restored.currentStepIndex, 0);
      expect(restored.contextJson, isEmpty);
      expect(restored.variablesJson, isEmpty);
      expect(restored.definitionJson, isEmpty);
      expect(restored.currentLoopId, isNull);
      expect(restored.currentLoopIteration, isNull);
    });

    test('copyWith preserves unchanged fields', () {
      final run = buildRun();
      final copy = run.copyWith(status: WorkflowRunStatus.running);
      expect(copy.id, run.id);
      expect(copy.status, WorkflowRunStatus.running);
      expect(copy.definitionName, run.definitionName);
    });

    test('copyWith can set completedAt', () {
      final run = buildRun();
      final completedAt = DateTime.parse('2026-01-01T12:00:00Z');
      final copy = run.copyWith(completedAt: completedAt);
      expect(copy.completedAt, completedAt);
    });

    test('copyWith can clear completedAt to null', () {
      final run = buildRun(status: WorkflowRunStatus.completed, completedAt: DateTime.parse('2026-01-01T12:00:00Z'));
      final copy = run.copyWith(completedAt: null);
      expect(copy.completedAt, isNull);
    });

    test('copyWith can set errorMessage', () {
      final run = buildRun();
      final copy = run.copyWith(errorMessage: 'oops');
      expect(copy.errorMessage, 'oops');
    });

    test('copyWith can clear errorMessage to null', () {
      final run = buildRun(errorMessage: 'old error');
      final copy = run.copyWith(errorMessage: null);
      expect(copy.errorMessage, isNull);
    });
  });
}
