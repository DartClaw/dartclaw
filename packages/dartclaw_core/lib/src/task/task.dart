import 'package:dartclaw_models/dartclaw_models.dart' show TaskType;

import '../execution/agent_execution.dart';
import '../execution/workflow_step_execution.dart';
import 'task_status.dart';

/// Immutable task value object for orchestrated work.
///
/// A task tracks the lifecycle of a unit of work from draft through review or
/// terminal completion, along with optional goal linkage and worktree context.
class Task {
  /// Unique identifier for this task.
  final String id;

  /// Short title shown in task lists and review surfaces.
  final String title;

  /// Full task description or operator request.
  final String description;

  /// High-level category that influences routing and defaults.
  final TaskType type;

  /// Current lifecycle status for this task.
  final TaskStatus status;

  /// Optional identifier of the parent [Goal] that owns this task.
  final String? goalId;

  /// Optional acceptance criteria used during review.
  final String? acceptanceCriteria;

  /// Arbitrary task configuration persisted as immutable JSON data.
  final Map<String, dynamic> configJson;

  /// Optional worktree metadata persisted for coding-style tasks.
  final Map<String, dynamic>? worktreeJson;

  /// Timestamp when this task record was created.
  final DateTime createdAt;

  /// Timestamp when work on this task first started, if ever.
  final DateTime? startedAt;

  /// Timestamp when the task reached a terminal state.
  final DateTime? completedAt;

  /// Optimistic locking version, incremented on each status transition.
  ///
  /// Starts at 1 for all new tasks. Existing tasks without a persisted version
  /// default to 1 for backward compatibility.
  final int version;

  /// Display name of the person or system that requested this task.
  ///
  /// Set from channel sender metadata (WhatsApp pushname, Google Chat
  /// displayName, Signal sourceName) when the task originates from a channel
  /// message, or from the UI when created via the web interface.
  final String? createdBy;

  /// Optional shared execution row linked to this task.
  final String? agentExecutionId;

  /// Optional hydrated shared execution row linked to this task.
  final AgentExecution? agentExecution;

  /// Optional project this task targets.
  ///
  /// When set, the task's worktree is created from the project's clone.
  /// When null, the task uses the default project (typically _local).
  final String? projectId;

  /// Optional workflow run that owns this task.
  final String? _workflowRunId;

  /// Optional step index within the workflow (0-based).
  final int? _stepIndex;

  /// Optional hydrated workflow step execution row linked to this task.
  final WorkflowStepExecution? workflowStepExecution;

  /// Maximum retry attempts on failure (default 0 = no retries).
  ///
  /// When a task fails and `retryCount < maxRetries`, the task is
  /// automatically re-queued with retry context injected into the prompt.
  /// Error class loop detection prevents retrying the same recurring error.
  final int maxRetries;

  /// Number of retry attempts consumed so far (default 0).
  ///
  /// Incremented each time the task is re-queued after failure.
  /// When `retryCount >= maxRetries`, the task fails permanently.
  final int retryCount;

  /// Creates an immutable task record.
  Task({
    required this.id,
    required this.title,
    required this.description,
    required this.type,
    this.status = TaskStatus.draft,
    this.goalId,
    this.acceptanceCriteria,
    String? sessionId,
    Map<String, dynamic>? configJson,
    Map<String, dynamic>? worktreeJson,
    required this.createdAt,
    this.startedAt,
    this.completedAt,
    this.version = 1,
    this.createdBy,
    String? agentExecutionId,
    AgentExecution? agentExecution,
    this.projectId,
    String? provider,
    String? model,
    int? maxTokens,
    String? workflowRunId,
    int? stepIndex,
    this.workflowStepExecution,
    this.maxRetries = 0,
    this.retryCount = 0,
  }) : configJson = _freezeJsonMap(configJson ?? const {}),
       worktreeJson = worktreeJson == null ? null : _freezeJsonMap(worktreeJson),
       agentExecution =
           agentExecution ??
           _legacyAgentExecution(
             agentExecutionId: agentExecutionId,
             taskId: id,
             sessionId: sessionId,
             provider: provider,
             model: model,
             maxTokens: maxTokens,
           ),
       agentExecutionId =
           agentExecutionId ?? agentExecution?.id ?? _legacyAgentExecutionId(id, sessionId, provider, model, maxTokens),
       _workflowRunId = workflowRunId,
       _stepIndex = stepIndex;

