import 'task.dart';
import 'task_artifact.dart';
import 'task_repository.dart';
import 'task_status.dart';
import 'task_type.dart';

/// Business logic layer for task CRUD and lifecycle operations.
class TaskService {
  final TaskRepository _repo;

  TaskService(this._repo);

  /// Creates a new task.
  Future<Task> create({
    required String id,
    required String title,
    required String description,
    required TaskType type,
    bool autoStart = false,
    String? goalId,
    String? acceptanceCriteria,
    Map<String, dynamic> configJson = const {},
    DateTime? now,
  }) async {
    final timestamp = now ?? DateTime.now();
    var task = Task(
      id: id,
      title: title,
      description: description,
      type: type,
      goalId: goalId,
      acceptanceCriteria: acceptanceCriteria,
      configJson: configJson,
      createdAt: timestamp,
    );
    if (autoStart) {
      task = task.transition(TaskStatus.queued, now: timestamp);
    }
    await _repo.insert(task);
    return task;
  }

  /// Returns the task with [id], or null when missing.
  Future<Task?> get(String id) => _repo.getById(id);

  /// Lists tasks with optional status/type filters.
  Future<List<Task>> list({TaskStatus? status, TaskType? type}) => _repo.list(status: status, type: type);

  /// Applies a lifecycle transition.
  Future<Task> transition(
    String taskId,
    TaskStatus newStatus, {
    DateTime? now,
    Map<String, dynamic>? configJson,
  }) async {
    final task = await _requireTask(taskId);
    final transitioned = task.transition(newStatus, now: now);
    final persistedTransition = task.copyWith(
      status: transitioned.status,
      configJson: configJson ?? transitioned.configJson,
      startedAt: transitioned.startedAt,
      completedAt: transitioned.completedAt,
    );
    final updated = await _repo.updateIfStatus(persistedTransition, expectedStatus: task.status);
    if (!updated) {
      final current = await _repo.getById(taskId);
      if (current == null) {
        throw ArgumentError('Task not found: $taskId');
      }
      throw StateError('Task status changed concurrently: expected ${task.status.name}, found ${current.status.name}');
    }
    return persistedTransition;
  }

  /// Updates mutable fields on a non-terminal task.
  Future<Task> updateFields(
    String taskId, {
    String? title,
    String? description,
    String? acceptanceCriteria,
    Map<String, dynamic>? configJson,
    String? sessionId,
    Map<String, dynamic>? worktreeJson,
  }) async {
    final task = await _requireTask(taskId);
    if (task.status.terminal) {
      throw StateError('Cannot update terminal task: ${task.status.name}');
    }

    final updated = task.copyWith(
      title: title,
      description: description,
      acceptanceCriteria: acceptanceCriteria ?? task.acceptanceCriteria,
      configJson: configJson ?? task.configJson,
      sessionId: sessionId ?? task.sessionId,
      worktreeJson: worktreeJson ?? task.worktreeJson,
    );

    final persisted = await _repo.updateMutableFieldsIfStatus(updated, expectedStatus: task.status);
    if (!persisted) {
      final current = await _repo.getById(taskId);
      if (current == null) {
        throw ArgumentError('Task not found: $taskId');
      }
      if (current.status.terminal) {
        throw StateError('Cannot update terminal task: ${current.status.name}');
      }
      throw StateError('Task status changed concurrently: expected ${task.status.name}, found ${current.status.name}');
    }

    return updated;
  }

  /// Deletes a terminal task.
  Future<void> delete(String taskId) async {
    final task = await _requireTask(taskId);
    if (!task.status.terminal) {
      throw StateError('Cannot delete non-terminal task: ${task.status.name}');
    }
    await _repo.delete(taskId);
  }

  /// Adds an artifact row for a task.
  Future<TaskArtifact> addArtifact({
    required String id,
    required String taskId,
    required String name,
    required ArtifactKind kind,
    required String path,
    DateTime? now,
  }) async {
    if (await _repo.getById(taskId) == null) {
      throw StateError('Cannot add artifact for missing task: $taskId');
    }

    final artifact = TaskArtifact(
      id: id,
      taskId: taskId,
      name: name,
      kind: kind,
      path: path,
      createdAt: now ?? DateTime.now(),
    );
    await _repo.insertArtifact(artifact);
    return artifact;
  }

  /// Returns the artifact with [id], or null when missing.
  Future<TaskArtifact?> getArtifact(String id) => _repo.getArtifactById(id);

  /// Lists artifacts for the task.
  Future<List<TaskArtifact>> listArtifacts(String taskId) => _repo.listArtifactsByTask(taskId);

  /// Deletes an artifact row.
  Future<void> deleteArtifact(String id) => _repo.deleteArtifact(id);

  /// Disposes the underlying repository.
  Future<void> dispose() => _repo.dispose();

  Future<Task> _requireTask(String taskId) async {
    final task = await _repo.getById(taskId);
    if (task == null) {
      throw ArgumentError('Task not found: $taskId');
    }
    return task;
  }
}
