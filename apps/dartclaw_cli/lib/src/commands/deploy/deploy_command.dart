import 'package:args/command_runner.dart';

import 'config_command.dart';
import 'secrets_command.dart';
import 'setup_command.dart';

/// Parent command for deployment operations.
///
/// Three-step workflow:
/// 1. `deploy setup` — validate prerequisites
/// 2. `deploy config` — generate service files with placeholders
/// 3. `deploy secrets` — inject secrets, start service, verify health
class DeployCommand extends Command<void> {
  @override
  String get name => 'deploy';

  @override
  String get description => 'Deploy DartClaw as a persistent service';

  DeployCommand() {
    addSubcommand(SetupCommand());
    addSubcommand(ConfigCommand());
    addSubcommand(SecretsCommand());
  }
}
