import 'task_status.dart';
import 'task_type.dart';

/// Immutable task value object for orchestrated work.
class Task {
  final String id;
  final String title;
  final String description;
  final TaskType type;
  final TaskStatus status;
  final String? goalId;
  final String? acceptanceCriteria;
  final String? sessionId;
  final Map<String, dynamic> configJson;
  final Map<String, dynamic>? worktreeJson;
  final DateTime createdAt;
  final DateTime? startedAt;
  final DateTime? completedAt;

  Task({
    required this.id,
    required this.title,
    required this.description,
    required this.type,
    this.status = TaskStatus.draft,
    this.goalId,
    this.acceptanceCriteria,
    this.sessionId,
    Map<String, dynamic>? configJson,
    Map<String, dynamic>? worktreeJson,
    required this.createdAt,
    this.startedAt,
    this.completedAt,
  }) : configJson = _freezeJsonMap(configJson ?? const {}),
       worktreeJson = worktreeJson == null ? null : _freezeJsonMap(worktreeJson);

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
  );

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
    } else if ((status == TaskStatus.review || status == TaskStatus.interrupted) && newStatus == TaskStatus.queued) {
      nextCompletedAt = null;
    }

    return copyWith(
      status: newStatus,
      configJson: nextConfigJson,
      startedAt: nextStartedAt,
      completedAt: nextCompletedAt,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'description': description,
    'type': type.name,
    'status': status.name,
    if (goalId != null) 'goalId': goalId,
    if (acceptanceCriteria != null) 'acceptanceCriteria': acceptanceCriteria,
    if (sessionId != null) 'sessionId': sessionId,
    'configJson': _mutableJsonMap(configJson),
    if (worktreeJson != null) 'worktreeJson': _mutableJsonMap(worktreeJson!),
    'createdAt': createdAt.toIso8601String(),
    if (startedAt != null) 'startedAt': startedAt!.toIso8601String(),
    if (completedAt != null) 'completedAt': completedAt!.toIso8601String(),
  };

  factory Task.fromJson(Map<String, dynamic> json) => Task(
    id: json['id'] as String,
    title: json['title'] as String,
    description: json['description'] as String,
    type: TaskType.values.byName(json['type'] as String),
    status: _parseStatus(json['status']),
    goalId: json['goalId'] as String?,
    acceptanceCriteria: json['acceptanceCriteria'] as String?,
    sessionId: json['sessionId'] as String?,
    configJson: _jsonMapOrEmpty(json['configJson']),
    worktreeJson: _jsonMapOrNull(json['worktreeJson']),
    createdAt: DateTime.parse(json['createdAt'] as String),
    startedAt: _parseDateTime(json['startedAt']),
    completedAt: _parseDateTime(json['completedAt']),
  );
}

const _sentinel = Object();

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
