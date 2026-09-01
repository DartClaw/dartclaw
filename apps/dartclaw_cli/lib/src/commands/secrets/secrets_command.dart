import 'package:args/command_runner.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show ExitFn;

import '../auth/secret_input.dart';
import '../credential_subcommand.dart';
import 'secrets_audit_command.dart';
import 'secrets_list_command.dart';
import 'secrets_rm_command.dart';
import 'secrets_set_command.dart';

/// The operator's write path into DartClaw's named credential store.
class SecretsCommand extends Command<void> {
  new({
    CredentialWriteLine? stdoutLine,
    CredentialWriteLine? stderrLine,
    ExitFn? exitFn,
    Map<String, String>? environment,
    SecretTerminal? terminal,
  }) {
    addSubcommand(
      SecretsSetCommand(
        stdoutLine: stdoutLine,
        stderrLine: stderrLine,
        exitFn: exitFn,
        environment: environment,
        terminal: terminal,
      ),
    );
    addSubcommand(
      SecretsListCommand(stdoutLine: stdoutLine, stderrLine: stderrLine, exitFn: exitFn, environment: environment),
    );
    addSubcommand(
      SecretsRmCommand(stdoutLine: stdoutLine, stderrLine: stderrLine, exitFn: exitFn, environment: environment),
    );
    addSubcommand(
      SecretsAuditCommand(stdoutLine: stdoutLine, stderrLine: stderrLine, exitFn: exitFn, environment: environment),
    );
  }

  @override
  String get name => 'secrets';

  @override
  String get description => 'Store, list, remove and audit named credentials for this DartClaw instance';
}