  /// Returns a new task with selected fields replaced.
  Task copyWith({
    String? id,
    String? title,
    String? description,
    TaskType? type,
    TaskStatus? status,
    Object? goalId = _sentinel,
    Object? acceptanceCriteria = _sentinel,
    Object? sessionId = _sentinel,
    Object? configJson = _sentinel,
    Object? worktreeJson = _sentinel,
    DateTime? createdAt,
    Object? startedAt = _sentinel,
    Object? completedAt = _sentinel,
    int? version,
    Object? createdBy = _sentinel,
    Object? provider = _sentinel,
    Object? agentExecutionId = _sentinel,
    Object? agentExecution = _sentinel,
    Object? projectId = _sentinel,
    Object? model = _sentinel,
    Object? maxTokens = _sentinel,
    Object? workflowRunId = _sentinel,
    Object? stepIndex = _sentinel,
    Object? workflowStepExecution = _sentinel,
    int? maxRetries,
    int? retryCount,
  }) => Task(
    id: id ?? this.id,
    title: title ?? this.title,
    description: description ?? this.description,
    type: type ?? this.type,
    status: status ?? this.status,
    goalId: identical(goalId, _sentinel) ? this.goalId : goalId as String?,
    acceptanceCriteria: identical(acceptanceCriteria, _sentinel)
        ? this.acceptanceCriteria
        : acceptanceCriteria as String?,
    sessionId: identical(sessionId, _sentinel) ? this.sessionId : sessionId as String?,
    configJson: identical(configJson, _sentinel) ? this.configJson : configJson as Map<String, dynamic>?,
    worktreeJson: identical(worktreeJson, _sentinel) ? this.worktreeJson : worktreeJson as Map<String, dynamic>?,
    createdAt: createdAt ?? this.createdAt,
    startedAt: identical(startedAt, _sentinel) ? this.startedAt : startedAt as DateTime?,
    completedAt: identical(completedAt, _sentinel) ? this.completedAt : completedAt as DateTime?,
    version: version ?? this.version,
    createdBy: identical(createdBy, _sentinel) ? this.createdBy : createdBy as String?,
    agentExecutionId: identical(agentExecutionId, _sentinel) ? this.agentExecutionId : agentExecutionId as String?,
    agentExecution: identical(agentExecution, _sentinel)
        ? _copyAgentExecution(
            this.id,
            this.agentExecution,
            sessionId: sessionId,
            provider: provider,
            model: model,
            maxTokens: maxTokens,
          )
        : agentExecution as AgentExecution?,
    projectId: identical(projectId, _sentinel) ? this.projectId : projectId as String?,
    model: identical(model, _sentinel) ? this.model : model as String?,
    maxTokens: identical(maxTokens, _sentinel) ? this.maxTokens : maxTokens as int?,
    workflowRunId: identical(workflowRunId, _sentinel) ? this.workflowRunId : workflowRunId as String?,
    stepIndex: identical(stepIndex, _sentinel) ? this.stepIndex : stepIndex as int?,
    workflowStepExecution: identical(workflowStepExecution, _sentinel)
        ? _copyWorkflowStepExecution(this.workflowStepExecution, workflowRunId: workflowRunId, stepIndex: stepIndex)
        : workflowStepExecution as WorkflowStepExecution?,
    maxRetries: maxRetries ?? this.maxRetries,
    retryCount: retryCount ?? this.retryCount,
  );

  /// Session associated with the task's execution, if one has been created.
  String? get sessionId => agentExecution?.sessionId;

  /// Optional provider override for executing this task.
  String? get provider => agentExecution?.provider;

  /// Optional model override resolved for this task.
  String? get model => agentExecution?.model;

  /// Optional maximum token budget for this task.
  ///
  /// When set, cumulative token consumption is checked before each turn.
  /// At the warning threshold: warning event + system message injected.
  /// At 100%: task fails with `budget_exceeded` reason.
  /// Overrides goal-level and global defaults.
  int? get maxTokens => agentExecution?.budgetTokens;

  /// Optional workflow run that owns this task.
  String? get workflowRunId => workflowStepExecution?.workflowRunId ?? _workflowRunId;

  /// Optional step index within the workflow (0-based).
  int? get stepIndex => workflowStepExecution?.stepIndex ?? _stepIndex;

