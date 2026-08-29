import 'dart:io';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_security/dartclaw_security.dart' show envReferences;
import 'package:yaml/yaml.dart';

import '../config_loader.dart';
import 'credential_inventory.dart';
import 'secrets_subcommand.dart';

/// One place a secret lives that the store does not own.
typedef _Finding = ({String path, String reason});

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

    final classes = <String, List<_Finding>>{
      'Literals in config': _literals(yaml),
      'Unresolvable references': _unresolvable(config, yaml),
      'Shadowed entries': _shadowed(stored: stored, declared: config.credentials),
      'Orphans': _orphans(config, yaml),
      'Permissions': _permissions(configPath, config.credentialsDir),
    };

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

  static List<_Finding> _literals(Map<String, dynamic> yaml) => [
    for (final entry in _rawCredentials(yaml).entries)
      if (_isLiteral(_rawCredentialSecret(entry.value)))
        (path: 'credentials.${entry.key}', reason: 'holds a literal value rather than environment references'),
    for (final provider in _rawSearchProviders(yaml).entries)
      if (_isLiteral(provider.value['api_key']))
        (path: 'search.providers.${provider.key}.api_key', reason: 'holds a literal value'),
    if (_isLiteral(_rawSection(yaml, 'github')['webhook_secret']))
      (path: 'github.webhook_secret', reason: 'holds a literal value'),
  ];

  List<_Finding> _unresolvable(DartclawConfig config, Map<String, dynamic> yaml) => [
    for (final entry in config.credentials.entries.entries)
      if (entry.value.envVars.where(_isUnresolvableEnv).toList() case final unresolved when unresolved.isNotEmpty)
        (path: 'credentials.${entry.key}', reason: 'references ${unresolved.join(', ')}, which resolve to nothing'),
    for (final provider in _rawSearchProviders(yaml).entries)
      ..._unresolvableRaw('search.providers.${provider.key}.api_key', provider.value['api_key']),
    ..._unresolvableRaw('github.webhook_secret', _rawSection(yaml, 'github')['webhook_secret']),
  ];

  static List<_Finding> _shadowed({
    required Map<String, CredentialEntry> stored,
    required CredentialsConfig declared,
  }) => [
    for (final record in inventoryCredentials(stored: stored, declared: declared))
      if (record.shadowed)
        (
          path: 'credentials.${record.name}',
          reason: 'is declared in config and also stored — the stored entry wins, so the config one is dead',
        ),
  ];

  /// A `credentials.<name>` entry nothing consumes.
  ///
  /// `anthropic` and `openai` are consumed by name rather than by a
  /// `credential:` reference (`CredentialRegistry.getApiKey`), so they are
  /// never orphans.
  static List<_Finding> _orphans(DartclawConfig config, Map<String, dynamic> yaml) {
    const providerNames = {'anthropic', 'openai'};
    final consumed = {
      ...providerNames,
      for (final server in config.mcpServers.entries.values) ?server.credential,
      for (final agent in config.harness.acp.agents.values) ?agent.credential,
      for (final project in config.projects.definitions.values) ?project.credentials,
      // A resolved `credential:` lands in the same `apiKey` field a literal
      // does, so the reference has to come from the raw YAML.
      for (final provider in _rawSearchProviders(yaml).values)
        if (provider['credential'] case final String reference) reference.trim(),
    };
    return [
      for (final name in config.credentials.entries.keys)
        if (!consumed.contains(name))
          (path: 'credentials.$name', reason: 'is consumed by no `credential:` reference — remove it or wire it up'),
    ];
  }

  static List<_Finding> _permissions(String configPath, String credentialsDir) => [
    ..._looseFile(configPath, 'the config file'),
    ..._looseDirectory(credentialsDir, 'the credential directory'),
    for (final entity in _credentialEntities(credentialsDir))
      ...switch (entity) {
        File() => _looseFile(entity.path, 'a credential file'),
        Directory() => _looseDirectory(entity.path, 'a credential directory'),
        _ => const <_Finding>[],
      },
  ];

  static List<FileSystemEntity> _credentialEntities(String credentialsDir) {
    final directory = Directory(credentialsDir);
    if (!directory.existsSync()) return const [];
    try {
      return directory.listSync(recursive: true, followLinks: true);
    } on FileSystemException {
      return const [];
    }
  }

  static List<_Finding> _looseFile(String path, String what) {
    if (Platform.isWindows) return const [];
    final file = File(path);
    if (!file.existsSync()) return const [];
    final mode = file.statSync().mode & 0x3f; // group + other bits
    if (mode == 0) return const [];
    return [(path: path, reason: '$what is readable beyond its owner (mode ${_octal(file)})')];
  }

  static List<_Finding> _looseDirectory(String path, String what) {
    if (Platform.isWindows) return const [];
    final directory = Directory(path);
    if (!directory.existsSync()) return const [];
    final mode = directory.statSync().mode & 0x3f;
    if (mode == 0) return const [];
    return [(path: path, reason: '$what is accessible beyond its owner (mode ${_octal(directory)})')];
  }

  static String _octal(FileSystemEntity entity) => (entity.statSync().mode & 0x1ff).toRadixString(8).padLeft(3, '0');

  static Map<String, Map<String, dynamic>> _rawSearchProviders(Map<String, dynamic> yaml) {
    final providers = _rawSection(yaml, 'search')['providers'];
    if (providers is! Map) return const {};
    return {
      for (final entry in providers.entries)
        if (entry.value is Map) '${entry.key}': Map<String, dynamic>.from(entry.value as Map),
    };
  }

  static Map<String, Map<String, dynamic>> _rawCredentials(Map<String, dynamic> yaml) {
    final credentials = yaml['credentials'];
    if (credentials is! Map) return const {};
    return {
      for (final entry in credentials.entries)
        if (entry.value is Map) '${entry.key}': Map<String, dynamic>.from(entry.value as Map),
    };
  }

  static Object? _rawCredentialSecret(Map<String, dynamic> credential) => switch (credential['type']) {
    'github-token' || 'githubToken' => credential['token'],
    _ => credential['api_key'],
  };

  static Map<String, dynamic> _rawSection(Map<String, dynamic> yaml, String key) {
    final section = yaml[key];
    return section is Map ? Map<String, dynamic>.from(section) : const {};
  }

  static bool _isLiteral(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return false;
    var remainder = raw;
    for (final name in envReferences(raw)) {
      remainder = remainder.replaceAll('\${$name}', '');
    }
    return remainder.trim().isNotEmpty;
  }

  bool _isUnresolvableEnv(String name) => (environment[name] ?? '').trim().isEmpty;

  List<_Finding> _unresolvableRaw(String path, Object? raw) {
    if (raw is! String) return const [];
    final refs = envReferences(raw);
    if (refs.isEmpty) return const [];
    final unresolved = [
      for (final name in refs)
        if (_isUnresolvableEnv(name)) name,
    ];
    if (unresolved.isEmpty) return const [];
    return [(path: path, reason: 'references ${unresolved.join(', ')}, which resolve to nothing')];
  }
}
