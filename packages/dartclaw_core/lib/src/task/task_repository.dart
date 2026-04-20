import 'package:dartclaw_models/dartclaw_models.dart' show TaskType;

import 'task.dart';
import 'task_artifact.dart';
import 'task_status.dart';

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

  /// Persists transition fields and transition-safe config fields only when the
  /// current status matches [expectedStatus].
  ///
  /// Returns `true` when the update was applied, or `false` when the row is
  /// missing or its status changed before the write.
  Future<bool> updateIfStatus(Task task, {required TaskStatus expectedStatus});

  /// Persists mutable task fields only when the current status matches [expectedStatus].
  ///
  /// Returns `true` when the update was applied, or `false` when the row is
  /// missing or its status changed before the write.
  Future<bool> updateMutableFieldsIfStatus(Task task, {required TaskStatus expectedStatus});

  /// Atomically merges [patch] into the task's `configJson` when the current
  /// status matches [expectedStatus].
  ///
  /// Merge semantics follow RFC 7396 JSON Merge Patch: keys in [patch] replace
  /// matching keys in `configJson`; null values remove keys. Because the merge
  /// happens as a single storage-level update (not a read-modify-write), this
  /// is safe against concurrent writers that only touch disjoint config keys.
  ///
  /// Returns `true` when the patch was applied, or `false` when the row is
  /// missing or its status changed before the write.
  Future<bool> mergeConfigJsonIfStatus(
    String taskId,
    Map<String, dynamic> patch, {
    required TaskStatus expectedStatus,
  });

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
