import 'dart:io';

import 'package:yaml/yaml.dart';

import '../config_loader.dart';
import 'credential_inventory.dart';
import 'secrets_subcommand.dart';

/// Reports where this instance's secrets actually live.
///
/// Read-only, network-free, and value-free: it names config paths, credential
/// names and environment variable names, never a secret or any part of one.
/// Exits non-zero when it finds anything, so it can gate a deployment.
class SecretsAuditCommand extends SecretsSubcommand {
  new({super.stdoutLine, super.stderrLine, super.exitFn, super.environment});

  @override
  String get name => 'audit';

  @override
  String get description => 'Report every place a secret lives outside the credential store';

  @override
  Future<void> run() async {
    final config = loadDeclaredConfig();
    final configPath = resolveCliConfigPath(configPath: configPathOverride, env: environment);
    final yaml = _readYaml(configPath);
    final stored = openStore(config.credentialsDir, provision: false).readAll();

    final classes = auditSecrets(
      config: config,
      yaml: yaml,
      stored: stored,
      configPath: configPath,
      environment: environment,
    );

    var found = 0;
    for (final entry in classes.entries) {
      if (entry.key == 'Permissions' && Platform.isWindows) {
        stdoutLine('${entry.key}: not applicable on Windows — POSIX file modes are not the access boundary here.');
        continue;
      }
      if (entry.value.isEmpty) continue;
      found += entry.value.length;
      stdoutLine('${entry.key}:');
      for (final finding in entry.value) {
        stdoutLine('  ${finding.path} — ${finding.reason}');
      }
    }

    if (found == 0) {
      stdoutLine('No secret was found outside the credential store.');
      return;
    }
    stdoutLine('$found finding${found == 1 ? '' : 's'}. Move each value into the store with `dartclaw secrets set`.');
    exitFn(1);
  }

  /// The config file's raw YAML, or an empty map when there is no readable one.
  ///
  /// The parsed config cannot answer the literal-versus-`${VAR}` question for
  /// `search.providers.<id>.api_key` or `github.webhook_secret`: both are
  /// substituted at parse time, and a provider whose key resolves blank is
  /// dropped from the parsed map entirely.
  Map<String, dynamic> _readYaml(String configPath) {
    try {
      final file = File(configPath);
      if (!file.existsSync()) return const {};
      final document = loadYaml(file.readAsStringSync());
      return document is Map ? Map<String, dynamic>.from(document) : const {};
    } on YamlException {
      stderrLine('Could not parse $configPath — reporting on the store only.');
      return const {};
    } on FileSystemException {
      return const {};
    }
  }
}
