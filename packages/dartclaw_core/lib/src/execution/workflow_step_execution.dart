import 'dart:convert';

import 'package:meta/meta.dart';

/// Immutable workflow-specific execution record linked to a task + agent execution.
@immutable
final class WorkflowStepExecution {
  /// Task row that owns this workflow step execution.
  final String taskId;

  /// Shared agent execution row referenced by the task and workflow step.
  final String agentExecutionId;

  /// Workflow run that spawned this step.
  final String workflowRunId;

  /// Zero-based authored step index within the workflow run.
  final int stepIndex;

  /// Authored workflow step identifier.
  final String stepId;

  /// Authored workflow step type, when recorded.
  final String? stepType;

  /// Serialized workflow git snapshot.
  final String? gitJson;

  /// Provider-side session/thread identifier captured during one-shot execution.
  final String? providerSessionId;

  /// Serialized structured-output schema.
  final String? structuredSchemaJson;

  /// Serialized structured-output payload.
  final String? structuredOutputJson;

  /// Serialized follow-up prompts for one-shot execution.
  final String? followUpPromptsJson;

  /// Optional external artifact mount configuration.
  final String? externalArtifactMount;

  /// Zero-based map iteration index for foreach/map fan-out steps.
  final int? mapIterationIndex;

  /// Total iteration count for foreach/map fan-out steps.
  final int? mapIterationTotal;

  /// Serialized per-step token breakdown.
  final String? stepTokenBreakdownJson;

  const WorkflowStepExecution({
    required this.taskId,
    required this.agentExecutionId,
    required this.workflowRunId,
    required this.stepIndex,
    required this.stepId,
    this.stepType,
    this.gitJson,
    this.providerSessionId,
    this.structuredSchemaJson,
    this.structuredOutputJson,
    this.followUpPromptsJson,
    this.externalArtifactMount,
    this.mapIterationIndex,
    this.mapIterationTotal,
    this.stepTokenBreakdownJson,
  });

  WorkflowStepExecution copyWith({
    String? taskId,
    String? agentExecutionId,
    String? workflowRunId,
    int? stepIndex,
    String? stepId,
    Object? stepType = _sentinel,
    Object? gitJson = _sentinel,
    Object? providerSessionId = _sentinel,
    Object? structuredSchemaJson = _sentinel,
    Object? structuredOutputJson = _sentinel,
    Object? followUpPromptsJson = _sentinel,
    Object? externalArtifactMount = _sentinel,
    Object? mapIterationIndex = _sentinel,
    Object? mapIterationTotal = _sentinel,
    Object? stepTokenBreakdownJson = _sentinel,
  }) => WorkflowStepExecution(
    taskId: taskId ?? this.taskId,
    agentExecutionId: agentExecutionId ?? this.agentExecutionId,
    workflowRunId: workflowRunId ?? this.workflowRunId,
    stepIndex: stepIndex ?? this.stepIndex,
    stepId: stepId ?? this.stepId,
    stepType: identical(stepType, _sentinel) ? this.stepType : stepType as String?,
    gitJson: identical(gitJson, _sentinel) ? this.gitJson : gitJson as String?,
    providerSessionId: identical(providerSessionId, _sentinel) ? this.providerSessionId : providerSessionId as String?,
    structuredSchemaJson: identical(structuredSchemaJson, _sentinel)
        ? this.structuredSchemaJson
        : structuredSchemaJson as String?,
    structuredOutputJson: identical(structuredOutputJson, _sentinel)
        ? this.structuredOutputJson
        : structuredOutputJson as String?,
    followUpPromptsJson: identical(followUpPromptsJson, _sentinel)
        ? this.followUpPromptsJson
        : followUpPromptsJson as String?,
    externalArtifactMount: identical(externalArtifactMount, _sentinel)
        ? this.externalArtifactMount
        : externalArtifactMount as String?,
    mapIterationIndex: identical(mapIterationIndex, _sentinel) ? this.mapIterationIndex : mapIterationIndex as int?,
    mapIterationTotal: identical(mapIterationTotal, _sentinel) ? this.mapIterationTotal : mapIterationTotal as int?,
    stepTokenBreakdownJson: identical(stepTokenBreakdownJson, _sentinel)
        ? this.stepTokenBreakdownJson
        : stepTokenBreakdownJson as String?,
  );

