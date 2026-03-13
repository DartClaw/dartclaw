import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('Goal', () {
    test('creates with all fields', () {
      final createdAt = DateTime.parse('2026-03-10T10:00:00Z');
      final goal = Goal(
        id: 'goal-1',
        title: 'Ship 0.8',
        parentGoalId: 'goal-root',
        mission: 'Deliver the release safely.',
        createdAt: createdAt,
      );

      expect(goal.id, 'goal-1');
      expect(goal.title, 'Ship 0.8');
      expect(goal.parentGoalId, 'goal-root');
      expect(goal.mission, 'Deliver the release safely.');
      expect(goal.createdAt, createdAt);
    });

    test('serializes to json without null parentGoalId', () {
      final goal = Goal(
        id: 'goal-1',
        title: 'Ship 0.8',
        mission: 'Deliver the release safely.',
        createdAt: DateTime.parse('2026-03-10T10:00:00Z'),
      );

      expect(goal.toJson(), {
        'id': 'goal-1',
        'title': 'Ship 0.8',
        'mission': 'Deliver the release safely.',
        'createdAt': '2026-03-10T10:00:00.000Z',
      });
    });

    test('deserializes from json', () {
      final goal = Goal.fromJson({
        'id': 'goal-1',
        'title': 'Ship 0.8',
        'parentGoalId': 'goal-root',
        'mission': 'Deliver the release safely.',
        'createdAt': '2026-03-10T10:00:00Z',
      });

      expect(goal.id, 'goal-1');
      expect(goal.title, 'Ship 0.8');
      expect(goal.parentGoalId, 'goal-root');
      expect(goal.mission, 'Deliver the release safely.');
      expect(goal.createdAt, DateTime.parse('2026-03-10T10:00:00Z'));
    });

    test('stringifies succinctly', () {
      final goal = Goal(
        id: 'goal-1',
        title: 'Ship 0.8',
        mission: 'Deliver the release safely.',
        createdAt: DateTime.parse('2026-03-10T10:00:00Z'),
      );

      expect(goal.toString(), 'Goal(goal-1, "Ship 0.8")');
    });
  });
}
