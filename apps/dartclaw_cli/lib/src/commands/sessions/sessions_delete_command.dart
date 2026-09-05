import 'dart:io';

import '../connected_command_support.dart';

class SessionsDeleteCommand extends ConnectedCommand {
  final bool Function() _hasTerminal;
  final String? Function() _readLine;

  new({
    super.config,
    super.apiClient,
    super.writeLine,
    super.stderrLine,
    super.exitFn,
    bool Function()? hasTerminal,
    String? Function()? readLine,
  }) : _hasTerminal = hasTerminal ?? (() => stdin.hasTerminal),
       _readLine = readLine ?? stdin.readLineSync {
    argParser
      ..addFlag('yes', abbr: 'y', negatable: false, help: 'Skip the confirmation prompt')
      ..addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'delete';

  @override
  String get description => 'Delete a session';

  @override
  Future<void> run() => runConnected((apiClient) async {
    final sessionId = requirePositionalArg('Session ID required');
    if (!confirmDestructive(
      yes: argResults!['yes'] as bool,
      hasTerminal: _hasTerminal(),
      readLine: _readLine,
      prompt: 'Delete session $sessionId?',
      stderrLine: stderrLine,
    )) {
      stderrLine('Session $sessionId not deleted.');
      exitFn(1);
    }
    final result = await apiClient.delete('/api/sessions/$sessionId');
    if (argResults!['json'] as bool) {
      writePrettyJson(writeLine, result);
    } else {
      writeLine('Deleted session $sessionId.');
    }
  });
}
