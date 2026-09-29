import 'package:dartclaw_core/dartclaw_core.dart';

/// In-memory goal repository for tests that do not exercise SQL.
final class InMemoryGoalRepository implements GoalRepository {
  final Map<String, Goal> _goals = {};

  @override
  Future<void> insert(Goal goal) async {
    if (_goals.containsKey(goal.id)) throw ArgumentError('Goal already exists: ${goal.id}');
    _goals[goal.id] = goal;
  }

  @override
  Future<Goal?> getById(String id) async => _goals[id];

  @override
  Future<List<Goal>> list() async {
    final goals = _goals.values.toList()..sort((left, right) => right.createdAt.compareTo(left.createdAt));
    return goals;
  }

  @override
  Future<void> delete(String id) async {
    _goals.remove(id);
  }

  @override
  Future<void> dispose() async {}
}
