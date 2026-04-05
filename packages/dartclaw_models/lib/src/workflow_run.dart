const _sentinel = Object();

/// Lifecycle states for a workflow execution.
enum WorkflowRunStatus {
  /// Workflow created but not yet started.
  pending,

  /// Workflow is actively executing steps.
  running,

  /// Workflow paused due to step failure, gate failure, or user intervention.
  paused,

  /// All steps completed successfully.
  completed,

  /// Workflow failed irrecoverably.
  failed,

  /// Workflow was cancelled by user.
  cancelled;

  /// Whether this is a terminal state.
  bool get terminal => switch (this) {
    WorkflowRunStatus.completed ||
    WorkflowRunStatus.failed ||
    WorkflowRunStatus.cancelled =>
      true,
    _ => false,
  };
}

/// Runtime representation of a workflow execution.
class WorkflowRun {
  /// Unique identifier for this run.
  final String id;

  /// Name of the workflow definition being executed.
  final String definitionName;

  /// Current lifecycle status.
  final WorkflowRunStatus status;

  /// Serialized context snapshot (lightweight — full context on disk).
  final Map<String, dynamic> contextJson;

  /// Variable bindings provided at workflow start.
  final Map<String, String> variablesJson;

  /// When this run was created.
  final DateTime startedAt;

  /// When this run was last updated.
  final DateTime updatedAt;

  /// When this run reached a terminal state.
  final DateTime? completedAt;

  /// Error message when status is paused or failed.
  final String? errorMessage;

  /// Cumulative tokens consumed across all steps.
  final int totalTokens;

  /// Index of the currently executing or next step.
  final int currentStepIndex;

  /// Serialized workflow definition snapshot (definition at start time).
  final Map<String, dynamic> definitionJson;

  /// Current loop ID for crash recovery (S04).
  final String? currentLoopId;

  /// Current loop iteration for crash recovery (S04).
  final int? currentLoopIteration;

  const WorkflowRun({
    required this.id,
    required this.definitionName,
    this.status = WorkflowRunStatus.pending,
    this.contextJson = const {},
    this.variablesJson = const {},
    required this.startedAt,
    required this.updatedAt,
    this.completedAt,
    this.errorMessage,
    this.totalTokens = 0,
    this.currentStepIndex = 0,
    this.definitionJson = const {},
    this.currentLoopId,
    this.currentLoopIteration,
  });

  /// Returns a copy with selected fields replaced.
  WorkflowRun copyWith({
    String? id,
    String? definitionName,
    WorkflowRunStatus? status,
    Map<String, dynamic>? contextJson,
    Map<String, String>? variablesJson,
    DateTime? startedAt,
    DateTime? updatedAt,
    Object? completedAt = _sentinel,
    Object? errorMessage = _sentinel,
    int? totalTokens,
    int? currentStepIndex,
    Map<String, dynamic>? definitionJson,
    Object? currentLoopId = _sentinel,
    Object? currentLoopIteration = _sentinel,
  }) =>
      WorkflowRun(
        id: id ?? this.id,
        definitionName: definitionName ?? this.definitionName,
        status: status ?? this.status,
        contextJson: contextJson ?? this.contextJson,
        variablesJson: variablesJson ?? this.variablesJson,
        startedAt: startedAt ?? this.startedAt,
        updatedAt: updatedAt ?? this.updatedAt,
        completedAt: identical(completedAt, _sentinel)
            ? this.completedAt
            : completedAt as DateTime?,
        errorMessage: identical(errorMessage, _sentinel)
            ? this.errorMessage
            : errorMessage as String?,
        totalTokens: totalTokens ?? this.totalTokens,
        currentStepIndex: currentStepIndex ?? this.currentStepIndex,
        definitionJson: definitionJson ?? this.definitionJson,
        currentLoopId: identical(currentLoopId, _sentinel)
            ? this.currentLoopId
            : currentLoopId as String?,
        currentLoopIteration: identical(currentLoopIteration, _sentinel)
            ? this.currentLoopIteration
            : currentLoopIteration as int?,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'definitionName': definitionName,
    'status': status.name,
    'contextJson': Map<String, dynamic>.from(contextJson),
    'variablesJson': Map<String, String>.from(variablesJson),
    'startedAt': startedAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    if (completedAt != null) 'completedAt': completedAt!.toIso8601String(),
    if (errorMessage != null) 'errorMessage': errorMessage,
    'totalTokens': totalTokens,
    'currentStepIndex': currentStepIndex,
    'definitionJson': Map<String, dynamic>.from(definitionJson),
    if (currentLoopId != null) 'currentLoopId': currentLoopId,
    if (currentLoopIteration != null) 'currentLoopIteration': currentLoopIteration,
  };

  factory WorkflowRun.fromJson(Map<String, dynamic> json) => WorkflowRun(
    id: json['id'] as String,
    definitionName: json['definitionName'] as String,
    status: WorkflowRunStatus.values.byName(json['status'] as String),
    contextJson: _toStringDynamicMap(json['contextJson']),
    variablesJson: _toStringStringMap(json['variablesJson']),
    startedAt: DateTime.parse(json['startedAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
    completedAt: json['completedAt'] != null
        ? DateTime.parse(json['completedAt'] as String)
        : null,
    errorMessage: json['errorMessage'] as String?,
    totalTokens: (json['totalTokens'] as int?) ?? 0,
    currentStepIndex: (json['currentStepIndex'] as int?) ?? 0,
    definitionJson: _toStringDynamicMap(json['definitionJson']),
    currentLoopId: json['currentLoopId'] as String?,
    currentLoopIteration: json['currentLoopIteration'] as int?,
  );
}

Map<String, dynamic> _toStringDynamicMap(Object? value) =>
    value == null ? const {} : Map<String, dynamic>.from(value as Map);

Map<String, String> _toStringStringMap(Object? value) =>
    value == null ? const {} : Map<String, String>.from(value as Map);
