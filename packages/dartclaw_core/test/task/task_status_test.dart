import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('TaskStatus', () {
    group('terminal', () {
      test('returns true for terminal states', () {
        expect(TaskStatus.accepted.terminal, isTrue);
        expect(TaskStatus.rejected.terminal, isTrue);
        expect(TaskStatus.cancelled.terminal, isTrue);
        expect(TaskStatus.failed.terminal, isTrue);
      });

      test('returns false for non-terminal states', () {
        expect(TaskStatus.draft.terminal, isFalse);
        expect(TaskStatus.queued.terminal, isFalse);
        expect(TaskStatus.running.terminal, isFalse);
        expect(TaskStatus.interrupted.terminal, isFalse);
        expect(TaskStatus.review.terminal, isFalse);
      });
    });

    group('canTransitionTo', () {
      test('accepts all valid transitions', () {
        final expected = <TaskStatus, Set<TaskStatus>>{
          TaskStatus.draft: {TaskStatus.queued, TaskStatus.cancelled},
          TaskStatus.queued: {TaskStatus.running, TaskStatus.cancelled, TaskStatus.failed},
          TaskStatus.running: {TaskStatus.review, TaskStatus.interrupted, TaskStatus.failed, TaskStatus.cancelled},
          TaskStatus.interrupted: {TaskStatus.queued, TaskStatus.cancelled},
          TaskStatus.review: {
            TaskStatus.accepted,
            TaskStatus.rejected,
            TaskStatus.queued,
            TaskStatus.running,
            TaskStatus.failed,
          },
        };

        for (final from in expected.keys) {
          for (final to in expected[from]!) {
            expect(from.canTransitionTo(to), isTrue, reason: '$from should transition to $to');
          }
        }
      });

      test('rejects invalid transitions', () {
        expect(TaskStatus.draft.canTransitionTo(TaskStatus.running), isFalse);
        expect(TaskStatus.draft.canTransitionTo(TaskStatus.review), isFalse);
        expect(TaskStatus.queued.canTransitionTo(TaskStatus.review), isFalse);
        expect(TaskStatus.queued.canTransitionTo(TaskStatus.accepted), isFalse);
        expect(TaskStatus.running.canTransitionTo(TaskStatus.queued), isFalse);
        expect(TaskStatus.running.canTransitionTo(TaskStatus.accepted), isFalse);
        expect(TaskStatus.review.canTransitionTo(TaskStatus.interrupted), isFalse);
      });

      test('has no outbound transitions from accepted, rejected, cancelled', () {
        for (final terminal in const [
          TaskStatus.accepted,
          TaskStatus.rejected,
          TaskStatus.cancelled,
        ]) {
          for (final target in TaskStatus.values) {
            expect(terminal.canTransitionTo(target), isFalse, reason: '$terminal should not transition to $target');
          }
        }
      });

      test('failed can only transition to queued (retry path)', () {
        expect(TaskStatus.failed.canTransitionTo(TaskStatus.queued), isTrue);
        for (final target in TaskStatus.values.where((s) => s != TaskStatus.queued)) {
          expect(TaskStatus.failed.canTransitionTo(target), isFalse,
              reason: 'failed should not transition to $target');
        }
      });

      test('matches expected matrix exactly', () {
        final expected = <TaskStatus, Set<TaskStatus>>{
          TaskStatus.draft: {TaskStatus.queued, TaskStatus.cancelled},
          TaskStatus.queued: {TaskStatus.running, TaskStatus.cancelled, TaskStatus.failed},
          TaskStatus.running: {TaskStatus.review, TaskStatus.interrupted, TaskStatus.failed, TaskStatus.cancelled},
          TaskStatus.interrupted: {TaskStatus.queued, TaskStatus.cancelled},
          TaskStatus.review: {
            TaskStatus.accepted,
            TaskStatus.rejected,
            TaskStatus.queued,
            TaskStatus.running,
            TaskStatus.failed,
          },
          TaskStatus.accepted: const {},
          TaskStatus.rejected: const {},
          TaskStatus.cancelled: const {},
          TaskStatus.failed: {TaskStatus.queued}, // retry path
        };

        for (final from in TaskStatus.values) {
          for (final to in TaskStatus.values) {
            expect(
              from.canTransitionTo(to),
              expected[from]!.contains(to),
              reason: 'Unexpected transition result for $from -> $to',
            );
          }
        }
      });
    });

    group('exhaustiveness', () {
      test('every non-terminal state has at least one outbound transition', () {
        for (final status in TaskStatus.values.where((status) => !status.terminal)) {
          expect(TaskStatus.validTransitions[status], isNotNull);
          expect(TaskStatus.validTransitions[status], isNotEmpty);
        }
      });

      test('validTransitions contains non-terminal states plus failed (retry path)', () {
        expect(TaskStatus.validTransitions.keys, {
          TaskStatus.draft,
          TaskStatus.queued,
          TaskStatus.running,
          TaskStatus.interrupted,
          TaskStatus.review,
          TaskStatus.failed, // retry path: failed → queued
        });
      });
    });
  });
}