  /// Applies a validated lifecycle transition and updates timestamps.
  Task transition(TaskStatus newStatus, {DateTime? now}) {
    if (!status.canTransitionTo(newStatus)) {
      throw StateError('Invalid task status transition: ${status.name} -> ${newStatus.name}');
    }

    final timestamp = now ?? DateTime.now();
    final nextConfigJson = _mutableJsonMap(configJson);
    if (status == TaskStatus.review && newStatus == TaskStatus.queued) {
      final currentCount = nextConfigJson['pushBackCount'];
      nextConfigJson['pushBackCount'] = (currentCount is num ? currentCount.toInt() : 0) + 1;
    }

    var nextStartedAt = startedAt;
    if (newStatus == TaskStatus.running) {
      nextStartedAt = timestamp;
    }

    var nextCompletedAt = completedAt;
    if (newStatus.terminal) {
      nextCompletedAt = timestamp;
    } else if ((status == TaskStatus.review || status == TaskStatus.interrupted || status == TaskStatus.failed) &&
        newStatus == TaskStatus.queued) {
      nextCompletedAt = null;
    }

    return copyWith(
      status: newStatus,
      configJson: nextConfigJson,
      startedAt: nextStartedAt,
      completedAt: nextCompletedAt,
    );
  }

  /// Serializes this task to the JSON shape used by repositories.
  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'description': description,
    'type': type.name,
    'status': status.name,
    'version': version,
    if (goalId != null) 'goalId': goalId,
    if (acceptanceCriteria != null) 'acceptanceCriteria': acceptanceCriteria,
    if (createdBy != null) 'createdBy': createdBy,
    if (agentExecutionId != null) 'agentExecutionId': agentExecutionId,
    if (projectId != null) 'projectId': projectId,
    if (maxRetries != 0) 'maxRetries': maxRetries,
    if (retryCount != 0) 'retryCount': retryCount,
    'configJson': _mutableJsonMap(configJson),
    if (worktreeJson != null) 'worktreeJson': _mutableJsonMap(worktreeJson!),
    'createdAt': createdAt.toIso8601String(),
    if (startedAt != null) 'startedAt': startedAt!.toIso8601String(),
    if (completedAt != null) 'completedAt': completedAt!.toIso8601String(),
    if (agentExecution != null) 'agentExecution': agentExecution!.toJson(),
    if (workflowStepExecution != null) 'workflowStepExecution': workflowStepExecution!.toJson(),
  };

  /// Deserializes a task from persisted JSON.
  factory Task.fromJson(Map<String, dynamic> json) => Task(
    id: json['id'] as String,
    title: json['title'] as String,
    description: json['description'] as String,
    type: TaskType.values.byName(json['type'] as String),
    status: _parseStatus(json['status']),
    version: (json['version'] as int?) ?? 1,
    goalId: json['goalId'] as String?,
    acceptanceCriteria: json['acceptanceCriteria'] as String?,
    configJson: _jsonMapOrEmpty(json['configJson']),
    worktreeJson: _jsonMapOrNull(json['worktreeJson']),
    createdAt: DateTime.parse(json['createdAt'] as String),
    startedAt: _parseDateTime(json['startedAt']),
    completedAt: _parseDateTime(json['completedAt']),
    createdBy: json['createdBy'] as String?,
    agentExecutionId: json['agentExecutionId'] as String?,
    agentExecution: _agentExecutionFromJson(json),
    projectId: json['projectId'] as String?,
    workflowRunId: _workflowStepExecutionFromJson(json)?.workflowRunId,
    stepIndex: _workflowStepExecutionFromJson(json)?.stepIndex,
    workflowStepExecution: _workflowStepExecutionFromJson(json),
    maxRetries: (json['maxRetries'] as int?) ?? 0,
    retryCount: (json['retryCount'] as int?) ?? 0,
  );

  /// True when this task is orchestrated by a workflow rather than the
  /// standalone task review/merge flow.
  bool get isWorkflowOwnedGitTask => workflowRunId != null;
}

const _sentinel = Object();

AgentExecution? _legacyAgentExecution({
  required String taskId,
  required String? agentExecutionId,
  required String? sessionId,
  required String? provider,
  required String? model,
  required int? maxTokens,
}) {
  if (sessionId == null && provider == null && model == null && maxTokens == null) {
    return null;
  }
  return AgentExecution(
    id: agentExecutionId ?? _legacyAgentExecutionId(taskId, sessionId, provider, model, maxTokens)!,
    sessionId: sessionId,
    provider: provider,
    model: model,
    budgetTokens: maxTokens,
  );
}

