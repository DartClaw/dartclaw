import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show ConfigMeta, DartclawConfig;

import '../../dartclaw_api_client.dart';
import '../connected_command_support.dart';
import '../serve_command.dart' show ExitFn, WriteLine;

class ConfigGetCommand extends Command<void> {
  final DartclawConfig? _config;
  final DartclawApiClient? _apiClient;
  final WriteLine _writeLine;
  final ExitFn _exitFn;

  ConfigGetCommand({DartclawConfig? config, DartclawApiClient? apiClient, WriteLine? writeLine, ExitFn? exitFn})
    : _config = config,
      _apiClient = apiClient,
      _writeLine = writeLine ?? stdout.writeln,
      _exitFn = exitFn ?? exit;

  @override
  String get name => 'get';

  @override
  String get description => 'Get a single config value';

  @override
  Future<void> run() async {
    final args = argResults!.rest;
    if (args.isEmpty) {
      throw UsageException('Config key required', usage);
    }
    final inputKey = args.first;
    final apiClient = resolveCliApiClient(globalResults: globalResults, apiClient: _apiClient, config: _config);
    try {
      final configJson = await apiClient.getObject('/api/config');
      final jsonKey = _normalizeJsonKey(inputKey);
      final result = lookupPath(configJson, jsonKey);
      if (!result.exists) {
        _writeLine('Unknown config key: $inputKey');
        _exitFn(1);
      }
      final value = result.value;
      if (value is Map || value is List) {
        _writeLine(jsonEncode(value));
      } else {
        _writeLine(value?.toString() ?? 'null');
      }
    } on DartclawApiException catch (error) {
      _writeLine(error.message);
      _exitFn(1);
    }
  }
}

String _normalizeJsonKey(String input) {
  final yamlMeta = ConfigMeta.fields[input];
  if (yamlMeta != null) {
    return yamlMeta.jsonKey;
  }
  return input;
}
