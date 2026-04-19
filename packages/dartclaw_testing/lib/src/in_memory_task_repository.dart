import 'package:dartclaw_core/dartclaw_core.dart';

/// In-memory [TaskRepository] with canonical task-test helper behaviors.
class InMemoryTaskRepository implements TaskRepository {
  final Map<String, Task> _tasks = <String, Task>{};
  final Map<String, TaskArtifact> _artifacts = <String, TaskArtifact>{};
  bool _spoofNextReadAfterSuccessfulTransition = false;

  /// Whether [dispose] has been called.
  bool disposed = false;

  /// Simulates a concurrent status change during the next transition write.
  TaskStatus? concurrentStatusOnNextTransition;

  /// Simulates a concurrent version conflict during the next transition write.
  ///
  /// When set, the repository bumps the stored version before the write check,
  /// causing a version mismatch that returns false from [updateIfStatus].
  bool concurrentVersionOnNextTransition = false;

  /// Simulates a concurrent status change during the next mutable update write.
  TaskStatus? concurrentStatusOnNextMutableUpdate;

  /// Overrides the next [getById] result after a successful transition write.
  Task? taskReturnedOnNextReadAfterSuccessfulTransition;

  @override
  Future<void> insert(Task task) async {
    if (_tasks.containsKey(task.id)) {
      throw ArgumentError('Task already exists: ${task.id}');
    }
    _tasks[task.id] = task;
  }

  @override
  Future<Task?> getById(String id) async {
    if (_spoofNextReadAfterSuccessfulTransition) {
      _spoofNextReadAfterSuccessfulTransition = false;
      final overriddenTask = taskReturnedOnNextReadAfterSuccessfulTransition;
      taskReturnedOnNextReadAfterSuccessfulTransition = null;
      return overriddenTask;
    }
    return _tasks[id];
  }

  @override
  Future<List<Task>> list({TaskStatus? status, TaskType? type}) async {
    final tasks = _tasks.values.where((task) {
      if (status != null && task.status != status) {
        return false;
      }
      if (type != null && task.type != type) {
        return false;
      }
      return true;
    }).toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return tasks;
  }

  @override
  Future<void> update(Task task) async {
    final current = _tasks[task.id];
    if (current == null) {
      throw ArgumentError('Task not found: ${task.id}');
    }
    _tasks[task.id] = task.copyWith(version: current.version + 1);
  }

  @override
  Future<bool> updateIfStatus(Task task, {required TaskStatus expectedStatus}) async {
    final current = _tasks[task.id];
    if (current == null) {
      return false;
    }

    final concurrentStatus = concurrentStatusOnNextTransition;
    if (concurrentStatus != null) {
      concurrentStatusOnNextTransition = null;
      _tasks[task.id] = current.copyWith(status: concurrentStatus);
      return false;
    }

    if (concurrentVersionOnNextTransition) {
      concurrentVersionOnNextTransition = false;
      // Bump the stored version to simulate a concurrent write.
      _tasks[task.id] = current.copyWith(version: current.version + 1);
      return false;
    }

    if (current.status != expectedStatus) {
      return false;
    }

    if (current.version != task.version) {
      return false;
    }

    _tasks[task.id] = current.copyWith(
      status: task.status,
      configJson: task.configJson,
      startedAt: task.startedAt,
      completedAt: task.completedAt,
      version: current.version + 1,
    );
    if (taskReturnedOnNextReadAfterSuccessfulTransition != null) {
      _spoofNextReadAfterSuccessfulTransition = true;
    }
    return true;
  }

  @override
  Future<bool> updateMutableFieldsIfStatus(Task task, {required TaskStatus expectedStatus}) async {
    final current = _tasks[task.id];
    if (current == null) {
      return false;
    }

    final concurrentStatus = concurrentStatusOnNextMutableUpdate;
    if (concurrentStatus != null) {
      concurrentStatusOnNextMutableUpdate = null;
      _tasks[task.id] = current.copyWith(status: concurrentStatus);
      return false;
    }

    if (current.status != expectedStatus) {
      return false;
    }

    _tasks[task.id] = current.copyWith(
      title: task.title,
      description: task.description,
      acceptanceCriteria: task.acceptanceCriteria,
      sessionId: task.sessionId,
      configJson: task.configJson,
      worktreeJson: task.worktreeJson,
      agentExecutionId: task.agentExecutionId,
      projectId: task.projectId ?? current.projectId,
    );
    return true;
  }

  @override
  Future<void> delete(String id) async {
    if (_tasks.remove(id) == null) {
      throw ArgumentError('Task not found: $id');
    }
    _artifacts.removeWhere((_, artifact) => artifact.taskId == id);
  }

  @override
  Future<void> insertArtifact(TaskArtifact artifact) async {
    _artifacts[artifact.id] = artifact;
  }

  @override
  Future<TaskArtifact?> getArtifactById(String id) async => _artifacts[id];

  @override
  Future<List<TaskArtifact>> listArtifactsByTask(String taskId) async {
    final artifacts = _artifacts.values.where((artifact) => artifact.taskId == taskId).toList()
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return artifacts;
  }

  @override
  Future<void> deleteArtifact(String id) async {
    _artifacts.remove(id);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}
