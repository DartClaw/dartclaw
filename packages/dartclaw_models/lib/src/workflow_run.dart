const _sentinel = Object();

/// Node kinds that can be resumed via a persisted execution cursor.
enum WorkflowExecutionCursorNodeType { loop, map, foreach }

/// Persisted cursor for resuming workflow execution without replaying settled work.
class WorkflowExecutionCursor {
  /// Active node kind being resumed.
  final WorkflowExecutionCursorNodeType nodeType;

  /// ID of the active loop or map node.
  final String nodeId;

  /// Step index that anchors the node within the flattened step list.
  final int stepIndex;

  /// Active loop step ID when resuming a loop node.
  final String? stepId;

  /// Active loop iteration when resuming a loop node.
  final int? iteration;

  /// Total item count when resuming a map node.
  final int? totalItems;

  /// Settled map iteration indices.
  final List<int> completedIndices;

  /// Failed map iteration indices.
  final List<int> failedIndices;

  /// Cancelled map iteration indices.
  final List<int> cancelledIndices;

  /// Index-ordered map results; pending slots remain null.
  final List<dynamic> resultSlots;

  const WorkflowExecutionCursor({
    required this.nodeType,
    required this.nodeId,
    required this.stepIndex,
    this.stepId,
    this.iteration,
    this.totalItems,
    this.completedIndices = const [],
    this.failedIndices = const [],
    this.cancelledIndices = const [],
    this.resultSlots = const [],
  });

  factory WorkflowExecutionCursor.loop({
    required String loopId,
    required int stepIndex,
    required int iteration,
    String? stepId,
  }) => WorkflowExecutionCursor(
    nodeType: WorkflowExecutionCursorNodeType.loop,
    nodeId: loopId,
    stepIndex: stepIndex,
    stepId: stepId,
    iteration: iteration,
  );

  factory WorkflowExecutionCursor.map({
    required String stepId,
    required int stepIndex,
    required int totalItems,
    List<int> completedIndices = const [],
    List<int> failedIndices = const [],
    List<int> cancelledIndices = const [],
    List<dynamic> resultSlots = const [],
  }) => WorkflowExecutionCursor(
    nodeType: WorkflowExecutionCursorNodeType.map,
    nodeId: stepId,
    stepIndex: stepIndex,
    totalItems: totalItems,
    completedIndices: List<int>.from(completedIndices),
    failedIndices: List<int>.from(failedIndices),
    cancelledIndices: List<int>.from(cancelledIndices),
    resultSlots: List<dynamic>.from(resultSlots),
  );

  /// Creates a cursor for resuming a foreach/sub-pipeline node.
  factory WorkflowExecutionCursor.foreach({
    required String stepId,
    required int stepIndex,
    required int totalItems,
    List<int> completedIndices = const [],
    List<int> failedIndices = const [],
    List<int> cancelledIndices = const [],
    List<dynamic> resultSlots = const [],
  }) => WorkflowExecutionCursor(
    nodeType: WorkflowExecutionCursorNodeType.foreach,
    nodeId: stepId,
    stepIndex: stepIndex,
    totalItems: totalItems,
    completedIndices: List<int>.from(completedIndices),
    failedIndices: List<int>.from(failedIndices),
    cancelledIndices: List<int>.from(cancelledIndices),
    resultSlots: List<dynamic>.from(resultSlots),
  );

  Map<String, dynamic> toJson() => {
    'nodeType': nodeType.name,
    'nodeId': nodeId,
    'stepIndex': stepIndex,
    if (stepId != null) 'stepId': stepId,
    if (iteration != null) 'iteration': iteration,
    if (totalItems != null) 'totalItems': totalItems,
    if (completedIndices.isNotEmpty) 'completedIndices': List<int>.from(completedIndices),
    if (failedIndices.isNotEmpty) 'failedIndices': List<int>.from(failedIndices),
    if (cancelledIndices.isNotEmpty) 'cancelledIndices': List<int>.from(cancelledIndices),
    if (resultSlots.isNotEmpty) 'resultSlots': List<dynamic>.from(resultSlots),
  };

