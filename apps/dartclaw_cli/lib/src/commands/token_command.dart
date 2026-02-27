import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';

typedef TokenWriteLine = void Function(String line);

/// Token management command with `show` and `rotate` subcommands.
class TokenCommand extends Command<void> {
  @override
  String get name => 'token';

  @override
  String get description => 'Manage gateway authentication token';

  TokenCommand() {
    addSubcommand(_TokenShowCommand());
    addSubcommand(_TokenRotateCommand());
  }
}

class _TokenShowCommand extends Command<void> {
  final TokenWriteLine _stdoutLine;
  final TokenWriteLine _stderrLine;

  @override
  String get name => 'show';

  @override
  String get description => 'Display the current gateway token';

  _TokenShowCommand({
    TokenWriteLine? stdoutLine,
    TokenWriteLine? stderrLine,
  })  : _stdoutLine = stdoutLine ?? stdout.writeln,
        _stderrLine = stderrLine ?? stderr.writeln;

  @override
  void run() {
    final config = DartclawConfig.load(configPath: globalResults?['config'] as String?);
    final dataDir = config.dataDir;
    final token = config.gatewayToken ?? TokenService.loadFromFile(dataDir);
    if (token == null) {
      _stderrLine('No token configured. Run `dartclaw serve` to auto-generate one.');
    } else {
      _stdoutLine(token);
    }
  }
}

class _TokenRotateCommand extends Command<void> {
  final TokenWriteLine _stdoutLine;
  final TokenWriteLine _stderrLine;

  @override
  String get name => 'rotate';

  @override
  String get description => 'Generate and persist a new gateway token';

  _TokenRotateCommand({
    TokenWriteLine? stdoutLine,
    TokenWriteLine? stderrLine,
  })  : _stdoutLine = stdoutLine ?? stdout.writeln,
        _stderrLine = stderrLine ?? stderr.writeln;

  @override
  void run() {
    final config = DartclawConfig.load(configPath: globalResults?['config'] as String?);
    final dataDir = config.dataDir;
    final newToken = TokenService.rotateToken(dataDir);
    _stdoutLine(newToken);
    _stderrLine('Token rotated. All existing sessions invalidated.');
  }
}