  Map<String, dynamic> toJson() => {
    'taskId': taskId,
    'agentExecutionId': agentExecutionId,
    'workflowRunId': workflowRunId,
    'stepIndex': stepIndex,
    'stepId': stepId,
    if (stepType != null) 'stepType': stepType,
    if (gitJson != null) 'gitJson': _decodeJsonString(gitJson!),
    if (providerSessionId != null) 'providerSessionId': providerSessionId,
    if (structuredSchemaJson != null) 'structuredSchemaJson': _decodeJsonString(structuredSchemaJson!),
    if (structuredOutputJson != null) 'structuredOutputJson': _decodeJsonString(structuredOutputJson!),
    if (followUpPromptsJson != null) 'followUpPromptsJson': _decodeJsonString(followUpPromptsJson!),
    if (externalArtifactMount != null) 'externalArtifactMount': _decodeJsonString(externalArtifactMount!),
    if (mapIterationIndex != null) 'mapIterationIndex': mapIterationIndex,
    if (mapIterationTotal != null) 'mapIterationTotal': mapIterationTotal,
    if (stepTokenBreakdownJson != null) 'stepTokenBreakdownJson': _decodeJsonString(stepTokenBreakdownJson!),
  };

  factory WorkflowStepExecution.fromJson(Map<String, dynamic> json) => WorkflowStepExecution(
    taskId: json['taskId'] as String,
    agentExecutionId: json['agentExecutionId'] as String,
    workflowRunId: json['workflowRunId'] as String,
    stepIndex: (json['stepIndex'] as num).toInt(),
    stepId: json['stepId'] as String,
    stepType: json['stepType'] as String?,
    gitJson: _encodeJsonValue(json['gitJson']),
    providerSessionId: json['providerSessionId'] as String?,
    structuredSchemaJson: _encodeJsonValue(json['structuredSchemaJson']),
    structuredOutputJson: _encodeJsonValue(json['structuredOutputJson']),
    followUpPromptsJson: _encodeJsonValue(json['followUpPromptsJson']),
    externalArtifactMount: _encodeJsonValue(json['externalArtifactMount']),
    mapIterationIndex: (json['mapIterationIndex'] as num?)?.toInt(),
    mapIterationTotal: (json['mapIterationTotal'] as num?)?.toInt(),
    stepTokenBreakdownJson: _encodeJsonValue(json['stepTokenBreakdownJson']),
  );

  Map<String, dynamic>? get git => _decodeJsonMap(gitJson);
  Map<String, dynamic>? get structuredSchema => _decodeJsonMap(structuredSchemaJson);
  Map<String, dynamic>? get structuredOutput => _decodeJsonMap(structuredOutputJson);
  Map<String, dynamic>? get externalArtifactMountConfig => _decodeJsonMap(externalArtifactMount);
  List<String> get followUpPrompts => _decodeJsonList(followUpPromptsJson);
  Map<String, dynamic>? get stepTokenBreakdown => _decodeJsonMap(stepTokenBreakdownJson);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WorkflowStepExecution &&
          other.taskId == taskId &&
          other.agentExecutionId == agentExecutionId &&
          other.workflowRunId == workflowRunId &&
          other.stepIndex == stepIndex &&
          other.stepId == stepId &&
          other.stepType == stepType &&
          other.gitJson == gitJson &&
          other.providerSessionId == providerSessionId &&
          other.structuredSchemaJson == structuredSchemaJson &&
          other.structuredOutputJson == structuredOutputJson &&
          other.followUpPromptsJson == followUpPromptsJson &&
          other.externalArtifactMount == externalArtifactMount &&
          other.mapIterationIndex == mapIterationIndex &&
          other.mapIterationTotal == mapIterationTotal &&
          other.stepTokenBreakdownJson == stepTokenBreakdownJson;

  @override
  int get hashCode => Object.hash(
    taskId,
    agentExecutionId,
    workflowRunId,
    stepIndex,
    stepId,
    stepType,
    gitJson,
    providerSessionId,
    structuredSchemaJson,
    structuredOutputJson,
    followUpPromptsJson,
    externalArtifactMount,
    mapIterationIndex,
    mapIterationTotal,
    stepTokenBreakdownJson,
  );

  static String? _encodeJsonValue(Object? value) => value == null ? null : jsonEncode(value);

  static Object? _decodeJsonString(String value) => jsonDecode(value);

  static Map<String, dynamic>? _decodeJsonMap(String? value) {
    if (value == null) return null;
    final decoded = jsonDecode(value);
    if (decoded is! Map) return null;
    return decoded.map((key, nestedValue) => MapEntry(key.toString(), nestedValue));
  }

  static List<String> _decodeJsonList(String? value) {
    if (value == null) return const <String>[];
    final decoded = jsonDecode(value);
    if (decoded is! List) return const <String>[];
    return decoded.map((item) => item.toString()).toList(growable: false);
  }
}

const Object _sentinel = Object();
