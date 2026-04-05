import 'package:dartclaw_core/dartclaw_core.dart' show Goal, GoalRepository;

const _goalContextCharBudget = 800;
const _ellipsis = '...';

/// Business logic layer for goal CRUD and context resolution.
class GoalService {
  final GoalRepository _repo;

  GoalService(this._repo);

  /// Creates a new goal.
  Future<Goal> create({
    required String id,
    required String title,
    required String mission,
    String? parentGoalId,
    int? maxTokens,
    DateTime? now,
  }) async {
    if (parentGoalId != null) {
      final parent = await _repo.getById(parentGoalId);
      if (parent == null) {
        throw ArgumentError('Parent goal not found: $parentGoalId');
      }
      if (parent.parentGoalId != null) {
        throw StateError('Cannot nest goals beyond 2 levels');
      }
    }

    final goal = Goal(
      id: id,
      title: title,
      parentGoalId: parentGoalId,
      mission: mission,
      createdAt: now ?? DateTime.now(),
      maxTokens: maxTokens != null && maxTokens > 0 ? maxTokens : null,
    );
    await _repo.insert(goal);
    return goal;
  }

  /// Returns the goal with [id], or null when missing.
  Future<Goal?> get(String id) => _repo.getById(id);

  /// Lists all goals.
  Future<List<Goal>> list() => _repo.list();

  /// Deletes a goal by id.
  Future<void> delete(String goalId) => _repo.delete(goalId);

  /// Resolves a goal mission block for task-session prompt injection.
  Future<String?> resolveGoalContext(String? goalId) async {
    if (goalId == null) return null;

    final goal = await _repo.getById(goalId);
    if (goal == null) return null;

    final buffer = StringBuffer()
      ..writeln('## Goal: ${goal.title}')
      ..writeln(goal.mission);

    if (goal.parentGoalId != null) {
      final parent = await _repo.getById(goal.parentGoalId!);
      if (parent != null) {
        buffer
          ..writeln()
          ..writeln('## Parent Goal: ${parent.title}')
          ..writeln(parent.mission);
      }
    }

    final context = buffer.toString().trimRight();
    if (context.length <= _goalContextCharBudget) {
      return context;
    }

    return '${context.substring(0, _goalContextCharBudget - _ellipsis.length)}$_ellipsis';
  }

  /// Disposes the underlying repository.
  Future<void> dispose() => _repo.dispose();
}
