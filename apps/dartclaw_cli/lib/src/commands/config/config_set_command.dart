import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show ConfigMeta, ConfigMutability;

import '../connected_command_support.dart';

class ConfigSetCommand extends ConnectedCommand {
  ConfigSetCommand({super.config, super.apiClient, super.writeLine, super.exitFn}) {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'set';

  @override
  String get description => 'Update a config value';

  @override
  Future<void> run() => runConnected((apiClient) async {
    final args = argResults!.rest;
    if (args.length < 2) {
      throw UsageException('Usage: dartclaw config set <key> <value>', usage);
    }
    final inputKey = args[0];
    final rawValue = args.sublist(1).join(' ');
    final yamlKey = _normalizeYamlKey(inputKey);
    final result = await apiClient.patchObject('/api/config', body: {yamlKey: parseCliValue(rawValue)});
    if (argResults!['json'] as bool) {
      writePrettyJson(writeLine, result);
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
    writeLine('$status: $yamlKey = $rawValue');
  });
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
