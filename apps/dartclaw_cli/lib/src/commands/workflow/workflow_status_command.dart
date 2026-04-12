import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;
import 'package:dartclaw_core/dartclaw_core.dart' show Task;
import 'package:dartclaw_storage/dartclaw_storage.dart'
    show SqliteTaskRepository, SqliteWorkflowRunRepository, openTaskDb, TaskDbFactory;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowRun;

import '../config_loader.dart';
import '../serve_command.dart' show ExitFn, WriteLine;

/// Shows status of an existing workflow run from persisted state.
///
/// Opens [tasks.db] directly (no running server required) and displays
/// the run's current state plus step-level detail from child tasks.
class WorkflowStatusCommand extends Command<void> {
  final DartclawConfig? _config;
  final TaskDbFactory _taskDbFactory;
  final WriteLine _writeLine;
  final ExitFn _exitFn;

  WorkflowStatusCommand({DartclawConfig? config, TaskDbFactory? taskDbFactory, WriteLine? writeLine, ExitFn? exitFn})
    : _config = config,
      _taskDbFactory = taskDbFactory ?? openTaskDb,
      _writeLine = writeLine ?? stdout.writeln,
      _exitFn = exitFn ?? exit {
    argParser.addFlag('json', negatable: false, help: 'Output as JSON');
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

    final config = _config ?? loadCliConfig(configPath: globalResults?['config'] as String?);
    final dataDir = config.server.dataDir;

    if (!Directory(dataDir).existsSync()) {
      _writeLine('No data directory found at $dataDir');
      _exitFn(1);
    }

    final taskDb = _taskDbFactory(config.tasksDbPath);
    try {
      final repository = SqliteWorkflowRunRepository(taskDb);
      WorkflowRun? run;
      try {
        run = await repository.getById(runId);
      } catch (e) {
        _writeLine('No workflow data found (database may not be initialized).');
        taskDb.close();
        _exitFn(1);
      }

      if (run == null) {
        _writeLine('Workflow run not found: $runId');
        taskDb.close();
        _exitFn(1);
      }

      final taskRepository = SqliteTaskRepository(taskDb);
      final allTasks = await taskRepository.list();
      final childTasks = allTasks.where((t) => t.workflowRunId == runId).toList()
        ..sort((a, b) => (a.stepIndex ?? 0).compareTo(b.stepIndex ?? 0));

      if (argResults!['json'] as bool) {
        _printJson(run, childTasks);
      } else {
        _printTable(run, childTasks);
      }
    } finally {
      taskDb.close();
    }
  }

  void _printJson(WorkflowRun? run, List<Task> childTasks) {
    if (run == null) return;
    final json = {...run.toJson(), 'steps': childTasks.map((t) => t.toJson()).toList()};
    _writeLine(const JsonEncoder.withIndent('  ').convert(json));
  }

  void _printTable(WorkflowRun? run, List<Task> childTasks) {
    if (run == null) return;
    _writeLine('Workflow Run: ${run.id}');
    _writeLine('  Definition:  ${run.definitionName}');

    // Surface approval context for approval-paused runs.
    final pendingApprovalStepId = run.contextJson['_approval.pending.stepId'] as String?;
    final isApprovalPaused = run.status.name == 'paused' && pendingApprovalStepId != null;
    final statusDisplay = isApprovalPaused ? 'paused (awaiting approval)' : run.status.name;
    _writeLine('  Status:      $statusDisplay');

    _writeLine('  Started:     ${_formatDateTime(run.startedAt)}');
    if (run.completedAt != null) {
      _writeLine('  Completed:   ${_formatDateTime(run.completedAt!)}');
    }
    _writeLine('  Steps:       ${run.currentStepIndex}/${_totalSteps(run)} completed');
    _writeLine('  Tokens:      ${_formatNumber(run.totalTokens)}');

    if (isApprovalPaused) {
      final approvalMessage = run.contextJson['$pendingApprovalStepId.approval.message'] as String?;
      _writeLine('  Approval:    Step "$pendingApprovalStepId" is awaiting approval');
      if (approvalMessage != null) {
        _writeLine('  Request:     $approvalMessage');
      }
      _writeLine('  Actions:     `dartclaw workflow resume ${run.id}` to approve');
      _writeLine('               `dartclaw workflow cancel ${run.id}` to reject');
    }

    if (run.errorMessage != null) {
      _writeLine('  Error:       ${run.errorMessage}');
    }

    if (childTasks.isNotEmpty) {
      _writeLine('');
      _writeLine(
        '  ${'STEP'.padRight(6)}  ${'NAME'.padRight(30)}  ${'STATUS'.padRight(10)}  ${'TOKENS'.padRight(8)}  DURATION',
      );
      for (final task in childTasks) {
        final stepNum = task.stepIndex != null ? '${task.stepIndex! + 1}' : '?';
        final totalStr = _totalSteps(run).toString();
        final stepLabel = '$stepNum/$totalStr'.padRight(6);
        final name = (task.title.length > 30 ? '${task.title.substring(0, 27)}...' : task.title).padRight(30);
        final status = task.status.name.padRight(10);
        final tokens = '—'.padRight(8);
        final duration = _taskDuration(task);
        _writeLine('  $stepLabel  $name  $status  $tokens  $duration');
      }
    }
  }

  int _totalSteps(WorkflowRun run) {
    final steps = run.definitionJson['steps'];
    if (steps is List) return steps.length;
    return 0;
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.year}-${_pad(dt.month)}-${_pad(dt.day)} '
        '${_pad(dt.hour)}:${_pad(dt.minute)}:${_pad(dt.second)}';
  }

  String _pad(int n) => n.toString().padLeft(2, '0');

  String _formatNumber(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }

  String _taskDuration(Task task) {
    if (task.startedAt == null) return '—';
    final end = task.completedAt ?? DateTime.now();
    final d = end.difference(task.startedAt!);
    if (d.inMinutes > 0) {
      return '${d.inMinutes}m ${d.inSeconds % 60}s';
    }
    return '${d.inSeconds}s';
  }
}
