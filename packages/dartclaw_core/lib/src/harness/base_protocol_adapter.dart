import 'dart:convert';

import 'package:logging/logging.dart';

import 'canonical_tool.dart';
import 'protocol_adapter.dart';

/// Shared helpers for provider protocol adapters.
abstract class BaseProtocolAdapter implements ProtocolAdapter {
  const BaseProtocolAdapter();
}

Map<String, dynamic>? mapValue(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return null;
}

String stringifyMessageContent(Object? content) {
  if (content is String) {
    return content;
  }
  if (content is List && content.isNotEmpty) {
    return content.map((item) => item.toString()).join('\n');
  }
  return content?.toString() ?? '';
}

/// Extracts a [String] from a dynamic value, stringifying numbers and bools.
String? stringValue(Object? value) {
  return switch (value) {
    String() => value,
    num() || bool() => '$value',
    _ => null,
  };
}

List<dynamic>? listValue(Object? value) {
  if (value is List<dynamic>) return value;
  if (value is List) return value.cast<dynamic>();
  return null;
}

/// Extracts an [int] from a dynamic value, parsing strings.
int? intValue(Object? value) {
  return switch (value) {
    int() => value,
    num() => value.toInt(),
    String() => int.tryParse(value),
    _ => null,
  };
}

/// Decodes a single JSON line into a [Map], or returns `null`.
Map<String, dynamic>? decodeJsonObject(String line) {
  if (line.trim().isEmpty) {
    return null;
  }
  try {
    return mapValue(jsonDecode(line));
  } on FormatException {
    return null;
  }
}

/// Formats an object for protocol payloads and log values.
String? stringifyValue(Object? value) {
  if (value == null) return null;
  if (value is String) return value;
  try {
    return jsonEncode(value);
  } on JsonUnsupportedObjectError {
    return '$value';
  }
}

CanonicalTool? codexMapToolName(String providerToolName, {String? kind}) {
  return switch (providerToolName) {
    'command_execution' => CanonicalTool.shell,
    'file_change' => switch (kind) {
      'update' || 'modify' => CanonicalTool.fileEdit,
      _ => CanonicalTool.fileWrite,
    },
    'mcp_tool_call' => CanonicalTool.mcpCall,
    _ => null,
  };
}

/// Returns a compact tool-call summary from an error object.
String? codexErrorSummary(Object? error) {
  final map = mapValue(error);
  if (map == null) return stringifyValue(error);
  return stringValue(map['message']) ?? stringifyValue(map);
}

/// Extracts a non-empty file-change item from a payload.
Map<String, dynamic>? codexPrimaryFileChange(Map<String, dynamic> item) {
  final changes = listValue(item['changes']);
  if (changes == null || changes.isEmpty) return null;

  for (final change in changes) {
    final changeMap = mapValue(change);
    if (changeMap != null) return changeMap;
  }

  return null;
}

/// Strips control keys from an unrecognized Codex item.
Map<String, dynamic> codexUnknownItemInput(Map<String, dynamic> item) {
  final input = <String, dynamic>{};
  for (final entry in item.entries) {
    if (entry.key == 'id' || entry.key == 'type') {
      continue;
    }
    input[entry.key] = entry.value;
  }
  return input;
}

/// Logs an unmapped tool name when a logger is available.
CanonicalTool? warnOnUnmappedToolName(
  Logger? log,
  String providerName,
  String providerToolName,
  CanonicalTool? canonicalTool,
) {
  if (canonicalTool == null) {
    log?.warning('Unmapped $providerName tool name: $providerToolName');
  }
  return canonicalTool;
}
