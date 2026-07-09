import 'dart:convert';

import 'standalone_lifecycle_support.dart';

class WorkflowCancelCommand extends StandaloneWorkflowLifecycleCommand {
  WorkflowCancelCommand({
    super.config,
    super.apiClient,
    super.writeLine,
    super.exitFn,
    super.searchDbFactory,
    super.taskDbFactory,
    super.harnessFactory,
    super.environment,
    super.stderrLine,
    super.interrupts,
    super.runWorkflowSkillsBootstrap,
    super.skillIntrospector,
    super.providerAuthPreflight,
  }) {
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
  Future<void> run() async {
    requireForceWithStandalone();
    final runId = requirePositionalArg('Run ID required');
    final feedback = _feedback();
    if (isStandalone) {
      await runStandaloneLifecycle(
        runId: runId,
        provisionTaskRunners: false,
        runWorkflowSkillsBootstrap: false,
        action: (session) async {
          await session.wiring.workflowService.cancel(runId, feedback: feedback);
          final updated = await session.wiring.workflowService.get(runId);
          if (argResults!['json'] as bool) {
            writeLine(const JsonEncoder.withIndent('  ').convert(updated?.toJson() ?? {'id': runId}));
          } else {
            writeLine('Workflow ${updated?.id ?? runId} cancelled (${updated?.status.name ?? 'unknown'}).');
          }
          return 0;
        },
      );
    } else {
      await runConnected((apiClient) async {
        await apiClient.post('/api/workflows/runs/$runId/cancel', body: {'feedback': ?feedback});
        final updated = await apiClient.getObject('/api/workflows/runs/$runId');
        if (argResults!['json'] as bool) {
          writeLine(const JsonEncoder.withIndent('  ').convert(updated));
        } else {
          writeLine('Workflow ${updated['id']} cancelled (${updated['status']}).');
        }
      });
    }
  }

  String? _feedback() {
    final raw = argResults!['feedback'] as String?;
    if (raw == null || raw.trim().isEmpty) return null;
    return raw.trim();
  }
}
