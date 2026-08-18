import 'package:args/command_runner.dart';

import '../serve_command.dart' show ExitFn;
import 'auth_claude_command.dart';
import 'auth_codex_command.dart';
import 'auth_subcommand.dart';
import 'secret_input.dart';

/// The operator's write path into DartClaw's dedicated credential stores.
class AuthCommand extends Command<void> {
  new({
    AuthWriteLine? stdoutLine,
    AuthWriteLine? stderrLine,
    ExitFn? exitFn,
    Map<String, String>? environment,
    SecretTerminal? terminal,
    ProcessStarter? startProcess,
  }) {
    addSubcommand(
      AuthClaudeCommand(
        stdoutLine: stdoutLine,
        stderrLine: stderrLine,
        exitFn: exitFn,
        environment: environment,
        terminal: terminal,
      ),
    );
    addSubcommand(
      AuthCodexCommand(
        stdoutLine: stdoutLine,
        stderrLine: stderrLine,
        exitFn: exitFn,
        environment: environment,
        startProcess: startProcess,
      ),
    );
  }

  @override
  String get name => 'auth';

  @override
  String get description => 'Store provider subscription credentials for this DartClaw instance';
}
