import 'dart:convert';

import 'package:meta/meta.dart';

/// Immutable runtime execution record shared across task-like surfaces.
@immutable
final class AgentExecution {
  /// Unique identifier for this execution.
  final String id;

  /// Provider session associated with this execution, when available.
  final String? sessionId;

  /// Harness provider that owns this execution.
  final String? provider;

  /// Optional model override resolved for this execution.
  final String? model;

  /// Optional workspace directory used by the execution.
  final String? workspaceDir;

  /// Optional serialized container configuration.
  final String? containerJson;

  /// Optional token budget for this execution.
  final int? budgetTokens;

  /// Optional serialized harness-specific metadata.
  final String? harnessMetaJson;

  /// Timestamp when the execution started.
  final DateTime? startedAt;

  /// Timestamp when the execution completed.
  final DateTime? completedAt;

  /// Creates an immutable agent execution record.
  const AgentExecution({
    required this.id,
    this.sessionId,
    this.provider,
    this.model,
    this.workspaceDir,
    this.containerJson,
    this.budgetTokens,
    this.harnessMetaJson,
    this.startedAt,
    this.completedAt,
  });

  /// Returns a new execution with selected fields replaced.
  AgentExecution copyWith({
    String? id,
    Object? sessionId = _sentinel,
    Object? provider = _sentinel,
    Object? model = _sentinel,
    Object? workspaceDir = _sentinel,
    Object? containerJson = _sentinel,
    Object? budgetTokens = _sentinel,
    Object? harnessMetaJson = _sentinel,
    Object? startedAt = _sentinel,
    Object? completedAt = _sentinel,
  }) => AgentExecution(
    id: id ?? this.id,
    sessionId: identical(sessionId, _sentinel) ? this.sessionId : sessionId as String?,
    provider: identical(provider, _sentinel) ? this.provider : provider as String?,
    model: identical(model, _sentinel) ? this.model : model as String?,
    workspaceDir: identical(workspaceDir, _sentinel) ? this.workspaceDir : workspaceDir as String?,
    containerJson: identical(containerJson, _sentinel) ? this.containerJson : containerJson as String?,
    budgetTokens: identical(budgetTokens, _sentinel) ? this.budgetTokens : budgetTokens as int?,
    harnessMetaJson: identical(harnessMetaJson, _sentinel) ? this.harnessMetaJson : harnessMetaJson as String?,
    startedAt: identical(startedAt, _sentinel) ? this.startedAt : startedAt as DateTime?,
    completedAt: identical(completedAt, _sentinel) ? this.completedAt : completedAt as DateTime?,
  );

  /// Serializes this execution to JSON.
  Map<String, dynamic> toJson() => {
    'id': id,
    if (provider != null) 'provider': provider,
    if (sessionId != null) 'sessionId': sessionId,
    if (model != null) 'model': model,
    if (workspaceDir != null) 'workspaceDir': workspaceDir,
    if (containerJson != null) 'containerJson': _decodeJsonString(containerJson!),
    if (budgetTokens != null) 'budgetTokens': budgetTokens,
    if (harnessMetaJson != null) 'harnessMetaJson': _decodeJsonString(harnessMetaJson!),
    if (startedAt != null) 'startedAt': startedAt!.toIso8601String(),
    if (completedAt != null) 'completedAt': completedAt!.toIso8601String(),
  };

  /// Deserializes an execution from persisted JSON.
  factory AgentExecution.fromJson(Map<String, dynamic> json) => AgentExecution(
    id: json['id'] as String,
    sessionId: json['sessionId'] as String?,
    provider: json['provider'] as String?,
    model: json['model'] as String?,
    workspaceDir: json['workspaceDir'] as String?,
    containerJson: _encodeJsonValue(json['containerJson']),
    budgetTokens: (json['budgetTokens'] as num?)?.toInt(),
    harnessMetaJson: _encodeJsonValue(json['harnessMetaJson']),
    startedAt: _parseDateTime(json['startedAt']),
    completedAt: _parseDateTime(json['completedAt']),
  );

  @override
  String toString() =>
      'AgentExecution(id: $id, provider: $provider, sessionId: $sessionId, '
      'startedAt: $startedAt, completedAt: $completedAt)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentExecution &&
          other.id == id &&
          other.sessionId == sessionId &&
          other.provider == provider &&
          other.model == model &&
          other.workspaceDir == workspaceDir &&
          other.containerJson == containerJson &&
          other.budgetTokens == budgetTokens &&
          other.harnessMetaJson == harnessMetaJson &&
          other.startedAt == startedAt &&
          other.completedAt == completedAt;

  @override
  int get hashCode => Object.hash(
    id,
    sessionId,
    provider,
    model,
    workspaceDir,
    containerJson,
    budgetTokens,
    harnessMetaJson,
    startedAt,
    completedAt,
  );

  static String? _encodeJsonValue(Object? value) => value == null ? null : jsonEncode(value);

  static Object? _decodeJsonString(String value) => jsonDecode(value);

  static DateTime? _parseDateTime(Object? value) => value == null ? null : DateTime.parse(value as String);
}

const Object _sentinel = Object();
