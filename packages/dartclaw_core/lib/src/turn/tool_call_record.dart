import 'package:collection/collection.dart';

/// Per-tool-call record captured from harness stream events.
class ToolCallRecord {
  /// Stable provider invocation identity when the provider supplied one.
  final String? id;

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

  /// Redacted display arguments retained for conversation history.
  final String? arguments;

  /// Redacted display result retained for conversation history.
  final String? result;

  /// Whether [arguments] or [result] was cut to fit its display budget.
  ///
  /// The producer that performs the cut owns this; a consumer must never
  /// re-derive it from the truncation marker's text.
  final bool isTruncated;

  /// Exact returned memory source locators, retained in first-return order.
  final List<String> sourceLocators;

  /// Creates a record with a defensive copy of [sourceLocators].
  new({
    this.id,
    required this.name,
    required this.success,
    required this.durationMs,
    this.errorType,
    this.context,
    this.arguments,
    this.result,
    this.isTruncated = false,
    List<String> sourceLocators = const [],
  }) : sourceLocators = List.unmodifiable(sourceLocators);

  /// Serializes this record to a JSON-ready map.
  Map<String, dynamic> toJson() => {
    if (id != null) 'id': id,
    'name': name,
    'success': success,
    'durationMs': durationMs,
    'sourceLocators': sourceLocators,
    if (errorType != null) 'errorType': errorType,
    if (context != null) 'context': context,
    if (arguments != null) 'arguments': arguments,
    if (result != null) 'result': result,
    if (isTruncated) 'isTruncated': true,
  };

  /// Reconstructs a [ToolCallRecord] from its JSON representation.
  factory fromJson(Map<String, dynamic> json) => ToolCallRecord(
    id: json['id'] as String?,
    name: json['name'] as String,
    success: json['success'] as bool,
    durationMs: json['durationMs'] as int,
    errorType: json['errorType'] as String?,
    context: json['context'] as String?,
    arguments: json['arguments'] as String?,
    result: json['result'] as String?,
    isTruncated: json['isTruncated'] == true,
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
          other.id == id &&
          other.success == success &&
          other.durationMs == durationMs &&
          other.errorType == errorType &&
          other.context == context &&
          other.arguments == arguments &&
          other.result == result &&
          other.isTruncated == isTruncated &&
          const ListEquality<String>().equals(other.sourceLocators, sourceLocators);

  @override
  int get hashCode => Object.hash(
    id,
    name,
    success,
    durationMs,
    errorType,
    context,
    arguments,
    result,
    isTruncated,
    Object.hashAll(sourceLocators),
  );

  @override
  String toString() =>
      'ToolCallRecord(name: $name, success: $success, durationMs: $durationMs, errorType: $errorType, context: $context)';
}
