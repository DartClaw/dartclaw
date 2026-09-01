/// Returns the first integer found in [values] for any of [keys].
int? firstIntegerForKeys(Map<String, dynamic> values, Iterable<String> keys) {
  for (final key in keys) {
    final count = asInteger(values[key]);
    if (count != null) return count;
  }
  return null;
}

/// Coerces [value] to an integer when safe to do so.
///
/// The schema-enforced integer a review emitted is the count; nothing here
/// derives one from a verdict's findings list or any other nested shape.
int? asInteger(Object? value) {
  if (value is int) return value;
  if (value is num && value.isFinite && value.roundToDouble() == value) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}
