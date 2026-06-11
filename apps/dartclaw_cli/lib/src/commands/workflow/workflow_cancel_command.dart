import 'dart:convert';

import '../connected_command_support.dart';

class WorkflowCancelCommand extends ConnectedCommand {
  WorkflowCancelCommand({super.config, super.apiClient, super.writeLine, super.exitFn}) {
    argParser
      ..addOption('feedback', help: 'Optional rejection or cancellation feedback')
      ..addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get name => 'cancel';

  @override
  String get description => 'Cancel a workflow run';

  @override
  String get invocation => '${runner!.executableName} workflow cancel <runId>';

  @override
  Future<void> run() => runConnected((apiClient) async {
    final runId = requirePositionalArg('Run ID required');
    await apiClient.post(
      '/api/workflows/runs/$runId/cancel',
      body: {
        if ((argResults!['feedback'] as String?)?.trim().isNotEmpty == true)
          'feedback': (argResults!['feedback'] as String).trim(),
      },
    );
    final updated = await apiClient.getObject('/api/workflows/runs/$runId');
    if (argResults!['json'] as bool) {
      writeLine(const JsonEncoder.withIndent('  ').convert(updated));
    } else {
      writeLine('Workflow ${updated['id']} cancelled (${updated['status']}).');
    }
  });
}