String? _legacyAgentExecutionId(String taskId, String? sessionId, String? provider, String? model, int? maxTokens) {
  if (sessionId == null && provider == null && model == null && maxTokens == null) {
    return null;
  }
  return 'legacy-ae:$taskId';
}

AgentExecution? _copyAgentExecution(
  String taskId,
  AgentExecution? current, {
  required Object? sessionId,
  required Object? provider,
  required Object? model,
  required Object? maxTokens,
}) {
  if (current == null) {
    if (identical(sessionId, _sentinel) &&
        identical(provider, _sentinel) &&
        identical(model, _sentinel) &&
        identical(maxTokens, _sentinel)) {
      return null;
    }
    return _legacyAgentExecution(
      taskId: taskId,
      agentExecutionId: null,
      sessionId: identical(sessionId, _sentinel) ? null : sessionId as String?,
      provider: identical(provider, _sentinel) ? null : provider as String?,
      model: identical(model, _sentinel) ? null : model as String?,
      maxTokens: identical(maxTokens, _sentinel) ? null : maxTokens as int?,
    );
  }
  var next = current;
  if (!identical(sessionId, _sentinel)) {
    next = next.copyWith(sessionId: sessionId as String?);
  }
  if (!identical(provider, _sentinel)) {
    next = next.copyWith(provider: provider as String?);
  }
  if (!identical(model, _sentinel)) {
    next = next.copyWith(model: model as String?);
  }
  if (!identical(maxTokens, _sentinel)) {
    next = next.copyWith(budgetTokens: maxTokens as int?);
  }
  return next;
}

WorkflowStepExecution? _copyWorkflowStepExecution(
  WorkflowStepExecution? current, {
  required Object? workflowRunId,
  required Object? stepIndex,
}) {
  if (current == null) return null;
  var next = current;
  if (!identical(workflowRunId, _sentinel)) {
    next = next.copyWith(workflowRunId: workflowRunId as String?);
  }
  if (!identical(stepIndex, _sentinel)) {
    next = next.copyWith(stepIndex: stepIndex as int?);
  }
  return next;
}

AgentExecution? _agentExecutionFromJson(Map<String, dynamic> json) {
  final nested = json['agentExecution'];
  if (nested is Map<String, dynamic>) {
    return AgentExecution.fromJson(nested);
  }
  return null;
}

WorkflowStepExecution? _workflowStepExecutionFromJson(Map<String, dynamic> json) {
  final nested = json['workflowStepExecution'];
  if (nested is Map<String, dynamic>) {
    return WorkflowStepExecution.fromJson(nested);
  }
  return null;
}

TaskStatus _parseStatus(Object? value) {
  if (value == null) {
    throw const FormatException('Task JSON must include a non-null status.');
  }
  return TaskStatus.values.byName(value as String);
}

DateTime? _parseDateTime(Object? value) => value == null ? null : DateTime.parse(value as String);

Map<String, dynamic> _jsonMapOrEmpty(Object? value) => value == null ? <String, dynamic>{} : _jsonMapOrNull(value)!;

Map<String, dynamic>? _jsonMapOrNull(Object? value) {
  if (value == null) return null;
  return Map<String, dynamic>.from(value as Map);
}

Map<String, dynamic> _freezeJsonMap(Map<String, dynamic> source) =>
    Map.unmodifiable(source.map((key, value) => MapEntry(key, _freezeJsonValue(value))));

Object? _freezeJsonValue(Object? value) {
  if (value is Map) {
    return Map.unmodifiable(value.map((key, nestedValue) => MapEntry(key as String, _freezeJsonValue(nestedValue))));
  }
  if (value is List) {
    return List.unmodifiable(value.map(_freezeJsonValue));
  }
  return value;
}

Map<String, dynamic> _mutableJsonMap(Map<String, dynamic> source) =>
    source.map((key, value) => MapEntry(key, _mutableJsonValue(value)));

Object? _mutableJsonValue(Object? value) {
  if (value is Map) {
    return value.map((key, nestedValue) => MapEntry(key as String, _mutableJsonValue(nestedValue)));
  }
  if (value is List) {
    return value.map(_mutableJsonValue).toList(growable: true);
  }
  return value;
}
