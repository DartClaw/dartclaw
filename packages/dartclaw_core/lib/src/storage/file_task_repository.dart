import 'package:dartclaw_kernel/dartclaw_kernel.dart' show AgentExecution, WorkflowStepExecution;

import '../task/task.dart';
import '../task/task_artifact.dart';
import '../task/task_repository.dart';
import '../task/task_status.dart';
import 'file_execution_store.dart';

/// Task persistence over a standalone execution checkpoint.
final class FileTaskRepository implements TaskRepository {
  /// Binds task records to [store].
  new(this.store);

  /// Shared checkpoint authority.
  final FileExecutionStore store;

  @override
  Future<void> insert(Task task) => store.update((state) {
    final tasks = _records(state, 'tasks');
    if (tasks.containsKey(task.id)) throw StateError('Task already exists: ${task.id}');
    _upsertExecution(state, task.agentExecution);
    _requireExecution(state, task.agentExecutionId);
    tasks[task.id] = _taskRecord(task);
  });

  @override
  Future<Task?> getById(String id) => store.read((state) {
    final record = _records(state, 'tasks')[id];
    return record == null ? null : _hydrate(state, _json(record));
  });

  @override
  Future<List<Task>> list({TaskStatus? status}) => store.read((state) {
    final tasks = _records(state, 'tasks').values.map((row) => _hydrate(state, _json(row)));
    return _newest(tasks.where((task) => status == null || task.status == status));
  });

  @override
  Future<List<Task>> listByWorkflowRunIds(Iterable<String> runIds) => store.read((state) {
    final ids = runIds.toSet();
    if (ids.isEmpty) return <Task>[];
    return _newest(
      _records(
        state,
        'tasks',
      ).values.map((row) => _hydrate(state, _json(row))).where((task) => ids.contains(task.workflowRunId)),
    );
  });

  @override
  Future<void> update(Task task) => store.update((state) {
    final tasks = _records(state, 'tasks');
    final current = tasks[task.id];
    if (current == null || _json(current)['version'] != task.version) {
      throw ArgumentError('Task not found or version changed: ${task.id}');
    }
    _upsertExecution(state, task.agentExecution);
    _requireExecution(state, task.agentExecutionId);
    tasks[task.id] = _taskRecord(task.copyWith(version: task.version + 1));
  });

  @override
  Future<bool> updateIfStatus(Task task, {required TaskStatus expectedStatus}) => store.update((state) {
    final tasks = _records(state, 'tasks');
    final current = tasks[task.id];
    if (current == null) return false;
    final row = _json(current);
    if (row['status'] != expectedStatus.name || row['version'] != task.version) return false;
    tasks[task.id] = {
      ...row,
      'status': task.status.name,
      'version': task.version + 1,
      'configJson': task.configJson,
      if (task.startedAt != null) 'startedAt': task.startedAt!.toIso8601String(),
      if (task.startedAt == null) 'startedAt': null,
      if (task.completedAt != null) 'completedAt': task.completedAt!.toIso8601String(),
      if (task.completedAt == null) 'completedAt': null,
    };
    return true;
  });

  @override
  Future<bool> updateMutableFieldsIfStatus(Task task, {required TaskStatus expectedStatus}) => store.update((state) {
    final tasks = _records(state, 'tasks');
    final current = tasks[task.id];
    if (current == null) return false;
    final row = _json(current);
    if (row['status'] != expectedStatus.name) return false;
    _upsertExecution(state, task.agentExecution);
    _requireExecution(state, task.agentExecutionId);
    tasks[task.id] = {
      ...row,
      'title': task.title,
      'description': task.description,
      'acceptanceCriteria': task.acceptanceCriteria,
      'configJson': task.configJson,
      'worktreeJson': task.worktreeJson,
      'agentExecutionId': task.agentExecutionId,
      'projectId': task.projectId,
      'retryCount': task.retryCount,
    };
    return true;
  });

