import 'dart:convert';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show ConfigMeta;

import '../connected_command_support.dart';

class ConfigGetCommand extends ConnectedCommand {
  ConfigGetCommand({super.config, super.apiClient, super.writeLine, super.exitFn});

  @override
  String get name => 'get';

  @override
  String get description => 'Get a single config value';

  @override
  Future<void> run() => runConnected((apiClient) async {
    final args = argResults!.rest;
    if (args.isEmpty) {
      throw UsageException('Config key required', usage);
    }
    final inputKey = args.first;
    final configJson = await apiClient.getObject('/api/config');
    final jsonKey = _normalizeJsonKey(inputKey);
    final result = lookupPath(configJson, jsonKey);
    if (!result.exists) {
      writeLine('Unknown config key: $inputKey');
      exitFn(1);
    }
    final value = result.value;
    if (value is Map || value is List) {
      writeLine(jsonEncode(value));
    } else {
      writeLine(value?.toString() ?? 'null');
    }
  });
}

String _normalizeJsonKey(String input) {
  final yamlMeta = ConfigMeta.fields[input];
  if (yamlMeta != null) {
    return yamlMeta.jsonKey;
  }
  return input;
}
