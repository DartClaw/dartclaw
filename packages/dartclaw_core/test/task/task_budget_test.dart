import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  Task baseTask({int? maxTokens}) => Task(
    id: 'task-1',
    title: 'Budget test task',
    description: 'Test',
    type: TaskType.custom,
    createdAt: DateTime.parse('2026-04-02T10:00:00Z'),
    maxTokens: maxTokens,
  );

  Goal baseGoal({int? maxTokens}) => Goal(
    id: 'goal-1',
    title: 'Test goal',
    mission: 'Budget test mission',
    createdAt: DateTime.parse('2026-04-02T10:00:00Z'),
    maxTokens: maxTokens,
  );

  group('Task.maxTokens', () {
    test('defaults to null when not set', () {
      final task = baseTask();
      expect(task.maxTokens, isNull);
    });

    test('is set when provided', () {
      final task = baseTask(maxTokens: 50000);
      expect(task.maxTokens, 50000);
    });

    test('toJson omits maxTokens when null', () {
      final json = baseTask().toJson();
      expect(json.containsKey('maxTokens'), isFalse);
    });

    test('toJson includes maxTokens when set', () {
      final json = baseTask(maxTokens: 50000).toJson();
      expect(json['maxTokens'], 50000);
    });

    test('fromJson round-trips maxTokens', () {
      final task = baseTask(maxTokens: 100000);
      final restored = Task.fromJson(task.toJson());
      expect(restored.maxTokens, 100000);
    });

    test('fromJson defaults maxTokens to null when absent', () {
      final json = baseTask().toJson();
      expect(json.containsKey('maxTokens'), isFalse);
      final restored = Task.fromJson(json);
      expect(restored.maxTokens, isNull);
    });

    test('copyWith sets maxTokens', () {
      final task = baseTask();
      final updated = task.copyWith(maxTokens: 75000);
      expect(updated.maxTokens, 75000);
    });

    test('copyWith clears maxTokens with null sentinel', () {
      final task = baseTask(maxTokens: 50000);
      final updated = task.copyWith(maxTokens: null);
      expect(updated.maxTokens, isNull);
    });

    test('copyWith without maxTokens preserves existing value', () {
      final task = baseTask(maxTokens: 50000);
      final updated = task.copyWith(title: 'changed');
      expect(updated.maxTokens, 50000);
    });
  });

  group('Goal.maxTokens', () {
    test('defaults to null when not set', () {
      final goal = baseGoal();
      expect(goal.maxTokens, isNull);
    });

    test('is set when provided', () {
      final goal = baseGoal(maxTokens: 75000);
      expect(goal.maxTokens, 75000);
    });

    test('toJson omits maxTokens when null', () {
      final json = baseGoal().toJson();
      expect(json.containsKey('maxTokens'), isFalse);
    });

    test('toJson includes maxTokens when set', () {
      final json = baseGoal(maxTokens: 75000).toJson();
      expect(json['maxTokens'], 75000);
    });

    test('fromJson round-trips maxTokens', () {
      final goal = baseGoal(maxTokens: 75000);
      final restored = Goal.fromJson(goal.toJson());
      expect(restored.maxTokens, 75000);
    });

    test('fromJson defaults maxTokens to null when absent', () {
      final json = baseGoal().toJson();
      expect(json.containsKey('maxTokens'), isFalse);
      final restored = Goal.fromJson(json);
      expect(restored.maxTokens, isNull);
    });
  });

  group('TaskBudgetConfig', () {
    test('defaults warningThreshold to 0.8', () {
      const config = TaskBudgetConfig.defaults();
      expect(config.warningThreshold, 0.8);
    });

    test('defaults defaultMaxTokens to null', () {
      const config = TaskBudgetConfig.defaults();
      expect(config.defaultMaxTokens, isNull);
    });

    test('hasDefaults is false when defaultMaxTokens is null', () {
      const config = TaskBudgetConfig.defaults();
      expect(config.hasDefaults, isFalse);
    });

    test('hasDefaults is true when defaultMaxTokens is set', () {
      const config = TaskBudgetConfig(defaultMaxTokens: 100000);
      expect(config.hasDefaults, isTrue);
    });

    test('accepts custom warningThreshold', () {
      const config = TaskBudgetConfig(warningThreshold: 0.9);
      expect(config.warningThreshold, 0.9);
    });
  });

  group('BudgetWarningEvent', () {
    test('constructs and stores fields', () {
      final ts = DateTime.parse('2026-04-02T10:00:00Z');
      final event = BudgetWarningEvent(
        taskId: 'task-1',
        consumedPercent: 0.85,
        consumed: 8500,
        limit: 10000,
        timestamp: ts,
      );
      expect(event.taskId, 'task-1');
      expect(event.consumedPercent, 0.85);
      expect(event.consumed, 8500);
      expect(event.limit, 10000);
      expect(event.timestamp, ts);
    });

    test('toString includes percentage', () {
      final event = BudgetWarningEvent(
        taskId: 'task-1',
        consumedPercent: 0.85,
        consumed: 8500,
        limit: 10000,
        timestamp: DateTime.now(),
      );
      expect(event.toString(), contains('85%'));
      expect(event.toString(), contains('8500/10000'));
    });
  });
}
