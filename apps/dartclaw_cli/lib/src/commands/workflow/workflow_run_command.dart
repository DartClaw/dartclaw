import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_core/dartclaw_core.dart'
    show
        DartclawConfig,
        EventBus,
        HarnessFactory,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowDefinition,
        WorkflowRun,
        WorkflowRunStatus,
        WorkflowRunStatusChangedEvent,
        WorkflowStepCompletedEvent,
        WorkflowApprovalRequestedEvent;
import 'package:dartclaw_server/dartclaw_server.dart' show TaskService, WorkflowService, WorkspaceService;
import 'package:dartclaw_storage/dartclaw_storage.dart' show SearchDbFactory, TaskDbFactory;

import '../config_loader.dart';
import '../serve_command.dart' show ExitFn, WriteLine;
import 'cli_progress_printer.dart';
import 'cli_workflow_wiring.dart';

/// Runs a workflow headlessly with progress streaming to stdout.
///
/// Starts a minimal in-process server (task execution infrastructure only —
/// no HTTP routes, no web UI), runs the named workflow, streams step progress
/// to stdout, and exits with a code reflecting the outcome:
/// - 0: workflow completed
/// - 1: workflow failed or cancelled
/// - 2: workflow paused
class WorkflowRunCommand extends Command<void> {
  final DartclawConfig? _config;
  final SearchDbFactory? _searchDbFactory;
  final TaskDbFactory? _taskDbFactory;
  final HarnessFactory? _harnessFactory;
  final WriteLine _stdoutLine;
  final WriteLine _stderrLine;
  final ExitFn _exitFn;

  WorkflowRunCommand({
    DartclawConfig? config,
    SearchDbFactory? searchDbFactory,
    TaskDbFactory? taskDbFactory,
    HarnessFactory? harnessFactory,
    WriteLine? stdoutLine,
    WriteLine? stderrLine,
    ExitFn? exitFn,
  }) : _config = config,
       _searchDbFactory = searchDbFactory,
       _taskDbFactory = taskDbFactory,
       _harnessFactory = harnessFactory,
       _stdoutLine = stdoutLine ?? stdout.writeln,
       _stderrLine = stderrLine ?? stderr.writeln,
       _exitFn = exitFn ?? exit {
    argParser
      ..addMultiOption('var', abbr: 'v', help: 'Variable (KEY=VALUE)', valueHelp: 'KEY=VALUE')
      ..addOption('project', abbr: 'p', help: 'Project ID for project-scoped steps');
  }

  @override
  String get name => 'run';

  @override
  String get description => 'Run a workflow headlessly';

  @override
  String get invocation => '${runner!.executableName} workflow run <name>';

  @override
  Future<void> run() async {
    final args = argResults!.rest;
    if (args.isEmpty) {
      throw UsageException('Workflow name required', usage);
    }
    final workflowName = args.first;
    final varArgs = argResults!['var'] as List<String>;
    final variables = _parseVariables(varArgs);
    final projectId = argResults!['project'] as String?;

    final config = _config ?? loadCliConfig(configPath: globalResults?['config'] as String?);
    final dataDir = config.server.dataDir;

    Directory(dataDir).createSync(recursive: true);

    // Run workspace migration (idempotent — no-op if already done).
    final workspace = WorkspaceService(dataDir: dataDir);
    await workspace.migrate();

    final wiring = CliWorkflowWiring(
      config: config,
      dataDir: dataDir,
      harnessFactory: _harnessFactory,
      searchDbFactory: _searchDbFactory,
      taskDbFactory: _taskDbFactory,
    );
    await wiring.wire();

    try {
      final definition = wiring.registry.getByName(workflowName);
      if (definition == null) {
        _stderrLine('Unknown workflow: $workflowName');
        final available = wiring.registry.listAll().map((d) => d.name).join(', ');
        if (available.isNotEmpty) {
          _stderrLine('Available: $available');
        } else {
          _stderrLine('No workflows are available.');
        }
        await wiring.dispose();
        _exitFn(1);
      }

      final printer = CliProgressPrinter(
        totalSteps: definition.steps.length,
        workflowName: definition.name,
        writeLine: _stdoutLine,
      );

      final exitCode = await _runAndStream(
        service: wiring.workflowService,
        taskService: wiring.taskService,
        variables: variables,
        eventBus: wiring.eventBus,
        printer: printer,
        projectId: projectId,
        definition: definition,
      );

      await wiring.dispose();
      _exitFn(exitCode);
    } catch (e, st) {
      _stderrLine('ERROR: $e');
      _stderrLine('$st');
      await wiring.dispose();
      _exitFn(1);
    }
  }

