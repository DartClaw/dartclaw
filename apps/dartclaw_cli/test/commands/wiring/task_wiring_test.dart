import 'package:dartclaw_cli/src/commands/wiring/task_wiring.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

void main() {
  group('buildAutoAcceptCallback', () {
    test('returns null unless completion action is accept', () {
      expect(
        buildAutoAcceptCallback(completionAction: 'review', reviewTask: (_) async => throw UnimplementedError()),
        isNull,
      );
    });

    test('throws when review returns a merge conflict', () async {
      final callback = buildAutoAcceptCallback(
        completionAction: 'accept',
        reviewTask: (_) async => const ReviewMergeConflict(
          taskId: 'task-1',
          taskTitle: 'Fix login',
          conflictingFiles: ['lib/main.dart'],
          details: 'Automatic merge failed',
        ),
      );

      expect(callback, isNotNull);
      await expectLater(
        callback!('task-1'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            allOf(contains('task-1'), contains('merge conflict'), contains('lib/main.dart')),
          ),
        ),
      );
    });

    test('throws when review returns not found', () async {
      final callback = buildAutoAcceptCallback(
        completionAction: 'accept',
        reviewTask: (_) async => const ReviewNotFound('task-1'),
      );

      await expectLater(
        callback!('task-1'),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('no task found'))),
      );
    });

    test('throws when review returns invalid transition', () async {
      final callback = buildAutoAcceptCallback(
        completionAction: 'accept',
        reviewTask: (_) async => const ReviewInvalidTransition(
          taskId: 'task-1',
          oldStatus: TaskStatus.failed,
          targetStatus: TaskStatus.accepted,
          currentStatus: TaskStatus.failed,
        ),
      );

      await expectLater(
        callback!('task-1'),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('not in review'))),
      );
    });

    test('throws when review returns invalid request', () async {
      final callback = buildAutoAcceptCallback(
        completionAction: 'accept',
        reviewTask: (_) async => const ReviewInvalidRequest('unknown action'),
      );

      await expectLater(
        callback!('task-1'),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('unknown action'))),
      );
    });

    test('throws when review returns action failed', () async {
      final callback = buildAutoAcceptCallback(
        completionAction: 'accept',
        reviewTask: (_) async => const ReviewActionFailed('git push rejected'),
      );

      await expectLater(
        callback!('task-1'),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('git push rejected'))),
      );
    });

    test('allows successful reviews to complete', () async {
      final callback = buildAutoAcceptCallback(
        completionAction: 'accept',
        reviewTask: (_) async => ReviewSuccess(
          Task(
            id: 'task-1',
            title: 'Fix login',
            description: 'Fix login',
            type: TaskType.coding,
            createdAt: DateTime.utc(2026, 3, 25),
          ),
        ),
      );

      expect(callback, isNotNull);
      await expectLater(callback!('task-1'), completes);
    });
  });
}
