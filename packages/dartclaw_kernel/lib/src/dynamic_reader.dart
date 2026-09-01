/// Recursively normalizes a [Map<dynamic, dynamic>] to [Map<String, dynamic>].
///
/// - Non-string keys are coerced via [Object.toString].
/// - Nested [Map<dynamic, dynamic>] values are recursively normalized.
/// - [List] elements that are [Map<dynamic, dynamic>] are recursively normalized.
/// - All other values pass through unchanged.
Map<String, dynamic> normalizeDynamicMap(Map<dynamic, dynamic> source) {
  return source.map((key, value) {
    final normalizedValue = switch (value) {
      final Map<dynamic, dynamic> nested => normalizeDynamicMap(nested),
      final List<dynamic> list =>
        list.map((item) => item is Map<dynamic, dynamic> ? normalizeDynamicMap(item) : item).toList(growable: false),
      _ => value,
    };
    return MapEntry(key.toString(), normalizedValue);
  });
}
