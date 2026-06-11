import 'package:args/command_runner.dart';

import 'config_command.dart';
import 'secrets_command.dart';

/// Parent command for deployment operations.
///
/// Two-step workflow (prerequisite validation now lives in `dartclaw init`):
/// 1. `deploy config` — generate service files with placeholders
/// 2. `deploy secrets` — inject secrets, start service, verify health
class DeployCommand extends Command<void> {
  @override
  String get name => 'deploy';

  @override
  String get description => 'Deploy DartClaw as a persistent service';

  DeployCommand() {
    addSubcommand(ConfigCommand());
    addSubcommand(SecretsCommand());
  }
}
