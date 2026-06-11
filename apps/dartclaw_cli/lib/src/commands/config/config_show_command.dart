import 'dart:convert';

import 'package:dartclaw_config/dartclaw_config.dart' show ConfigMeta;

import '../connected_command_support.dart';

class ConfigShowCommand extends ConnectedCommand {
  ConfigShowCommand({super.config, super.apiClient, super.writeLine, super.exitFn}) {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'show';

  @override
  String get description => 'Show resolved configuration';

  @override
  Future<void> run() => runConnected((apiClient) async {
    final configJson = await apiClient.getObject('/api/config');
    if (argResults!['json'] as bool) {
      writePrettyJson(writeLine, configJson);
      return;
    }

    writeLine('  ${'KEY'.padRight(40)}  ${'VALUE'.padRight(28)}  MUTABILITY');
    for (final entry in ConfigMeta.byJsonKey.entries.toList()..sort((a, b) => a.key.compareTo(b.key))) {
      final result = lookupPath(configJson, entry.key);
      if (!result.exists) {
        continue;
      }
      final display = _displayValue(result.value);
      writeLine(
        '  ${truncate(entry.key, 40).padRight(40)}  ${truncate(display, 28).padRight(28)}  ${entry.value.mutability.name}',
      );
    }
  });
}

String _displayValue(Object? value) {
  if (value == null) {
    return 'null';
  }
  if (value is List || value is Map) {
    return jsonEncode(value);
  }
  return value.toString();
}
