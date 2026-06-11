import 'dart:convert';

import '../connected_command_support.dart';

/// Base for workflow CLI subcommands that target a single run by positional id
/// and POST to a `/api/workflows/runs/<runId>/<verb>` endpoint.
///
/// Concrete subcommands provide [name], [description], and call [runAgainstRun]
/// from [run] with the path suffix and verb that matches their REST endpoint.
abstract class WorkflowRunIdCommand extends ConnectedCommand {
  WorkflowRunIdCommand({super.config, super.apiClient, super.writeLine, super.exitFn}) {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get invocation => '${runner!.executableName} workflow $name <runId>';

  /// POSTs to `/api/workflows/runs/<runId>/<pathSuffix>` and prints either the
  /// JSON envelope or `Workflow <id> <verb> (<status>).`.
  Future<void> runAgainstRun({required String pathSuffix, required String verb}) => runConnected((apiClient) async {
    final runId = requirePositionalArg('Run ID required');
    final result = await apiClient.postObject('/api/workflows/runs/$runId/$pathSuffix');
    if (argResults!['json'] as bool) {
      writeLine(const JsonEncoder.withIndent('  ').convert(result));
    } else {
      writeLine('Workflow ${result['id']} $verb (${result['status']}).');
    }
  });
}
