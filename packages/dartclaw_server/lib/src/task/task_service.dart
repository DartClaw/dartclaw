import 'package:dartclaw_core/dartclaw_core.dart'
    show
        ArtifactKind,
        EventBus,
        Task,
        TaskArtifact,
        TaskRepository,
        TaskReviewReadyEvent,
        TaskStatus,
        TaskStatusChangedEvent,
        TaskType;

import 'task_event_recorder.dart';

/// Thrown when a task transition fails because the stored version does not
/// match the expected version (concurrent modification detected).
class VersionConflictException implements Exception {
  final String taskId;
  final int expectedVersion;
  final int currentVersion;

  const VersionConflictException({required this.taskId, required this.expectedVersion, required this.currentVersion});

  @override
  String toString() =>
      'VersionConflictException: task $taskId was modified concurrently '
      '(expected version $expectedVersion, found $currentVersion)';
}

/// Business logic layer for task CRUD and lifecycle operations.
class TaskService {
  final TaskRepository _repo;
  final EventBus? _eventBus;
  final TaskEventRecorder? _eventRecorder;

  TaskService(this._repo, {EventBus? eventBus, TaskEventRecorder? eventRecorder})
    : _eventBus = eventBus,
      _eventRecorder = eventRecorder;

  /// Creates a new task.
  ///
  /// When [autoStart] is true the task is queued immediately and a
  /// [TaskStatusChangedEvent] is fired for the draft→queued transition.
  Future<Task> create({
    required String id,
    required String title,
    required String description,
    required TaskType type,
    bool autoStart = false,
    String? goalId,
    String? acceptanceCriteria,
    String? createdBy,
    String? provider,
    String? projectId,
    Map<String, dynamic> configJson = const {},
    DateTime? now,
    String trigger = 'system',
  }) async {
    final timestamp = now ?? DateTime.now();
    final persistedProvider =
        provider ??
        ((configJson['provider'] as String?)?.trim().isEmpty ?? true
            ? null
            : (configJson['provider'] as String).trim());
    var task = Task(
      id: id,
      title: title,
      description: description,
      type: type,
      goalId: goalId,
      acceptanceCriteria: acceptanceCriteria,
      configJson: configJson,
      createdAt: timestamp,
      createdBy: createdBy,
      provider: persistedProvider,
      projectId: projectId?.trim().isEmpty ?? true ? null : projectId?.trim(),
    );
    if (autoStart) {
      task = task.transition(TaskStatus.queued, now: timestamp);
    }
    await _repo.insert(task);
    if (autoStart) {
      _fireEvent(
        TaskStatusChangedEvent(
          taskId: task.id,
          oldStatus: TaskStatus.draft,
          newStatus: task.status,
          trigger: trigger,
          timestamp: timestamp,
        ),
      );
      _eventRecorder?.recordStatusChanged(
        task.id,
        oldStatus: TaskStatus.draft,
        newStatus: task.status,
        trigger: trigger,
      );
    }
    return task;
  }

  /// Returns the task with [id], or null when missing.
  Future<Task?> get(String id) => _repo.getById(id);

  /// Lists tasks with optional status/type filters.
  Future<List<Task>> list({TaskStatus? status, TaskType? type}) => _repo.list(status: status, type: type);

  /// Applies a lifecycle transition.
  ///
  /// Fires [TaskStatusChangedEvent] (and [TaskReviewReadyEvent] when entering
  /// review) after a successful repository write.
  ///
  /// Throws [VersionConflictException] when the row was modified concurrently
  /// (version mismatch). Throws [StateError] when the status changed
  /// concurrently. Throws [ArgumentError] when the task does not exist.
  Future<Task> transition(
    String taskId,
    TaskStatus newStatus, {
    DateTime? now,
    Map<String, dynamic>? configJson,
    String trigger = 'system',
  }) async {
    final task = await _requireTask(taskId);
    final oldStatus = task.status;
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
      if (current.version != task.version) {
        throw VersionConflictException(taskId: taskId, expectedVersion: task.version, currentVersion: current.version);
      }
      throw StateError('Task status changed concurrently: expected ${task.status.name}, found ${current.status.name}');
    }
    _fireEvent(
      TaskStatusChangedEvent(
        taskId: taskId,
        oldStatus: oldStatus,
        newStatus: newStatus,
        trigger: trigger,
        timestamp: now ?? DateTime.now(),
      ),
    );
    _eventRecorder?.recordStatusChanged(taskId, oldStatus: oldStatus, newStatus: newStatus, trigger: trigger);
    if (newStatus == TaskStatus.review) {
      _fireReviewReadyEvent(taskId);
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
    String? projectId,
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
      projectId: projectId ?? task.projectId,
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

  void _fireEvent(TaskStatusChangedEvent event) {
    _eventBus?.fire(event);
  }

  void _fireReviewReadyEvent(String taskId) {
    final eventBus = _eventBus;
    if (eventBus == null) return;
    // Fire asynchronously to avoid blocking transition(); artifact lookup is
    // best-effort — a missing or empty artifact list is still valid.
    _repo
        .listArtifactsByTask(taskId)
        .then((artifacts) {
          final artifactKinds = artifacts.map((a) => a.kind.name).toSet().toList()..sort();
          eventBus.fire(
            TaskReviewReadyEvent(
              taskId: taskId,
              artifactCount: artifacts.length,
              artifactKinds: artifactKinds,
              timestamp: DateTime.now(),
            ),
          );
        })
        .catchError((_) {
          // Best-effort: failure to list artifacts should not prevent the review ready notification.
        });
  }
}