  factory WorkflowExecutionCursor.fromJson(Map<String, dynamic> json) => WorkflowExecutionCursor(
    nodeType: WorkflowExecutionCursorNodeType.values.byName(json['nodeType'] as String),
    nodeId: json['nodeId'] as String,
    stepIndex: (json['stepIndex'] as num?)?.toInt() ?? 0,
    stepId: json['stepId'] as String?,
    iteration: (json['iteration'] as num?)?.toInt(),
    totalItems: (json['totalItems'] as num?)?.toInt(),
    completedIndices: _toIntList(json['completedIndices']),
    failedIndices: _toIntList(json['failedIndices']),
    cancelledIndices: _toIntList(json['cancelledIndices']),
    resultSlots: _toDynamicList(json['resultSlots']),
  );
}

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
    WorkflowRunStatus.completed || WorkflowRunStatus.failed || WorkflowRunStatus.cancelled => true,
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

  /// Generalized execution cursor for node-oriented crash recovery.
  final WorkflowExecutionCursor? executionCursor;

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
    this.executionCursor,
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
    Object? executionCursor = _sentinel,
  }) => WorkflowRun(
    id: id ?? this.id,
    definitionName: definitionName ?? this.definitionName,
    status: status ?? this.status,
    contextJson: contextJson ?? this.contextJson,
    variablesJson: variablesJson ?? this.variablesJson,
    startedAt: startedAt ?? this.startedAt,
    updatedAt: updatedAt ?? this.updatedAt,
    completedAt: identical(completedAt, _sentinel) ? this.completedAt : completedAt as DateTime?,
    errorMessage: identical(errorMessage, _sentinel) ? this.errorMessage : errorMessage as String?,
    totalTokens: totalTokens ?? this.totalTokens,
    currentStepIndex: currentStepIndex ?? this.currentStepIndex,
    definitionJson: definitionJson ?? this.definitionJson,
    currentLoopId: identical(currentLoopId, _sentinel) ? this.currentLoopId : currentLoopId as String?,
    currentLoopIteration: identical(currentLoopIteration, _sentinel)
        ? this.currentLoopIteration
        : currentLoopIteration as int?,
    executionCursor: identical(executionCursor, _sentinel)
        ? this.executionCursor
        : executionCursor as WorkflowExecutionCursor?,
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
    if (executionCursor != null) 'executionCursor': executionCursor!.toJson(),
  };

  factory WorkflowRun.fromJson(Map<String, dynamic> json) => WorkflowRun(
    id: json['id'] as String,
    definitionName: json['definitionName'] as String,
    status: WorkflowRunStatus.values.byName(json['status'] as String),
    contextJson: _toStringDynamicMap(json['contextJson']),
    variablesJson: _toStringStringMap(json['variablesJson']),
    startedAt: DateTime.parse(json['startedAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
    completedAt: json['completedAt'] != null ? DateTime.parse(json['completedAt'] as String) : null,
    errorMessage: json['errorMessage'] as String?,
    totalTokens: (json['totalTokens'] as int?) ?? 0,
    currentStepIndex: (json['currentStepIndex'] as int?) ?? 0,
    definitionJson: _toStringDynamicMap(json['definitionJson']),
    currentLoopId: json['currentLoopId'] as String?,
    currentLoopIteration: json['currentLoopIteration'] as int?,
    executionCursor: _toExecutionCursor(json['executionCursor']),
  );
}

Map<String, dynamic> _toStringDynamicMap(Object? value) =>
    value == null ? const {} : Map<String, dynamic>.from(value as Map);

Map<String, String> _toStringStringMap(Object? value) =>
    value == null ? const {} : Map<String, String>.from(value as Map);

List<int> _toIntList(Object? value) =>
    value == null ? const [] : (value as List).map((item) => (item as num).toInt()).toList(growable: false);

List<dynamic> _toDynamicList(Object? value) => value == null ? const [] : List<dynamic>.from(value as List);

WorkflowExecutionCursor? _toExecutionCursor(Object? value) =>
    value == null ? null : WorkflowExecutionCursor.fromJson(Map<String, dynamic>.from(value as Map));
