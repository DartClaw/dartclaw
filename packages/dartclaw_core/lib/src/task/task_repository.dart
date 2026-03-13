import 'task.dart';
import 'task_artifact.dart';
import 'task_status.dart';
import 'task_type.dart';

/// Storage-agnostic contract for task persistence.
abstract class TaskRepository {
  /// Inserts a new task.
  Future<void> insert(Task task);

  /// Returns the task with [id], or null when missing.
  Future<Task?> getById(String id);

  /// Lists tasks ordered by newest first.
  Future<List<Task>> list({TaskStatus? status, TaskType? type});

  /// Persists an update to an existing task.
  Future<void> update(Task task);

  /// Persists transition fields only when the current status matches [expectedStatus].
  ///
  /// Returns `true` when the update was applied, or `false` when the row is
  /// missing or its status changed before the write.
  Future<bool> updateIfStatus(Task task, {required TaskStatus expectedStatus});

  /// Persists mutable task fields only when the current status matches [expectedStatus].
  ///
  /// Returns `true` when the update was applied, or `false` when the row is
  /// missing or its status changed before the write.
  Future<bool> updateMutableFieldsIfStatus(Task task, {required TaskStatus expectedStatus});

  /// Deletes a task by id.
  Future<void> delete(String id);

  /// Inserts an artifact row.
  Future<void> insertArtifact(TaskArtifact artifact);

  /// Returns the artifact with [id], or null when missing.
  Future<TaskArtifact?> getArtifactById(String id);

  /// Lists artifacts for a task ordered by oldest first.
  Future<List<TaskArtifact>> listArtifactsByTask(String taskId);

  /// Deletes an artifact by id.
  Future<void> deleteArtifact(String id);

  /// Releases underlying resources.
  Future<void> dispose();
}
