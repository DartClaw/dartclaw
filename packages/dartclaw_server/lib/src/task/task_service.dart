import 'package:dartclaw_core/dartclaw_core.dart'
    show
        AgentExecution,
        AgentExecutionRepository,
        ArtifactKind,
        EventBus,
        ExecutionRepositoryTransactor,
        Task,
        TaskArtifact,
        TaskRepository,
        TaskReviewReadyEvent,
        TaskStatus,
        TaskStatusChangedEvent,
        TaskType,
        WorkflowTaskService;

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
class TaskService implements WorkflowTaskService {
  final TaskRepository _repo;
  final AgentExecutionRepository? _agentExecutionRepository;
  final ExecutionRepositoryTransactor? _executionTransactor;
  final EventBus? _eventBus;
  final TaskEventRecorder? _eventRecorder;

  TaskService(
    this._repo, {
    AgentExecutionRepository? agentExecutionRepository,
    ExecutionRepositoryTransactor? executionTransactor,
    EventBus? eventBus,
    TaskEventRecorder? eventRecorder,
  }) : _agentExecutionRepository = agentExecutionRepository,
       _executionTransactor = executionTransactor,
       _eventBus = eventBus,
       _eventRecorder = eventRecorder;

  /// Creates a new task.
  ///
  /// When [autoStart] is true the task is queued immediately and a
  /// [TaskStatusChangedEvent] is fired for the draft→queued transition.
  @override
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
    String? agentExecutionId,
    String? projectId,
    int? maxTokens,
    String? workflowRunId,
    int? stepIndex,
    int maxRetries = 0,
    Map<String, dynamic> configJson = const {},
    DateTime? now,
    String trigger = 'system',
  }) async {
    final timestamp = now ?? DateTime.now();
    final persistedProvider = _trimmedOrNull(
      provider ??
          ((configJson['provider'] as String?)?.trim().isEmpty ?? true ? null : configJson['provider'] as String?),
    );
    final persistedModel = _trimmedOrNull(configJson['model'] as String?);
    final normalizedMaxTokens = maxTokens != null && maxTokens > 0 ? maxTokens : null;
    final sanitizedConfig = Map<String, dynamic>.from(configJson)..remove('model');
    final persistedAgentExecutionId = agentExecutionId?.trim().isEmpty ?? true ? null : agentExecutionId?.trim();
    final agentExecutionRepository = _agentExecutionRepository;
    final createdExecution =
        (persistedAgentExecutionId == null || await _shouldCreateAgentExecution(persistedAgentExecutionId))
        ? AgentExecution(
            id: persistedAgentExecutionId ?? 'ae-$id',
            provider: persistedProvider,
            model: persistedModel,
            budgetTokens: normalizedMaxTokens,
          )
        : null;
    final linkedExecution =
        createdExecution == null && persistedAgentExecutionId != null && agentExecutionRepository != null
        ? await agentExecutionRepository.get(persistedAgentExecutionId)
        : null;
    final effectiveExecution = createdExecution ?? linkedExecution;
    var task = Task(
      id: id,
      title: title,
      description: description,
      type: type,
      goalId: goalId,
      acceptanceCriteria: acceptanceCriteria,
      configJson: sanitizedConfig,
      createdAt: timestamp,
      createdBy: createdBy,
      provider: effectiveExecution == null ? persistedProvider : null,
      model: effectiveExecution == null ? persistedModel : null,
      agentExecutionId: persistedAgentExecutionId ?? effectiveExecution?.id,
      agentExecution: effectiveExecution,
      projectId: projectId?.trim().isEmpty ?? true ? null : projectId?.trim(),
      maxTokens: effectiveExecution == null ? normalizedMaxTokens : null,
      workflowRunId: workflowRunId?.trim().isEmpty ?? true ? null : workflowRunId?.trim(),
      stepIndex: stepIndex,
      maxRetries: maxRetries > 0 ? maxRetries : 0,
    );
    if (autoStart) {
      task = task.transition(TaskStatus.queued, now: timestamp);
    }
    final agentExecutions = agentExecutionRepository;
    final transactor = _executionTransactor;
    if (createdExecution != null && agentExecutions != null && transactor != null) {
      await transactor.transaction(() async {
        await agentExecutions.create(createdExecution);
        await _repo.insert(task);
      });
    } else if (createdExecution != null && agentExecutions != null) {
      await agentExecutions.create(createdExecution);
      await _repo.insert(task);
    } else {
      await _repo.insert(task);
    }
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
  @override
  Future<Task?> get(String id) => _repo.getById(id);

  /// Lists tasks with optional status/type filters.
  @override
  Future<List<Task>> list({TaskStatus? status, TaskType? type}) => _repo.list(status: status, type: type);

  /// Applies a lifecycle transition.
  ///
  /// Fires [TaskStatusChangedEvent] (and [TaskReviewReadyEvent] when entering
  /// review) after a successful repository write.
  ///
  /// Throws [VersionConflictException] when the row was modified concurrently
  /// (version mismatch). Throws [StateError] when the status changed
  /// concurrently. Throws [ArgumentError] when the task does not exist.
  @override
  Future<Task> transition(
    String taskId,
    TaskStatus newStatus, {
    DateTime? now,
    Map<String, dynamic>? configJson,
    String trigger = 'system',
  }) async {
    final task = await _requireTask(taskId);
    final oldStatus = task.status;
    final timestamp = now ?? DateTime.now();
    final transitioned = task.transition(newStatus, now: now);
    final nextExecution = _nextAgentExecutionForTransition(task, transitioned);
    final persistedTransition = task.copyWith(
      status: transitioned.status,
      configJson: configJson ?? transitioned.configJson,
      startedAt: transitioned.startedAt,
      completedAt: transitioned.completedAt,
      agentExecution: nextExecution,
    );
    final updated = await _persistTransition(
      original: task,
      transitioned: persistedTransition,
      nextExecution: nextExecution,
      trigger: trigger,
      timestamp: timestamp,
    );
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
        timestamp: timestamp,
      ),
    );
    _eventRecorder?.recordStatusChanged(taskId, oldStatus: oldStatus, newStatus: newStatus, trigger: trigger);
    if (newStatus == TaskStatus.review) {
      _fireReviewReadyEvent(taskId);
    }
    return persistedTransition;
  }

  static const _sentinel = Object();

  /// Updates mutable fields on a non-terminal task.
  ///
  /// Use [clearSessionId] to explicitly clear the session ID (e.g., on retry).
  /// Use [retryCount] to update the retry attempt counter.
  Future<Task> updateFields(
    String taskId, {
    String? title,
    String? description,
    String? acceptanceCriteria,
    Map<String, dynamic>? configJson,
    Object? sessionId = _sentinel,
    Map<String, dynamic>? worktreeJson,
    String? projectId,
    int? retryCount,
  }) async {
    final task = await _requireTask(taskId);
    if (task.status.terminal) {
      throw StateError('Cannot update terminal task: ${task.status.name}');
    }

    final resolvedSessionId = identical(sessionId, _sentinel) ? task.sessionId : sessionId as String?;
    final currentExecution = task.agentExecution;
    final fallbackExecutionId = task.agentExecutionId ?? 'legacy-ae:${task.id}';
    final nextExecution = identical(sessionId, _sentinel)
        ? currentExecution
        : currentExecution?.copyWith(sessionId: resolvedSessionId) ??
            (resolvedSessionId == null ? null : AgentExecution(id: fallbackExecutionId, sessionId: resolvedSessionId));

    final updated = task.copyWith(
      title: title,
      description: description,
      acceptanceCriteria: acceptanceCriteria ?? task.acceptanceCriteria,
      configJson: configJson ?? task.configJson,
      worktreeJson: worktreeJson ?? task.worktreeJson,
      sessionId: resolvedSessionId,
      agentExecutionId: nextExecution?.id ?? task.agentExecutionId,
      agentExecution: nextExecution,
      projectId: projectId ?? task.projectId,
      retryCount: retryCount,
    );

    final agentExecutionChanged = nextExecution != currentExecution;
    final agentExecutionRepository = _agentExecutionRepository;
    final transactor = _executionTransactor;
    bool persisted;
    if (agentExecutionChanged && nextExecution != null && agentExecutionRepository != null && transactor != null) {
      try {
        await transactor.transaction(() async {
          final mutableFieldsUpdated = await _repo.updateMutableFieldsIfStatus(updated, expectedStatus: task.status);
          if (!mutableFieldsUpdated) {
            throw const _TaskTransitionConflict();
          }
          final existing = await agentExecutionRepository.get(nextExecution.id);
          if (existing == null) {
            await agentExecutionRepository.create(nextExecution);
          } else {
            await agentExecutionRepository.update(nextExecution, trigger: 'system');
          }
        });
        persisted = true;
      } on _TaskTransitionConflict {
        persisted = false;
      }
    } else {
      persisted = await _repo.updateMutableFieldsIfStatus(updated, expectedStatus: task.status);
      if (persisted && agentExecutionChanged && nextExecution != null && agentExecutionRepository != null) {
        final existing = await agentExecutionRepository.get(nextExecution.id);
        if (existing == null) {
          await agentExecutionRepository.create(nextExecution);
        } else {
          await agentExecutionRepository.update(nextExecution, trigger: 'system');
        }
      }
    }
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
  @override
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

  AgentExecution? _nextAgentExecutionForTransition(Task current, Task transitioned) {
    final execution = current.agentExecution;
    if (execution == null) {
      return current.agentExecution;
    }

    var nextExecution = execution;
    if (transitioned.startedAt != execution.startedAt && transitioned.startedAt != null) {
      nextExecution = nextExecution.copyWith(startedAt: transitioned.startedAt);
    }
    if (transitioned.completedAt != execution.completedAt) {
      nextExecution = nextExecution.copyWith(completedAt: transitioned.completedAt);
    }
    return nextExecution;
  }

  Future<bool> _persistTransition({
    required Task original,
    required Task transitioned,
    required AgentExecution? nextExecution,
    required String trigger,
    required DateTime timestamp,
  }) async {
    final execution = original.agentExecution;
    final repository = _agentExecutionRepository;
    if (execution == null || repository == null || nextExecution == null) {
      return _repo.updateIfStatus(transitioned, expectedStatus: original.status);
    }

    if (nextExecution == execution) {
      return _repo.updateIfStatus(transitioned, expectedStatus: original.status);
    }

    final transactor = _executionTransactor;
    if (transactor != null) {
      try {
        await transactor.transaction(() async {
          final updated = await _repo.updateIfStatus(transitioned, expectedStatus: original.status);
          if (!updated) {
            throw const _TaskTransitionConflict();
          }
          final existing = await repository.get(nextExecution.id);
          if (existing == null) {
            await repository.create(nextExecution);
          } else {
            await repository.update(nextExecution, trigger: trigger, timestamp: timestamp);
          }
        });
        return true;
      } on _TaskTransitionConflict {
        return false;
      }
    }

    final updated = await _repo.updateIfStatus(transitioned, expectedStatus: original.status);
    if (!updated) {
      return false;
    }
    final existing = await repository.get(nextExecution.id);
    if (existing == null) {
      await repository.create(nextExecution);
    } else {
      await repository.update(nextExecution, trigger: trigger, timestamp: timestamp);
    }
    return true;
  }

  String? _trimmedOrNull(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  Future<bool> _shouldCreateAgentExecution(String? agentExecutionId) async {
    final repository = _agentExecutionRepository;
    if (agentExecutionId == null || repository == null) {
      return agentExecutionId == null;
    }
    return await repository.get(agentExecutionId) == null;
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

final class _TaskTransitionConflict implements Exception {
  const _TaskTransitionConflict();
}
