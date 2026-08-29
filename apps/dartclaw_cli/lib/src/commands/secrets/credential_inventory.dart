import 'package:dartclaw_config/dartclaw_config.dart';

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
