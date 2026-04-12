import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show ConfigMeta, DartclawConfig;

import '../../dartclaw_api_client.dart';
import '../connected_command_support.dart';
import '../serve_command.dart' show ExitFn, WriteLine;

class ConfigShowCommand extends Command<void> {
  final DartclawConfig? _config;
  final DartclawApiClient? _apiClient;
  final WriteLine _writeLine;
  final ExitFn _exitFn;

  ConfigShowCommand({DartclawConfig? config, DartclawApiClient? apiClient, WriteLine? writeLine, ExitFn? exitFn})
    : _config = config,
      _apiClient = apiClient,
      _writeLine = writeLine ?? stdout.writeln,
      _exitFn = exitFn ?? exit {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'show';

  @override
  String get description => 'Show resolved configuration';

  @override
  Future<void> run() async {
    final apiClient = resolveCliApiClient(globalResults: globalResults, apiClient: _apiClient, config: _config);
    try {
      final configJson = await apiClient.getObject('/api/config');
      if (argResults!['json'] as bool) {
        writePrettyJson(_writeLine, configJson);
        return;
      }

      _writeLine('  ${'KEY'.padRight(40)}  ${'VALUE'.padRight(28)}  MUTABILITY');
      for (final entry in ConfigMeta.byJsonKey.entries.toList()..sort((a, b) => a.key.compareTo(b.key))) {
        final result = lookupPath(configJson, entry.key);
        if (!result.exists) {
          continue;
        }
        final display = _displayValue(result.value);
        _writeLine(
          '  ${truncate(entry.key, 40).padRight(40)}  ${truncate(display, 28).padRight(28)}  ${entry.value.mutability.name}',
        );
      }
    } on DartclawApiException catch (error) {
      _writeLine(error.message);
      _exitFn(1);
    }
  }
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
