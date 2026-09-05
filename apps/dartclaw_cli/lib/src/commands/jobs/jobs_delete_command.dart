import 'dart:io';

import '../connected_command_support.dart';

class JobsDeleteCommand extends ConnectedCommand {
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
  String get description => 'Delete a scheduled job';

  @override
  Future<void> run() => runConnected((apiClient) async {
    final jobName = requirePositionalArg('Job name required');
    if (!confirmDestructive(
      yes: argResults!['yes'] as bool,
      hasTerminal: _hasTerminal(),
      readLine: _readLine,
      prompt: 'Delete job $jobName?',
      stderrLine: stderrLine,
    )) {
      stderrLine('Job $jobName not deleted.');
      exitFn(1);
    }
    final encodedName = Uri.encodeComponent(jobName);
    final result = await apiClient.deleteObject('/api/scheduling/jobs/$encodedName');
    if (argResults!['json'] as bool) {
      writePrettyJson(writeLine, result);
    } else {
      writeLine('Deleted job $jobName.');
    }
  });
}
