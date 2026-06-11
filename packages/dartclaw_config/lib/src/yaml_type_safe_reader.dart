/// Typed YAML field helpers for the config parser.
///
/// Each function encapsulates the "type-check + warn-and-ignore-and-return-default"
/// pattern used throughout [config_parser.dart]. The warn message format is
/// byte-equivalent to the inline messages they replace, so log-asserting tests
/// remain green without modification.
///
/// These are exported from the public barrel so sibling packages (e.g. channel
/// config parsers) can reuse the same type-check + warn pattern.
library;

/// Returns the [key] value from [yaml] as a [String], or [defaultValue] on
/// mismatch. Appends a warning to [warns] if the value is present but not a
/// [String]. [warnKey] overrides the key shown in the warning (defaults to
/// [key]) — use it when the lookup key is bare but the message needs a prefix.
String? readString(
  String key,
  Map<dynamic, dynamic> yaml,
  List<String> warns, {
  String? defaultValue,
  String? warnKey,
}) {
  final raw = yaml[key];
  if (raw == null) return defaultValue;
  if (raw is String) return raw;
  warns.add(
    'Invalid type for ${warnKey ?? key}: "${raw.runtimeType}" — using ${defaultValue == null ? 'defaults' : 'default'}',
  );
  return defaultValue;
}

/// Returns the [key] value from [yaml] as an [int], or [defaultValue] on
/// mismatch. Appends a warning to [warns] if the value is present but not an
/// [int]. [warnKey] overrides the key shown in the warning (defaults to [key])
/// — use it when the lookup key is bare but the message needs a prefix.
int? readInt(String key, Map<dynamic, dynamic> yaml, List<String> warns, {int? defaultValue, String? warnKey}) {
  final raw = yaml[key];
  if (raw == null) return defaultValue;
  if (raw is int) return raw;
  warns.add(
    'Invalid type for ${warnKey ?? key}: "${raw.runtimeType}" — using ${defaultValue == null ? 'defaults' : 'default'}',
  );
  return defaultValue;
}

/// Returns the [key] value from [yaml] as a [bool], or [defaultValue] on
/// mismatch. Appends a warning to [warns] if the value is present but not a
/// [bool]. [warnKey] overrides the key shown in the warning (defaults to [key])
/// — use it when the lookup key is bare but the message needs a prefix.
bool? readBool(String key, Map<dynamic, dynamic> yaml, List<String> warns, {bool? defaultValue, String? warnKey}) {
  final raw = yaml[key];
  if (raw == null) return defaultValue;
  if (raw is bool) return raw;
  warns.add(
    'Invalid type for ${warnKey ?? key}: "${raw.runtimeType}" — using ${defaultValue == null ? 'defaults' : 'default'}',
  );
  return defaultValue;
}

/// Returns the [key] value from [yaml] as a [Map<String, dynamic>], or
/// [defaultValue] on mismatch. Handles YAML [Map<dynamic,dynamic>] → normalised
/// [Map<String,dynamic>] conversion centrally. [warnKey] overrides the key shown
/// in the warning (defaults to [key]) — use it when the lookup key is bare but
/// the message needs a prefix.
Map<String, dynamic>? readMap(
  String key,
  Map<dynamic, dynamic> yaml,
  List<String> warns, {
  Map<String, dynamic>? defaultValue,
  String? warnKey,
}) {
  final raw = yaml[key];
  if (raw == null) return defaultValue;
  if (raw is Map) return Map<String, dynamic>.from(raw);
  warns.add(
    'Invalid type for ${warnKey ?? key}: "${raw.runtimeType}" — using ${defaultValue == null ? 'defaults' : 'default'}',
  );
  return defaultValue;
}

/// Returns the [key] value from [yaml] as a [List<String>], or [defaultValue]
/// on mismatch. Appends a warning to [warns] if the value is present but not a
/// [List]. [warnKey] overrides the key shown in the warning (defaults to [key])
/// — use it when the lookup key is bare but the message needs a prefix.
List<String>? readStringList(
  String key,
  Map<dynamic, dynamic> yaml,
  List<String> warns, {
  List<String>? defaultValue,
  String? warnKey,
}) {
  final raw = yaml[key];
  if (raw == null) return defaultValue;
  if (raw is List) return raw.whereType<String>().toList();
  warns.add(
    'Invalid type for ${warnKey ?? key}: "${raw.runtimeType}" — using ${defaultValue == null ? 'defaults' : 'default'}',
  );
  return defaultValue;
}

/// Generic typed reader. Returns the [key] value from [yaml] cast to [T], or
/// [defaultValue] on mismatch. Prefer the typed helpers above for concrete
/// types; use this for unusual cases. [warnKey] overrides the key shown in the
/// warning (defaults to [key]) — use it when the lookup key is bare but the
/// message needs a prefix.
T? readField<T>(String key, Map<dynamic, dynamic> yaml, List<String> warns, {T? defaultValue, String? warnKey}) {
  final raw = yaml[key];
  if (raw == null) return defaultValue;
  if (raw is T) return raw;
  warns.add(
    'Invalid type for ${warnKey ?? key}: "${raw.runtimeType}" — using ${defaultValue == null ? 'defaults' : 'default'}',
  );
  return defaultValue;
}
