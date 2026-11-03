import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show WorkflowExecutionCursor, WorkflowExecutionCursorNodeType, WorkflowRun, WorkflowRunOrigin;
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
        executionCursor: WorkflowExecutionCursor.foreach(
          stepId: 'foreach-step',
          stepIndex: 4,
          totalItems: 3,
          completedIndices: const [0, 2],
          failedIndices: const [2],
          completedSubStepIdsByIndex: const {
            1: ['implement', 'quick-review'],
          },
          resultSlots: const [
            'done',
            null,
            {'error': true, 'message': 'failed'},
          ],
        ),
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
      expect(restored.executionCursor?.nodeType, WorkflowExecutionCursorNodeType.foreach);
      expect(restored.executionCursor?.nodeId, 'foreach-step');
      expect(restored.executionCursor?.completedIndices, [0, 2]);
      expect(restored.executionCursor?.failedIndices, [2]);
      expect(restored.executionCursor?.completedSubStepIdsByIndex, {
        1: ['implement', 'quick-review'],
      });
    });

    test('round-trips with minimal fields (defaults)', () {
      final run = buildRun();
      final restored = WorkflowRun.fromJson(run.toJson());
      expect(restored.totalTokens, 0);
      expect(restored.currentStepIndex, 0);
      expect(restored.contextJson, isEmpty);
      expect(restored.variablesJson, isEmpty);
      expect(restored.definitionJson, isEmpty);
      expect(restored.executionCursor, isNull);
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
  group('WorkflowRun origin', () {
    const chatOrigin = WorkflowRunOrigin(
      surface: 'googlechat',
      channelType: 'googlechat',
      recipientId: 'spaces/AAA',
      threadId: 'spaces/AAA/threads/T1',
      sessionKey: 'agent:main:group:googlechat:spaces%2FAAA',
      senderId: 'users/42',
    );

    test('round-trips every field through the run JSON', () {
      final run = WorkflowRun(
        id: 'run-1',
        definitionName: 'wf',
        startedAt: DateTime.parse('2026-01-01T00:00:00Z'),
        updatedAt: DateTime.parse('2026-01-01T00:00:00Z'),
        origin: chatOrigin,
      );

      final restored = WorkflowRun.fromJson(run.toJson());

      expect(restored.origin, chatOrigin);
      expect(run.toJson()['origin'], {
        'surface': 'googlechat',
        'channelType': 'googlechat',
        'recipientId': 'spaces/AAA',
        'threadId': 'spaces/AAA/threads/T1',
        'sessionKey': 'agent:main:group:googlechat:spaces%2FAAA',
        'senderId': 'users/42',
      });
    });

    test('a missing or null origin reads as unknown', () {
      final json = buildRun().toJson()..remove('origin');
      expect(WorkflowRun.fromJson(json).origin, WorkflowRunOrigin.unknown);
      expect(WorkflowRun.fromJson({...json, 'origin': null}).origin.surface, 'unknown');
    });

    test('a malformed non-null origin fails decoding instead of reading as unknown', () {
      final json = buildRun().toJson();
      expect(() => WorkflowRun.fromJson({...json, 'origin': 'slack'}), throwsFormatException);
      expect(() => WorkflowRun.fromJson({...json, 'origin': <String, Object?>{}}), throwsFormatException);
      expect(
        () => WorkflowRun.fromJson({
          ...json,
          'origin': {'surface': 'web', 'threadId': 7},
        }),
        throwsFormatException,
      );
    });

    test('an unlisted surface fails decoding while every channel type name and fixed surface decodes', () {
      final json = buildRun().toJson();
      expect(
        () => WorkflowRun.fromJson({
          ...json,
          'origin': {'surface': 'carrier-pigeon'},
        }),
        throwsFormatException,
      );
      for (final surface in [
        ...ChannelType.values.map((type) => type.name),
        'cron',
        'github',
        'cli',
        'api',
        'unknown',
      ]) {
        expect(
          WorkflowRun.fromJson({
            ...json,
            'origin': {'surface': surface},
          }).origin.surface,
          surface,
        );
      }
    });

    test('copyWith keeps the origin', () {
      final run = buildRun().copyWith(status: WorkflowRunStatus.running);
      expect(run.origin, WorkflowRunOrigin.unknown);

      final chatRun = WorkflowRun(
        id: 'run-2',
        definitionName: 'wf',
        startedAt: DateTime.parse('2026-01-01T00:00:00Z'),
        updatedAt: DateTime.parse('2026-01-01T00:00:00Z'),
        origin: chatOrigin,
      );
      expect(chatRun.copyWith(status: WorkflowRunStatus.paused, errorMessage: 'x').origin, chatOrigin);
    });
  });
}
