import 'goal.dart';

/// Storage-agnostic contract for goal persistence.
abstract class GoalRepository {
  /// Inserts a new goal.
  Future<void> insert(Goal goal);

  /// Returns the goal with [id], or null when missing.
  Future<Goal?> getById(String id);

  /// Lists goals ordered by newest first.
  Future<List<Goal>> list();

  /// Deletes a goal by id.
  Future<void> delete(String id);

  /// Releases underlying resources.
  Future<void> dispose();
}
