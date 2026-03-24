/// Per-tool-call record captured from harness stream events.
class ToolCallRecord {
  final String name;
  final bool success;
  final int durationMs;
  final String? errorType;
  final String? context;

  const ToolCallRecord({
    required this.name,
    required this.success,
    required this.durationMs,
    this.errorType,
    this.context,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'success': success,
    'durationMs': durationMs,
    if (errorType != null) 'errorType': errorType,
    if (context != null) 'context': context,
  };

  factory ToolCallRecord.fromJson(Map<String, dynamic> json) => ToolCallRecord(
    name: json['name'] as String,
    success: json['success'] as bool,
    durationMs: json['durationMs'] as int,
    errorType: json['errorType'] as String?,
    context: json['context'] as String?,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ToolCallRecord &&
          other.name == name &&
          other.success == success &&
          other.durationMs == durationMs &&
          other.errorType == errorType &&
          other.context == context;

  @override
  int get hashCode => Object.hash(name, success, durationMs, errorType, context);

  @override
  String toString() =>
      'ToolCallRecord(name: $name, success: $success, durationMs: $durationMs, errorType: $errorType, context: $context)';
}
