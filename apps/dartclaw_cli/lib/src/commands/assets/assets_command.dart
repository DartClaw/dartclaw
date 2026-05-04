import 'package:args/command_runner.dart';

import 'assets_download_command.dart';

/// Asset management commands.
class AssetsCommand extends Command<void> {
  AssetsCommand({AssetsDownloadCommand? downloadCommand}) {
    addSubcommand(downloadCommand ?? AssetsDownloadCommand());
  }

  @override
  String get name => 'assets';

  @override
  String get description => 'Manage downloadable DartClaw release assets';
}
