import 'package:args/args.dart' show ArgResults;

/// Reads `--server` from the global parser results, returning `null` when the
/// option is absent or the parser does not declare it.
String? serverOverride(ArgResults? results) => globalOptionString(results, 'server');

/// Returns the parsed string value of a global option, or `null` when the
/// parser does not declare [name] (e.g. command-level tests that omit the
/// global parser).
String? globalOptionString(ArgResults? results, String name) {
  if (results == null) return null;
  try {
    return results[name] as String?;
  } on ArgumentError {
    return null;
  }
}
