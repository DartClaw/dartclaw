import 'dart:io';

import 'package:dartclaw_acp/dartclaw_acp.dart' show acpConfigFor;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';

/// Where a resolved credential's value actually comes from.
enum CredentialProvenance {
  /// `<data_dir>/credentials/named/<name>.json`.
  store,

  /// A literal value in the config file.
  config,

  /// A `${VAR}` reference in the config file, resolved from the environment.
  env,
}

/// One credential name as the operator's instance currently holds it.
class CredentialRecord {
  /// The credential name.
  final String name;

  /// The type of the entry that wins.
  final CredentialType type;

  /// Where the winning entry's value comes from.
  final CredentialProvenance provenance;

  /// Environment variables the config-declared form references, for a
  /// [CredentialProvenance.env] record. Names, never values.
  final List<String> envVars;

  /// Whether the store and the config file both declare this name.
  final bool shadowed;

  /// Whether the winning entry resolves to a non-empty value.
  final bool isPresent;

  /// Creates one inventory record.
  const new({
    required this.name,
    required this.type,
    required this.provenance,
    required this.shadowed,
    required this.isPresent,
    this.envVars = const [],
  });
}

/// Every credential name across the store and the config file, name-ordered.
///
/// [declared] must be the config file's *own* view — a config whose stored
/// credentials were already merged in cannot report a shadowed name, because
/// the store's entry has replaced the declared one by then.
List<CredentialRecord> inventoryCredentials({
  required Map<String, CredentialEntry> stored,
  required CredentialsConfig declared,
}) {
  final names = {...stored.keys, ...declared.entries.keys}.toList()..sort();
  return [
    for (final name in names)
      if (stored[name] case final storedEntry?)
        CredentialRecord(
          name: name,
          type: storedEntry.type,
          provenance: CredentialProvenance.store,
          shadowed: declared[name] != null,
          isPresent: storedEntry.isPresent,
        )
      else
        _declaredRecord(name, declared[name]!),
  ];
}

CredentialRecord _declaredRecord(String name, CredentialEntry entry) => CredentialRecord(
  name: name,
  type: entry.type,
  provenance: entry.envVars.isEmpty ? CredentialProvenance.config : CredentialProvenance.env,
  shadowed: false,
  isPresent: entry.isPresent,
  envVars: entry.envVars,
);

/// A value-free finding identifying a config path or credential name.
typedef SecretFinding = ({String path, String reason});

/// Audits storage using the config file's declared view, before stored merging.
Map<String, List<SecretFinding>> auditSecrets({
  required DartclawConfig config,
  required Map<String, dynamic> yaml,
  required Map<String, CredentialEntry> stored,
  required String configPath,
  required Map<String, String> environment,
  PlatformCapabilities? platformCapabilities,
}) {
  final audit = _SecretAudit(environment);
  return {
    'Literals in config': _SecretAudit._literals(yaml),
    'Unresolvable references': audit._unresolvable(config, yaml),
    'Shadowed entries': _SecretAudit._shadowed(stored: stored, declared: config.credentials),
    'Orphans': _SecretAudit._orphans(config, yaml),
    'Permissions': (platformCapabilities ?? PlatformCapabilities()).posixSignalsAvailable
        ? _SecretAudit._permissions(configPath, config.credentialsDir)
        : const [],
  };
}

class _SecretAudit {
  final Map<String, String> environment;
  const new(this.environment);

  static List<SecretFinding> _literals(Map<String, dynamic> yaml) => [
    for (final entry in _rawCredentials(yaml).entries)
      if (_isLiteral(_rawCredentialSecret(entry.value)))
        (path: 'credentials.${entry.key}', reason: 'holds a literal value rather than environment references'),
    for (final provider in _rawSearchProviders(yaml).entries)
      if (_isLiteral(provider.value['api_key']))
        (path: 'search.providers.${provider.key}.api_key', reason: 'holds a literal value'),
    if (_isLiteral(_rawSection(yaml, 'github')['webhook_secret']))
      (path: 'github.webhook_secret', reason: 'holds a literal value'),
  ];

  List<SecretFinding> _unresolvable(DartclawConfig config, Map<String, dynamic> yaml) => [
    for (final entry in config.credentials.entries.entries)
      if (entry.value.envVars.where(_isUnresolvableEnv).toList() case final unresolved when unresolved.isNotEmpty)
        (path: 'credentials.${entry.key}', reason: 'references ${unresolved.join(', ')}, which resolve to nothing'),
    for (final provider in _rawSearchProviders(yaml).entries)
      ..._unresolvableRaw('search.providers.${provider.key}.api_key', provider.value['api_key']),
    ..._unresolvableRaw('github.webhook_secret', _rawSection(yaml, 'github')['webhook_secret']),
  ];

  static List<SecretFinding> _shadowed({
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
  static List<SecretFinding> _orphans(DartclawConfig config, Map<String, dynamic> yaml) {
    const providerNames = {'anthropic', 'openai'};
    final consumed = {
      ...providerNames,
      for (final server in config.mcpServers.entries.values) ?server.credential,
      for (final agent in acpConfigFor(config).agents.values) ?agent.credential,
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

  static List<SecretFinding> _permissions(String configPath, String credentialsDir) => [
    ..._looseFile(configPath, 'the config file'),
    ..._looseDirectory(credentialsDir, 'the credential directory'),
    for (final entity in _credentialEntities(credentialsDir))
      ...switch (entity) {
        File() => _looseFile(entity.path, 'a credential file'),
        Directory() => _looseDirectory(entity.path, 'a credential directory'),
        _ => const <SecretFinding>[],
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

  static List<SecretFinding> _looseFile(String path, String what) {
    if (Platform.isWindows) return const [];
    final file = File(path);
    if (!file.existsSync()) return const [];
    final mode = file.statSync().mode & 0x3f; // group + other bits
    if (mode == 0) return const [];
    return [(path: path, reason: '$what is readable beyond its owner (mode ${_octal(file)})')];
  }

  static List<SecretFinding> _looseDirectory(String path, String what) {
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

  List<SecretFinding> _unresolvableRaw(String path, Object? raw) {
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