  Future<int> _runAndStream({
    required WorkflowService service,
    required TaskService taskService,
    required WorkflowDefinition definition,
    required Map<String, String> variables,
    required EventBus eventBus,
    required CliProgressPrinter printer,
    String? projectId,
  }) async {
    final runCompleter = Completer<WorkflowRun>();
    String? activeRunId;

    // Track step start times for duration calculation.
    final stepStartTimes = <int, DateTime>{};

    // Track the most recent approval-requested event so we can print approval context on pause.
    WorkflowApprovalRequestedEvent? lastApprovalEvent;

    // Subscribe before calling start() to avoid missing the first events.
    final runSub = eventBus.on<WorkflowRunStatusChangedEvent>().listen((event) {
      final runId = activeRunId;
      if (runId != null && event.runId != runId) return;
      if (event.newStatus.terminal || event.newStatus == WorkflowRunStatus.paused) {
        if (!runCompleter.isCompleted) {
          service.get(event.runId).then((run) {
            if (run != null && !runCompleter.isCompleted) {
              runCompleter.complete(run);
            }
          });
        }
      }
    });

    final approvalSub = eventBus.on<WorkflowApprovalRequestedEvent>().listen((event) {
      if (activeRunId != null && event.runId != activeRunId) return;
      lastApprovalEvent = event;
    });

    final stepSub = eventBus.on<WorkflowStepCompletedEvent>().listen((event) {
      if (activeRunId != null && event.runId != activeRunId) return;
      final startTime = stepStartTimes.remove(event.stepIndex);
      final duration = startTime != null ? DateTime.now().difference(startTime) : Duration.zero;
      if (event.success) {
        printer.stepCompleted(event.stepIndex, event.stepId, duration, event.tokenCount);
      } else {
        printer.stepFailed(event.stepIndex, event.stepId, null);
      }
    });

    // Subscribe to task status changes to print real-time step running/review lines.
    final taskSub = eventBus.on<TaskStatusChangedEvent>().listen((event) {
      final runId = activeRunId;
      if (runId == null) return;
      if (event.newStatus == TaskStatus.running || event.newStatus == TaskStatus.review) {
        taskService.get(event.taskId).then((task) {
          if (task == null || task.workflowRunId != runId) return;
          final stepIndex = task.stepIndex;
          if (stepIndex == null) return;
          final stepId = definition.steps.length > stepIndex ? definition.steps[stepIndex].id : task.id;
          if (event.newStatus == TaskStatus.running) {
            stepStartTimes[stepIndex] = DateTime.now();
            printer.stepRunning(stepIndex, stepId, task.title, task.provider ?? definition.steps[stepIndex].provider);
          } else {
            printer.stepReview(stepIndex, stepId);
          }
        });
      }
    });

    // Signal handling — SIGINT cancels the workflow.
    StreamSubscription<ProcessSignal>? sigintSub;
    DateTime? firstSigint;
    sigintSub = ProcessSignal.sigint.watch().listen((_) {
      final now = DateTime.now();
      final first = firstSigint;
      if (first != null && now.difference(first) < const Duration(seconds: 3)) {
        // Double SIGINT — force exit.
        _exitFn(1);
      }
      firstSigint = now;
      printer.workflowCancelling();
      final runId = activeRunId;
      if (runId != null) {
        unawaited(service.cancel(runId));
      }
    });

    try {
      final run = await service.start(definition, variables, projectId: projectId, headless: true);
      activeRunId = run.id;
      printer.workflowStarted();

      final finalRun = await runCompleter.future;

      return switch (finalRun.status) {
        WorkflowRunStatus.completed => () {
          printer.workflowCompleted(finalRun.currentStepIndex, finalRun.totalTokens);
          return 0;
        }(),
        WorkflowRunStatus.paused => () {
          final approval = lastApprovalEvent;
          if (approval != null) {
            printer.workflowApprovalPaused(
              finalRun.currentStepIndex - 1,
              approval.stepId,
              approval.message,
            );
          } else {
            printer.workflowPaused(finalRun.currentStepIndex, finalRun.errorMessage);
          }
          return 2;
        }(),
        WorkflowRunStatus.failed || WorkflowRunStatus.cancelled => () {
          printer.workflowFailed(finalRun.currentStepIndex, finalRun.errorMessage ?? 'Cancelled');
          return 1;
        }(),
        _ => 1,
      };
    } finally {
      await runSub.cancel();
      await stepSub.cancel();
      await taskSub.cancel();
      await sigintSub.cancel();
      await approvalSub.cancel();
    }
  }

  Map<String, String> _parseVariables(List<String> varArgs) {
    final variables = <String, String>{};
    for (final arg in varArgs) {
      final eqIndex = arg.indexOf('=');
      if (eqIndex < 1) {
        throw UsageException(
          'Invalid variable format: "$arg" (expected KEY=VALUE)',
          usage,
        );
      }
      final key = arg.substring(0, eqIndex);
      final value = arg.substring(eqIndex + 1);
      variables[key] = value;
    }
    return variables;
  }
}
