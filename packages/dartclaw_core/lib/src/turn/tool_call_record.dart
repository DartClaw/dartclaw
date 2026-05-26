/// Per-tool-call record captured from harness stream events.
class ToolCallRecord {
  /// Canonical tool name.
  final String name;

  /// Whether the tool invocation completed successfully.
  final bool success;

  /// Wall-clock duration of the tool invocation in milliseconds.
  final int durationMs;

  /// Error type label when [success] is false.
  final String? errorType;

  /// Optional short context string (target path, command, etc.).
  final String? context;

  /// Creates a [ToolCallRecord] value.
  const ToolCallRecord({
    required this.name,
    required this.success,
    required this.durationMs,
    this.errorType,
    this.context,
  });

  /// Serializes this record to a JSON-ready map.
  Map<String, dynamic> toJson() => {
    'name': name,
    'success': success,
    'durationMs': durationMs,
    if (errorType != null) 'errorType': errorType,
    if (context != null) 'context': context,
  };

  /// Reconstructs a [ToolCallRecord] from its JSON representation.
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
