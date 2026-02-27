import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_core/dartclaw_core.dart';

typedef StatusWriteLine = void Function(String line);

/// Shows DartClaw status: data directory info, session count, worker path.
class StatusCommand extends Command<void> {
  final DartclawConfig? _config;
  final StatusWriteLine _writeLine;

  StatusCommand({DartclawConfig? config, StatusWriteLine? writeLine})
    : _config = config,
      _writeLine = writeLine ?? stdout.writeln;

  @override
  String get name => 'status';

  @override
  String get description => 'Show DartClaw status';

  @override
  Future<void> run() async {
    final config = _config ?? DartclawConfig.load(configPath: globalResults?['config'] as String?);

    for (final w in config.warnings) {
      _writeLine('WARNING: $w');
    }

    final dataDir = config.dataDir;

    if (!Directory(dataDir).existsSync()) {
      _writeLine('No data directory found at $dataDir');
      return;
    }

    final sessions = SessionService(baseDir: config.sessionsDir);
    final sessionList = await sessions.listSessions();

    _writeLine('DartClaw Status');
    _writeLine('  Data dir:  $dataDir');
    _writeLine('  Sessions:  ${sessionList.length}');
    _writeLine('  Harness:   not running (executable: ${config.claudeExecutable})');
  }
}
