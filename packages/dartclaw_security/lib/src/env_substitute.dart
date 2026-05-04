import 'dart:io';

import 'package:logging/logging.dart';

final _log = Logger('envSubstitute');
final _envPattern = RegExp(r'\$\{([A-Za-z_][A-Za-z0-9_]*)\}');

/// Resolves `${VAR}` patterns in [input] using environment variables.
///
/// Only resolves `${VAR}` — NOT `$VAR` (explicit syntax, avoids accidental
/// substitution). Undefined vars resolve to empty string with a warning.
String envSubstitute(String input, {Map<String, String>? env}) {
  final environment = env ?? Platform.environment;
  return input.replaceAllMapped(_envPattern, (match) {
    final varName = match.group(1)!;
    final value = environment[varName];
    if (value == null) {
      _log.warning('Undefined env var: \${$varName} — resolved to empty string');
      return '';
    }
    return value;
  });
}

/// Returns the list of `${VAR}` names referenced in [input], in order of
/// appearance and deduplicated.
///
/// Used to preserve env-var provenance for downstream diagnostics (e.g.
/// startup credential preflight) after [envSubstitute] resolves the value.
List<String> envReferences(String input) {
  final seen = <String>{};
  final refs = <String>[];
  for (final match in _envPattern.allMatches(input)) {
    final name = match.group(1)!;
    if (seen.add(name)) {
      refs.add(name);
    }
  }
  return refs;
}