  @override
  Future<bool> mergeConfigJsonIfStatus(
    String taskId,
    Map<String, dynamic> patch, {
    required TaskStatus expectedStatus,
  }) => store.update((state) {
    final tasks = _records(state, 'tasks');
    final current = tasks[taskId];
    if (current == null) return false;
    final row = _json(current);
    if (row['status'] != expectedStatus.name) return false;
    row['configJson'] = TaskRepository.mergeConfigJsonPatch(_json(row['configJson']), patch);
    tasks[taskId] = row;
    return true;
  });

  @override
  Future<void> delete(String id) => store.update((state) {
    if (_records(state, 'tasks').remove(id) == null) throw ArgumentError('Task not found: $id');
    _records(state, 'workflowSteps').remove(id);
    _records(state, 'artifacts').removeWhere((_, row) => _json(row)['taskId'] == id);
  });

  @override
  Future<void> insertArtifact(TaskArtifact artifact) => store.update((state) {
    if (!_records(state, 'tasks').containsKey(artifact.taskId)) {
      throw ArgumentError('Task not found: ${artifact.taskId}');
    }
    final artifacts = _records(state, 'artifacts');
    if (artifacts.containsKey(artifact.id)) throw StateError('Artifact already exists: ${artifact.id}');
    artifacts[artifact.id] = artifact.toJson();
  });

  @override
  Future<TaskArtifact?> getArtifactById(String id) => store.read((state) {
    final row = _records(state, 'artifacts')[id];
    return row == null ? null : TaskArtifact.fromJson(_json(row));
  });

  @override
  Future<List<TaskArtifact>> listArtifactsByTask(String taskId) => store.read((state) {
    final artifacts = _records(
      state,
      'artifacts',
    ).values.map((row) => TaskArtifact.fromJson(_json(row))).where((artifact) => artifact.taskId == taskId).toList();
    artifacts.sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return artifacts;
  });

  @override
  Future<void> deleteArtifact(String id) => store.update((state) {
    _records(state, 'artifacts').remove(id);
  });

  @override
  Future<void> dispose() async {}

  Task _hydrate(Map<String, dynamic> state, Map<String, dynamic> record) {
    final id = record['id'] as String;
    final executionId = record['agentExecutionId'] as String?;
    final execution = executionId == null ? null : _records(state, 'agentExecutions')[executionId];
    if (executionId != null && execution == null) {
      throw FormatException('Task $id refers to missing agent execution $executionId in ${store.path}');
    }
    final step = _records(state, 'workflowSteps')[id];
    return Task.fromJson({
      ...record,
      if (execution != null) 'agentExecution': AgentExecution.fromJson(_json(execution)).toJson(),
      if (step != null) 'workflowStepExecution': WorkflowStepExecution.fromJson(_json(step)).toJson(),
    }).copyWith(workflowRunId: record['workflowRunId'] as String?, stepIndex: record['stepIndex'] as int?);
  }

  Map<String, dynamic> _taskRecord(Task task) => task.toJson()
    ..remove('agentExecution')
    ..remove('workflowStepExecution')
    ..['workflowRunId'] = task.workflowRunId
    ..['stepIndex'] = task.stepIndex;

  void _upsertExecution(Map<String, dynamic> state, AgentExecution? execution) {
    if (execution != null) _records(state, 'agentExecutions')[execution.id] = execution.toJson();
  }

  void _requireExecution(Map<String, dynamic> state, String? executionId) {
    if (executionId != null && !_records(state, 'agentExecutions').containsKey(executionId)) {
      throw ArgumentError('AgentExecution not found: $executionId');
    }
  }

  List<Task> _newest(Iterable<Task> tasks) {
    final result = tasks.toList();
    result.sort((a, b) {
      final byTime = b.createdAt.compareTo(a.createdAt);
      return byTime == 0 ? b.id.compareTo(a.id) : byTime;
    });
    return result;
  }
}

Map<String, dynamic> _records(Map<String, dynamic> state, String key) => state[key] as Map<String, dynamic>;
Map<String, dynamic> _json(Object? value) => Map<String, dynamic>.from(value as Map);
