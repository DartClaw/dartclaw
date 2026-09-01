import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'credential_inventory.dart';
import 'secrets_subcommand.dart';

/// Reports every credential name this instance holds, and where its value
/// comes from.
///
/// Names, types and provenance only. A value prefix is deliberately not printed
/// "to help identify the key": a prefix is enough to confirm a guess, and the
/// name already identifies the entry.
class SecretsListCommand extends SecretsSubcommand {
  new({super.stdoutLine, super.stderrLine, super.exitFn, super.environment});

  @override
  String get name => 'list';

  @override
  String get description => 'List credential names, types and provenance — never values';

  @override
  Future<void> run() async {
    final config = loadDeclaredConfig();
    final records = inventoryCredentials(
      stored: openStore(config.credentialsDir).readAll(),
      declared: config.credentials,
    );
    if (records.isEmpty) {
      stdoutLine('No credentials are stored or declared for this instance.');
      return;
    }
    final nameWidth = records.map((record) => record.name.length).reduce((a, b) => a > b ? a : b);
    final typeWidth = records.map((record) => _typeLabel(record).length).reduce((a, b) => a > b ? a : b);
    stdoutLine('${'NAME'.padRight(nameWidth)}  ${'TYPE'.padRight(typeWidth)}  SOURCE');
    for (final record in records) {
      stdoutLine(
        '${record.name.padRight(nameWidth)}  ${_typeLabel(record).padRight(typeWidth)}  ${_sourceLabel(record)}',
      );
    }
  }

  static String _typeLabel(CredentialRecord record) => switch (record.type) {
    CredentialType.apiKey => 'api-key',
    CredentialType.githubToken => 'github-token',
    CredentialType.subscription => 'subscription',
  };

  static String _sourceLabel(CredentialRecord record) {
    final source = switch (record.provenance) {
      CredentialProvenance.store => 'store',
      CredentialProvenance.config => 'config',
      CredentialProvenance.env => 'env (${record.envVars.join(', ')})',
    };
    final shadowed = record.shadowed ? ' — shadows a config-declared entry of the same name' : '';
    final unresolved = record.isPresent ? '' : ' — resolves to an empty value';
    return '$source$shadowed$unresolved';
  }
}
