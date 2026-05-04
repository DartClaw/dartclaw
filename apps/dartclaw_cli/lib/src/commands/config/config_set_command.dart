import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show ConfigMeta, ConfigMutability, DartclawConfig;

import '../../dartclaw_api_client.dart';
import '../connected_command_support.dart';
import '../serve_command.dart' show ExitFn, WriteLine;

class ConfigSetCommand extends Command<void> {
  final DartclawConfig? _config;
  final DartclawApiClient? _apiClient;
  final WriteLine _writeLine;
  final ExitFn _exitFn;

  ConfigSetCommand({DartclawConfig? config, DartclawApiClient? apiClient, WriteLine? writeLine, ExitFn? exitFn})
    : _config = config,
      _apiClient = apiClient,
      _writeLine = writeLine ?? stdout.writeln,
      _exitFn = exitFn ?? exit {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'set';

  @override
  String get description => 'Update a config value';

  @override
  Future<void> run() async {
    final args = argResults!.rest;
    if (args.length < 2) {
      throw UsageException('Usage: dartclaw config set <key> <value>', usage);
    }
    final inputKey = args[0];
    final rawValue = args.sublist(1).join(' ');
    final yamlKey = _normalizeYamlKey(inputKey);
    final apiClient = resolveCliApiClient(globalResults: globalResults, apiClient: _apiClient, config: _config);
    try {
      final result = await apiClient.patchObject('/api/config', body: {yamlKey: parseCliValue(rawValue)});
      if (argResults!['json'] as bool) {
        writePrettyJson(_writeLine, result);
        return;
      }
      final pendingRestart = ((result['pendingRestart'] as List?) ?? const []).map((value) => value.toString()).toSet();
      final meta = ConfigMeta.fields[yamlKey] ?? ConfigMeta.byJsonKey[inputKey];
      var status = 'Applied';
      if (pendingRestart.contains(yamlKey)) {
        status = 'Applied (restart required)';
      } else if (meta?.mutability == ConfigMutability.reloadable) {
        status = 'Applied (reload required)';
      } else if (meta?.mutability == ConfigMutability.live) {
        status = 'Applied (live)';
      }
      _writeLine('$status: $yamlKey = $rawValue');
    } on DartclawApiException catch (error) {
      _writeLine(error.message);
      _exitFn(1);
    }
  }
}

String _normalizeYamlKey(String input) {
  if (ConfigMeta.fields.containsKey(input)) {
    return input;
  }
  final jsonMeta = ConfigMeta.byJsonKey[input];
  if (jsonMeta != null) {
    return jsonMeta.yamlPath;
  }
  return input;
}
