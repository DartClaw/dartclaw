import 'package:collection/collection.dart';

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

  /// Exact returned memory source locators, retained in first-return order.
  final List<String> sourceLocators;

  /// Creates a record with a defensive copy of [sourceLocators].
  new({
    required this.name,
    required this.success,
    required this.durationMs,
    this.errorType,
    this.context,
    List<String> sourceLocators = const [],
  }) : sourceLocators = List.unmodifiable(sourceLocators);

  /// Serializes this record to a JSON-ready map.
  Map<String, dynamic> toJson() => {
    'name': name,
    'success': success,
    'durationMs': durationMs,
    'sourceLocators': sourceLocators,
    if (errorType != null) 'errorType': errorType,
    if (context != null) 'context': context,
  };

  /// Reconstructs a [ToolCallRecord] from its JSON representation.
  factory fromJson(Map<String, dynamic> json) => ToolCallRecord(
    name: json['name'] as String,
    success: json['success'] as bool,
    durationMs: json['durationMs'] as int,
    errorType: json['errorType'] as String?,
    context: json['context'] as String?,
    sourceLocators: switch (json['sourceLocators']) {
      List<dynamic> values when values.every((value) => value is String && value.trim().isNotEmpty) =>
        values.cast<String>(),
      _ => const [],
    },
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ToolCallRecord &&
          other.name == name &&
          other.success == success &&
          other.durationMs == durationMs &&
          other.errorType == errorType &&
          other.context == context &&
          const ListEquality<String>().equals(other.sourceLocators, sourceLocators);

  @override
  int get hashCode => Object.hash(name, success, durationMs, errorType, context, Object.hashAll(sourceLocators));

  @override
  String toString() =>
      'ToolCallRecord(name: $name, success: $success, durationMs: $durationMs, errorType: $errorType, context: $context)';
}
