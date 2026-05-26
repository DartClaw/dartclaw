Map<String, dynamic>? asStringKeyedMap(Object? value) {
  return switch (value) {
    final Map<String, dynamic> typed => Map<String, dynamic>.from(typed),
    final Map<dynamic, dynamic> dynamicMap => dynamicMap.map((key, value) => MapEntry('$key', value)),
    _ => null,
  };
}

String? trimmedString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

String stringValue(Object? value) => value is String ? value : '';
