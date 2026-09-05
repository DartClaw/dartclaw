import 'dart:io';

import '../connected_command_support.dart';

class ProjectsRemoveCommand extends ConnectedCommand {
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
  String get name => 'remove';

  @override
  String get description => 'Remove a project';

  @override
  Future<void> run() => runConnected((apiClient) async {
    final projectId = requirePositionalArg('Project ID required');
    if (!confirmDestructive(
      yes: argResults!['yes'] as bool,
      hasTerminal: _hasTerminal(),
      readLine: _readLine,
      prompt: 'Remove project $projectId? This also removes related tasks, worktrees, and runtime state.',
      stderrLine: stderrLine,
    )) {
      stderrLine('Project removal aborted.');
      exitFn(1);
    }

    final result = await apiClient.deleteObject('/api/projects/$projectId');
    if (argResults!['json'] as bool) {
      writePrettyJson(writeLine, result);
    } else {
      writeLine('Removed project $projectId.');
    }
  });
}
