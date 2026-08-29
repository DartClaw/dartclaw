import 'secrets_subcommand.dart';

/// Removes a stored named credential, leaving any config-declared entry of the
/// same name alone.
class SecretsRmCommand extends SecretsSubcommand {
  new({super.stdoutLine, super.stderrLine, super.exitFn, super.environment});

  @override
  String get name => 'rm';

  @override
  String get description => 'Remove a stored named credential';

  @override
  String get invocation => 'dartclaw secrets rm <name>';

  @override
  Future<void> run() async {
    final name = readNameArgument();
    final config = loadDeclaredConfig();
    final store = openStore(config.credentialsDir);
    if (!store.remove(name)) {
      stderrLine('No stored credential called "$name" — nothing was removed.');
      exitFn(1);
    }
    stdoutLine('Removed the stored credential "$name".');
    if (config.credentials[name] != null) {
      stdoutLine(
        'A config-declared `credentials.$name` entry remains and now resolves again — remove it from your config '
        'file if that is not what you want.',
      );
    }
  }
}
