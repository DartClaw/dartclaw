/// Typed YAML field helpers for the config parser.
///
/// Each function encapsulates the "type-check + warn-and-ignore-and-return-default"
/// pattern used throughout [config_parser.dart]. The warn message format is
/// byte-equivalent to the inline messages they replace, so log-asserting tests
/// remain green without modification.
///
/// These are internal parser helpers — not exported from the public barrel.
library;

/// Returns the [key] value from [yaml] as a [String], or [defaultValue] on
/// mismatch. Appends a warning to [warns] if the value is present but not a
/// [String].
String? readString(String key, Map<dynamic, dynamic> yaml, List<String> warns, {String? defaultValue}) {
  final raw = yaml[key];
  if (raw == null) return defaultValue;
  if (raw is String) return raw;
  warns.add('Invalid type for $key: "${raw.runtimeType}" — using ${defaultValue == null ? 'defaults' : 'default'}');
  return defaultValue;
}

/// Returns the [key] value from [yaml] as an [int], or [defaultValue] on
/// mismatch. Appends a warning to [warns] if the value is present but not an
/// [int].
int? readInt(String key, Map<dynamic, dynamic> yaml, List<String> warns, {int? defaultValue}) {
  final raw = yaml[key];
  if (raw == null) return defaultValue;
  if (raw is int) return raw;
  warns.add('Invalid type for $key: "${raw.runtimeType}" — using ${defaultValue == null ? 'defaults' : 'default'}');
  return defaultValue;
}

/// Returns the [key] value from [yaml] as a [bool], or [defaultValue] on
/// mismatch. Appends a warning to [warns] if the value is present but not a
/// [bool].
bool? readBool(String key, Map<dynamic, dynamic> yaml, List<String> warns, {bool? defaultValue}) {
  final raw = yaml[key];
  if (raw == null) return defaultValue;
  if (raw is bool) return raw;
  warns.add('Invalid type for $key: "${raw.runtimeType}" — using ${defaultValue == null ? 'defaults' : 'default'}');
  return defaultValue;
}

/// Returns the [key] value from [yaml] as a [Map<String, dynamic>], or
/// [defaultValue] on mismatch. Handles YAML [Map<dynamic,dynamic>] → normalised
/// [Map<String,dynamic>] conversion centrally.
Map<String, dynamic>? readMap(
  String key,
  Map<dynamic, dynamic> yaml,
  List<String> warns, {
  Map<String, dynamic>? defaultValue,
}) {
  final raw = yaml[key];
  if (raw == null) return defaultValue;
  if (raw is Map) return Map<String, dynamic>.from(raw);
  warns.add('Invalid type for $key: "${raw.runtimeType}" — using ${defaultValue == null ? 'defaults' : 'default'}');
  return defaultValue;
}

/// Returns the [key] value from [yaml] as a [List<String>], or [defaultValue]
/// on mismatch. Appends a warning to [warns] if the value is present but not a
/// [List].
List<String>? readStringList(String key, Map<dynamic, dynamic> yaml, List<String> warns, {List<String>? defaultValue}) {
  final raw = yaml[key];
  if (raw == null) return defaultValue;
  if (raw is List) return raw.whereType<String>().toList();
  warns.add('Invalid type for $key: "${raw.runtimeType}" — using ${defaultValue == null ? 'defaults' : 'default'}');
  return defaultValue;
}

/// Generic typed reader. Returns the [key] value from [yaml] cast to [T], or
/// [defaultValue] on mismatch. Prefer the typed helpers above for concrete
/// types; use this for unusual cases.
T? readField<T>(String key, Map<dynamic, dynamic> yaml, List<String> warns, {T? defaultValue}) {
  final raw = yaml[key];
  if (raw == null) return defaultValue;
  if (raw is T) return raw;
  warns.add('Invalid type for $key: "${raw.runtimeType}" — using ${defaultValue == null ? 'defaults' : 'default'}');
  return defaultValue;
}
