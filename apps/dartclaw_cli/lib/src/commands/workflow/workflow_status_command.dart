import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show Task, formatLocalDateTime, humanizeSpan, truncate;
import 'package:dartclaw_storage/dartclaw_storage.dart'
    show SqliteAgentExecutionRepository, SqliteTaskRepository, SqliteWorkflowRunRepository, openTaskDb, TaskDbFactory;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowRun, WorkflowRunStatus;

import '../config_loader.dart';
import '../connected_command_support.dart' hide truncate;

/// Shows workflow run status from the server by default, with a standalone fallback.
class WorkflowStatusCommand extends ConnectedCommand {
  final TaskDbFactory _taskDbFactory;
  final String? _currentDirectory;
  final Map<String, String>? _environment;

  WorkflowStatusCommand({
    super.config,
    TaskDbFactory? taskDbFactory,
    String? currentDirectory,
    Map<String, String>? environment,
    super.apiClient,
    super.writeLine,
    super.exitFn,
  }) : _taskDbFactory = taskDbFactory ?? openTaskDb,
       _currentDirectory = currentDirectory,
       _environment = environment {
    argParser
      ..addFlag('json', negatable: false, help: 'Output as JSON')
      ..addFlag('standalone', negatable: false, help: 'Read workflow status directly from the local tasks database');
  }

  @override
  String get name => 'status';

  @override
  String get description => 'Show workflow run status';

  @override
  String get invocation => '${runner!.executableName} workflow status <runId>';

  @override
  Future<void> run() async {
    final args = argResults!.rest;
    if (args.isEmpty) {
      throw UsageException('Run ID required', usage);
    }
    final runId = args.first;

    if (argResults!['standalone'] as bool) {
      await _runStandalone(runId);
      return;
    }

    await runConnected((apiClient) async {
      final run = await apiClient.getObject('/api/workflows/runs/$runId');
      if (argResults!['json'] as bool) {
        writeLine(const JsonEncoder.withIndent('  ').convert(run));
      } else {
        _printApiTable(run);
      }
    });
  }

  Future<void> _runStandalone(String runId) async {
    final configPath = resolveStandaloneWorkflowConfigPath(
      configPath: globalOptionString(globalResults, 'config'),
      currentDirectory: _currentDirectory,
      env: _environment,
    );
    final config = injectedConfig ?? loadCliConfig(configPath: configPath, env: _environment);
    final dataDir = config.server.dataDir;
    if (!Directory(dataDir).existsSync()) {
      writeLine('No data directory found at $dataDir');
      exitFn(1);
    }

    final taskDb = _taskDbFactory(config.tasksDbPath);
    try {
      SqliteAgentExecutionRepository(taskDb);
      final repository = SqliteWorkflowRunRepository(taskDb);
      WorkflowRun? run;
      try {
        run = await repository.getById(runId);
      } catch (_) {
        // DB not initialised or schema mismatch — user-visible message is the diagnostic.
        writeLine('No workflow data found (database may not be initialized).');
        exitFn(1);
      }

      if (run == null) {
        writeLine('Workflow run not found: $runId');
        exitFn(1);
      }

      final taskRepository = SqliteTaskRepository(taskDb);
      final childTasks = (await taskRepository.list()).where((task) => task.workflowRunId == runId).toList()
        ..sort((a, b) => (a.stepIndex ?? 0).compareTo(b.stepIndex ?? 0));

      if (argResults!['json'] as bool) {
        writeLine(
          const JsonEncoder.withIndent(
            '  ',
          ).convert({...run.toJson(), 'steps': childTasks.map((t) => t.toJson()).toList()}),
        );
      } else {
        _printStandaloneTable(run, childTasks);
      }
    } finally {
      taskDb.close();
    }
  }

