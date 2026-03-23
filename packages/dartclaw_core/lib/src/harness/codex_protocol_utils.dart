import 'dart:convert';

Map<String, dynamic>? codexMapValue(Object? value) {
  if (value is Map<String, dynamic>) {
    return value;
  }
  if (value is Map) {
    return Map<String, dynamic>.from(value);
  }
  return null;
}

String codexStringifyMessageContent(Object? content) {
  if (content is String) {
    return content;
  }
  if (content is List && content.isNotEmpty) {
    return content.map((item) => item.toString()).join('\n');
  }
  return content?.toString() ?? '';
}

/// Extracts a [String] from a dynamic value, stringifying numbers and bools.
String? codexStringValue(Object? value) {
  return switch (value) {
    String() => value,
    num() || bool() => '$value',
    _ => null,
  };
}

/// Extracts an [int] from a dynamic value, parsing strings.
int? codexIntValue(Object? value) {
  return switch (value) {
    int() => value,
    num() => value.toInt(),
    String() => int.tryParse(value),
    _ => null,
  };
}

/// Decodes a single JSON line into a [Map], or returns `null`.
Map<String, dynamic>? codexDecodeJsonObject(String line) {
  try {
    return codexMapValue(jsonDecode(line));
  } on FormatException {
    return null;
  }
}
