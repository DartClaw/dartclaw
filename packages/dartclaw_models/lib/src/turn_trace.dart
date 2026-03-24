import 'tool_call_record.dart';

/// A persisted record of a single agent turn.
class TurnTrace {
  final String id;
  final String sessionId;
  final String? taskId;
  final int? runnerId;
  final String? model;
  final String? provider;
  final DateTime startedAt;
  final DateTime endedAt;
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;
  final bool isError;
  final String? errorType;
  final List<ToolCallRecord> toolCalls;

  const TurnTrace({
    required this.id,
    required this.sessionId,
    this.taskId,
    this.runnerId,
    this.model,
    this.provider,
    required this.startedAt,
    required this.endedAt,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    this.isError = false,
    this.errorType,
    this.toolCalls = const [],
  });

  int get totalTokens => inputTokens + outputTokens;
  int get durationMs => endedAt.difference(startedAt).inMilliseconds;

  Map<String, dynamic> toJson() => {
    'id': id,
    'sessionId': sessionId,
    if (taskId != null) 'taskId': taskId,
    if (runnerId != null) 'runnerId': runnerId,
    if (model != null) 'model': model,
    if (provider != null) 'provider': provider,
    'startedAt': startedAt.toIso8601String(),
    'endedAt': endedAt.toIso8601String(),
    'inputTokens': inputTokens,
    'outputTokens': outputTokens,
    'cacheReadTokens': cacheReadTokens,
    'cacheWriteTokens': cacheWriteTokens,
    'isError': isError,
    if (errorType != null) 'errorType': errorType,
    'toolCalls': toolCalls.map((t) => t.toJson()).toList(),
    'totalTokens': totalTokens,
    'durationMs': durationMs,
  };

  factory TurnTrace.fromJson(Map<String, dynamic> json) => TurnTrace(
    id: json['id'] as String,
    sessionId: json['sessionId'] as String,
    taskId: json['taskId'] as String?,
    runnerId: json['runnerId'] as int?,
    model: json['model'] as String?,
    provider: json['provider'] as String?,
    startedAt: DateTime.parse(json['startedAt'] as String),
    endedAt: DateTime.parse(json['endedAt'] as String),
    inputTokens: json['inputTokens'] as int? ?? 0,
    outputTokens: json['outputTokens'] as int? ?? 0,
    cacheReadTokens: json['cacheReadTokens'] as int? ?? 0,
    cacheWriteTokens: json['cacheWriteTokens'] as int? ?? 0,
    isError: json['isError'] as bool? ?? false,
    errorType: json['errorType'] as String?,
    toolCalls:
        (json['toolCalls'] as List?)
            ?.map((e) => ToolCallRecord.fromJson(e as Map<String, dynamic>))
            .toList() ??
        const [],
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TurnTrace &&
          other.id == id &&
          other.sessionId == sessionId &&
          other.taskId == taskId &&
          other.runnerId == runnerId &&
          other.model == model &&
          other.provider == provider &&
          other.startedAt == startedAt &&
          other.endedAt == endedAt &&
          other.inputTokens == inputTokens &&
          other.outputTokens == outputTokens &&
          other.cacheReadTokens == cacheReadTokens &&
          other.cacheWriteTokens == cacheWriteTokens &&
          other.isError == isError &&
          other.errorType == errorType;

  @override
  int get hashCode => Object.hash(
    id,
    sessionId,
    taskId,
    runnerId,
    model,
    provider,
    startedAt,
    endedAt,
    inputTokens,
    outputTokens,
    cacheReadTokens,
    cacheWriteTokens,
    isError,
    errorType,
  );

  @override
  String toString() =>
      'TurnTrace(id: $id, sessionId: $sessionId, taskId: $taskId, '
      'inputTokens: $inputTokens, outputTokens: $outputTokens, isError: $isError)';
}
