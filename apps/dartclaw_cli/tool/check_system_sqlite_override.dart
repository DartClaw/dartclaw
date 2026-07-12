import 'dart:io';

import 'package:yaml/yaml.dart';

bool hasSystemSqliteOverride(String yaml) {
  final document = loadYaml(yaml);
  if (document is! YamlMap) return false;

  final hooks = document['hooks'];
  if (hooks is! YamlMap) return false;
  final userDefines = hooks['user_defines'];
  if (userDefines is! YamlMap) return false;
  final sqlite3 = userDefines['sqlite3'];
  if (sqlite3 is! YamlMap) return false;
  return sqlite3['source'] == 'system';
}

void main(List<String> arguments) {
  if (arguments.isEmpty) {
    stderr.writeln('Usage: check_system_sqlite_override.dart <pubspec.yaml> [...]');
    exitCode = 64;
    return;
  }

  final matches = <String>[];
  for (final path in arguments) {
    final file = File(path);
    if (hasSystemSqliteOverride(file.readAsStringSync())) {
      matches.add(path);
    }
  }
  if (matches.isNotEmpty) {
    stderr.writeln(matches.join('\n'));
    exitCode = 1;
  }
}
