import 'dart:convert';

import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowDefinition, WorkflowRun;

import 'cli_progress_printer.dart';
import 'live_status_line.dart';
import 'standalone_lifecycle_support.dart';
import 'standalone_run_harness.dart';

/// Base for workflow CLI subcommands that target a single run by positional id.
///
/// In connected mode they POST to `/api/workflows/runs/<runId>/<verb>`; in
/// standalone mode the concrete command drives the in-process engine via
/// [StandaloneWorkflowLifecycleCommand.runStandaloneLifecycle]. Concrete
/// subcommands provide [name]/[description] and branch on [isStandalone] from
/// [run].
abstract class WorkflowRunIdCommand extends StandaloneWorkflowLifecycleCommand {
  WorkflowRunIdCommand({
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
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
  }

  @override
  String get invocation => '${runner!.executableName} workflow $name <runId>';

  /// POSTs to `/api/workflows/runs/[runId]/[pathSuffix]` and prints either the
  /// JSON envelope or `Workflow <id> <verb> (<status>).`.
  Future<void> runAgainstRun({required String runId, required String pathSuffix, required String verb}) =>
      runConnected((apiClient) async {
        final result = await apiClient.postObject('/api/workflows/runs/$runId/$pathSuffix');
        if (argResults!['json'] as bool) {
          writeLine(const JsonEncoder.withIndent('  ').convert(result));
        } else {
          writeLine('Workflow ${result['id']} $verb (${result['status']}).');
        }
      });

  /// Drives the in-process engine to settle for execution verbs (resume/retry):
  /// loads the run definition, renders step-progress through [driveStandaloneWorkflowRun],
  /// and returns the settle status's exit code. [trigger] performs the
  /// `resume`/`retry` that spawns the executor.
  Future<int> driveStandaloneExecution(
    StandaloneLifecycleSession session,
    Future<WorkflowRun> Function() trigger,
  ) async {
    final definition = WorkflowDefinition.fromJson(session.run.definitionJson);
    final printer = CliProgressPrinter(
      totalSteps: definition.steps.length,
      workflowName: definition.name,
      writeLine: writeLine,
      standalone: true,
      liveStatusLine: LiveStatusLine.forStdout(jsonOutput: argResults!['json'] as bool),
    );
    final finalRun = await driveStandaloneWorkflowRun(
      service: session.wiring.workflowService,
      taskService: session.wiring.taskService,
      definition: definition,
      eventBus: session.wiring.eventBus,
      printer: printer,
      jsonOutput: argResults!['json'] as bool,
      stdoutLine: writeLine,
      interrupts: interrupts,
      exitFn: exitFn,
      trigger: trigger,
    );
    return standaloneWorkflowExitCode(finalRun.status);
  }

  /// Prints the single-transition result (`pause`) as JSON or
  /// `Workflow <id> <verb> (<status>).`.
  void printLifecycleStatus(WorkflowRun run, String verb) {
    if (argResults!['json'] as bool) {
      writeLine(const JsonEncoder.withIndent('  ').convert(run.toJson()));
    } else {
      writeLine('Workflow ${run.id} $verb (${run.status.name}).');
    }
  }
}
