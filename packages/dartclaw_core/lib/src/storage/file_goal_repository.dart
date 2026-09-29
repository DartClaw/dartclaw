import '../task/goal.dart';
import '../task/goal_repository.dart';
import 'file_execution_store.dart';

/// Goal persistence over a standalone execution checkpoint.
final class FileGoalRepository implements GoalRepository {
  /// Binds goals to [store].
  new(this.store);

  /// Shared checkpoint authority.
  final FileExecutionStore store;

  @override
  Future<void> insert(Goal goal) => store.update((state) {
    final goals = state['goals'] as Map<String, dynamic>;
    if (goals.containsKey(goal.id)) throw StateError('Goal already exists: ${goal.id}');
    goals[goal.id] = goal.toJson();
  });

  @override
  Future<Goal?> getById(String id) => store.read((state) {
    final row = (state['goals'] as Map<String, dynamic>)[id];
    return row == null ? null : Goal.fromJson(Map<String, dynamic>.from(row as Map));
  });

  @override
  Future<List<Goal>> list() => store.read((state) {
    final goals = (state['goals'] as Map<String, dynamic>).values
        .map((row) => Goal.fromJson(Map<String, dynamic>.from(row as Map)))
        .toList();
    goals.sort((a, b) {
      final byTime = b.createdAt.compareTo(a.createdAt);
      return byTime == 0 ? b.id.compareTo(a.id) : byTime;
    });
    return goals;
  });

  @override
  Future<void> delete(String id) => store.update((state) {
    (state['goals'] as Map<String, dynamic>).remove(id);
  });

  @override
  Future<void> dispose() async {}
}
