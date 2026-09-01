import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_core/dartclaw_core.dart';

import 'in_memory_task_repository.dart';

/// Returns the canonical short form used in channel-facing task messages.
String shortTaskId(String taskId) {
  final normalized = taskId.replaceAll('-', '');
  if (normalized.length <= 6) {
    return normalized;
  }
  return normalized.substring(0, 6);
}

/// Builds the `origin` JSON used by channel task and notification tests.
Map<String, dynamic> channelOriginJson({
  ChannelType channelType = ChannelType.whatsapp,
  String recipientId = 'sender@s.whatsapp.net',
  String? sessionKey,
  String? contactId,
}) {
  final resolvedContactId = contactId ?? recipientId;
  return {
    'channelType': channelType.name,
    'sessionKey':
        sessionKey ?? SessionKey.dmPerChannelContact(channelType: channelType.name, peerId: resolvedContactId),
    'recipientId': recipientId,
    'contactId': resolvedContactId,
  };
}

/// Shared in-memory task operations for channel tests.
class TaskOps {
  new(this._repo);

  final InMemoryTaskRepository _repo;

  String? lastProjectId;

  Future<Task> create({
    required String id,
    required String title,
    required String description,
    bool autoStart = false,
    String? goalId,
    String? acceptanceCriteria,
    String? createdBy,
    String? projectId,
    Map<String, dynamic> configJson = const {},
    DateTime? now,
    String trigger = 'system',
  }) async {
    lastProjectId = projectId;
    final timestamp = now ?? DateTime.now();
    var task = Task(
      id: id,
      title: title,
      description: description,
      goalId: goalId,
      acceptanceCriteria: acceptanceCriteria,
      createdBy: createdBy,
      projectId: projectId,
      configJson: configJson,
      createdAt: timestamp,
    );
    if (autoStart) {
      task = task.transition(TaskStatus.queued, now: timestamp);
    }
    await _repo.insert(task);
    return task;
  }

  Future<List<Task>> list({TaskStatus? status}) => _repo.list(status: status);

  Future<Task> transition(
    String taskId,
    TaskStatus newStatus, {
    DateTime? now,
    Map<String, dynamic>? configJson,
  }) async {
    final task = await _repo.getById(taskId);
    if (task == null) {
      throw ArgumentError('Task not found: $taskId');
    }

    final transitioned = task.transition(newStatus, now: now);
    final persisted = task.copyWith(
      status: transitioned.status,
      configJson: configJson ?? transitioned.configJson,
      startedAt: transitioned.startedAt,
      completedAt: transitioned.completedAt,
    );
    final updated = await _repo.updateIfStatus(persisted, expectedStatus: task.status);
    if (!updated) {
      throw StateError('Task status changed concurrently.');
    }
    return await _repo.getById(taskId) ?? persisted;
  }

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
    final task = await _repo.getById(taskId);
    if (task == null) {
      throw ArgumentError('Task not found: $taskId');
    }
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
      throw StateError('Task status changed concurrently.');
    }
    lastProjectId = updated.projectId;
    return updated;
  }

  Future<void> dispose() => _repo.dispose();
}

/// Creates a test task in the requested lifecycle state.
Future<Task> createTask(TaskOps tasks, String id, {required String title, required TaskStatus status}) async {
  final task = await tasks.create(
    id: id,
    title: title,
    description: title,
    autoStart: status != TaskStatus.draft,
    now: DateTime.parse('2026-03-13T10:00:00Z'),
  );
  if (status == TaskStatus.draft || status == TaskStatus.queued) {
    return task;
  }

  var current = task;
  if (current.status == TaskStatus.queued && status.index >= TaskStatus.running.index) {
    current = await tasks.transition(id, TaskStatus.running, now: DateTime.parse('2026-03-13T10:05:00Z'));
  }
  if (status == TaskStatus.running) {
    return current;
  }
  if (status == TaskStatus.review) {
    return tasks.transition(id, TaskStatus.review, now: DateTime.parse('2026-03-13T10:10:00Z'));
  }
  throw UnimplementedError('Unsupported status for test helper: $status');
}

/// Convenience wrapper for creating a task in review.
Future<Task> putTaskInReview(
  dynamic tasks,
  String id, {
  required String title,
  Map<String, dynamic> configJson = const {},
  Map<String, dynamic>? worktreeJson,
  String? sessionKey,
}) async {
  final resolvedConfigJson = <String, dynamic>{...configJson};
  resolvedConfigJson.putIfAbsent('needsWorktree', () => worktreeJson != null);
  if (sessionKey != null) {
    final originJson = <String, dynamic>{
      ...(resolvedConfigJson['origin'] as Map<String, dynamic>? ?? const {}),
      'sessionKey': sessionKey,
    };
    resolvedConfigJson['origin'] = originJson;
  }

  await tasks.create(
    id: id,
    title: title,
    description: title,
    autoStart: true,
    now: DateTime.parse('2026-03-13T10:00:00Z'),
    configJson: resolvedConfigJson,
  );
  await tasks.transition(id, TaskStatus.running, now: DateTime.parse('2026-03-13T10:05:00Z'));
  final Task reviewedTask =
      await tasks.transition(id, TaskStatus.review, now: DateTime.parse('2026-03-13T10:10:00Z')) as Task;
  if (worktreeJson != null) {
    final updated = await tasks.updateFields(id, worktreeJson: worktreeJson);
    if (updated is Task) {
      return updated;
    }
    return reviewedTask;
  }
  try {
    final loaded = await tasks.get(id);
    if (loaded is Task) {
      return loaded;
    }
    return reviewedTask;
  } on NoSuchMethodError {
    return reviewedTask;
  }
}