  void _printApiTable(Map<String, dynamic> run) {
    writeLine('Workflow Run: ${run['id']}');
    writeLine('  Definition:  ${run['definitionName']}');
    writeLine('  Status:      ${run['status']}');
    writeLine('  Started:     ${formatLocalDateTime(run['startedAt']?.toString())}');
    if (run['completedAt'] != null) {
      writeLine('  Completed:   ${formatLocalDateTime(run['completedAt']?.toString())}');
    }
    final steps = ((run['steps'] as List?) ?? const [])
        .map((step) => Map<String, dynamic>.from(step as Map))
        .toList(growable: false);
    writeLine(
      '  Steps:       ${steps.where((step) => step['status'] == 'completed').length}/${steps.length} completed',
    );
    writeLine('  Tokens:      ${_formatNumber((run['totalTokens'] as num?)?.toInt() ?? 0)}');
    if (run['errorMessage'] != null) {
      writeLine('  Error:       ${run['errorMessage']}');
    }

    if (steps.isEmpty) {
      return;
    }
    writeLine('');
    writeLine('  ${'STEP'.padRight(6)}  ${'NAME'.padRight(30)}  ${'STATUS'.padRight(18)}  TASK');
    for (var index = 0; index < steps.length; index++) {
      final step = Map<String, dynamic>.from(steps[index]);
      final label = '${index + 1}/${steps.length}'.padRight(6);
      final name = truncate(step['name']?.toString() ?? '', 30, suffix: '...').padRight(30);
      final status = (step['status']?.toString() ?? 'pending').padRight(18);
      final taskId = step['taskId']?.toString() ?? '—';
      writeLine('  $label  $name  $status  $taskId');
    }
  }

  void _printStandaloneTable(WorkflowRun run, List<Task> childTasks) {
    writeLine('Workflow Run: ${run.id}');
    writeLine('  Definition:  ${run.definitionName}');
    final pendingApprovalStepId = run.contextJson['_approval.pending.stepId'] as String?;
    final isAwaitingApproval =
        pendingApprovalStepId != null &&
        (run.status == WorkflowRunStatus.awaitingApproval || run.status == WorkflowRunStatus.paused);
    final statusDisplay = isAwaitingApproval ? 'paused (awaiting approval)' : run.status.name;
    writeLine('  Status:      $statusDisplay');
    writeLine('  Started:     ${formatLocalDateTime(run.startedAt.toIso8601String())}');
    if (run.completedAt != null) {
      writeLine('  Completed:   ${formatLocalDateTime(run.completedAt!.toIso8601String())}');
    }
    writeLine('  Steps:       ${run.currentStepIndex}/${_totalSteps(run)} completed');
    writeLine('  Tokens:      ${_formatNumber(run.totalTokens)}');
    if (isAwaitingApproval) {
      final approvalMessage = run.contextJson['$pendingApprovalStepId.approval.message'] as String?;
      writeLine('  Approval:    Step "$pendingApprovalStepId" is awaiting approval');
      if (approvalMessage != null) {
        writeLine('  Request:     $approvalMessage');
      }
      writeLine('  Actions:     Run `dartclaw workflow resume ${run.id} --standalone` to approve');
      writeLine('               Run `dartclaw workflow cancel ${run.id} --standalone` to reject');
    } else if (run.status == WorkflowRunStatus.failed) {
      writeLine('  Actions:     Run `dartclaw workflow retry ${run.id} --standalone` to retry');
    }
    if (run.errorMessage != null) {
      writeLine('  Error:       ${run.errorMessage}');
    }

    if (childTasks.isEmpty) {
      return;
    }
    writeLine('');
    writeLine(
      '  ${'STEP'.padRight(6)}  ${'NAME'.padRight(30)}  ${'STATUS'.padRight(10)}  ${'TOKENS'.padRight(8)}  DURATION',
    );
    for (final task in childTasks) {
      final stepNum = task.stepIndex != null ? '${task.stepIndex! + 1}' : '?';
      final totalStr = _totalSteps(run).toString();
      final stepLabel = '$stepNum/$totalStr'.padRight(6);
      final name = truncate(task.title, 30, suffix: '...').padRight(30);
      final status = task.status.name.padRight(10);
      final tokens = '—'.padRight(8);
      final duration = _taskDuration(task);
      writeLine('  $stepLabel  $name  $status  $tokens  $duration');
    }
  }

  int _totalSteps(WorkflowRun run) {
    final steps = run.definitionJson['steps'];
    if (steps is List) {
      return steps.length;
    }
    return 0;
  }

  String _taskDuration(Task task) {
    if (task.startedAt == null) {
      return '—';
    }
    return humanizeSpan(task.startedAt!, task.completedAt, false, false);
  }
}

String _formatNumber(int value) {
  final raw = value.toString();
  final buffer = StringBuffer();
  for (var index = 0; index < raw.length; index++) {
    if (index > 0 && (raw.length - index) % 3 == 0) {
      buffer.write(',');
    }
    buffer.write(raw[index]);
  }
  return buffer.toString();
}
