import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart' show ArgResults;
import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;
import 'package:dartclaw_core/dartclaw_core.dart' show Task;
import 'package:dartclaw_storage/dartclaw_storage.dart'
    show SqliteTaskRepository, SqliteWorkflowRunRepository, openTaskDb, TaskDbFactory;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowRun;

import '../../dartclaw_api_client.dart';
import '../config_loader.dart';
import '../serve_command.dart' show ExitFn, WriteLine;

/// Shows workflow run status from the server by default, with a standalone fallback.
class WorkflowStatusCommand extends Command<void> {
  final DartclawConfig? _config;
  final TaskDbFactory _taskDbFactory;
  final DartclawApiClient? _apiClient;
  final WriteLine _writeLine;
  final ExitFn _exitFn;

  WorkflowStatusCommand({
    DartclawConfig? config,
    TaskDbFactory? taskDbFactory,
    DartclawApiClient? apiClient,
    WriteLine? writeLine,
    ExitFn? exitFn,
  }) : _config = config,
       _taskDbFactory = taskDbFactory ?? openTaskDb,
       _apiClient = apiClient,
       _writeLine = writeLine ?? stdout.writeln,
       _exitFn = exitFn ?? exit {
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

    final apiClient = _resolveApiClient();
    try {
      final run = await apiClient.getObject('/api/workflows/runs/$runId');
      if (argResults!['json'] as bool) {
        _writeLine(const JsonEncoder.withIndent('  ').convert(run));
      } else {
        _printApiTable(run);
      }
    } on DartclawApiException catch (error) {
      _writeLine(error.message);
      _exitFn(1);
    }
  }

  DartclawApiClient _resolveApiClient() {
    if (_apiClient != null) {
      return _apiClient;
    }
    final config = _config ?? loadCliConfig(configPath: _globalOptionString(globalResults, 'config'));
    return DartclawApiClient.fromConfig(
      config: config,
      serverOverride: _serverOverride(globalResults),
      tokenOverride: _globalOptionString(globalResults, 'token'),
    );
  }

  Future<void> _runStandalone(String runId) async {
    final config = _config ?? loadCliConfig(configPath: _globalOptionString(globalResults, 'config'));
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
      } catch (_) {
        _writeLine('No workflow data found (database may not be initialized).');
        _exitFn(1);
      }

      if (run == null) {
        _writeLine('Workflow run not found: $runId');
        _exitFn(1);
      }

      final taskRepository = SqliteTaskRepository(taskDb);
      final childTasks = (await taskRepository.list()).where((task) => task.workflowRunId == runId).toList()
        ..sort((a, b) => (a.stepIndex ?? 0).compareTo(b.stepIndex ?? 0));

      if (argResults!['json'] as bool) {
        _writeLine(
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
    _writeLine('Workflow Run: ${run['id']}');
    _writeLine('  Definition:  ${run['definitionName']}');
    _writeLine('  Status:      ${run['status']}');
    _writeLine('  Started:     ${_formatDateTime(run['startedAt']?.toString())}');
    if (run['completedAt'] != null) {
      _writeLine('  Completed:   ${_formatDateTime(run['completedAt']?.toString())}');
    }
    final steps = ((run['steps'] as List?) ?? const [])
        .map((step) => Map<String, dynamic>.from(step as Map))
        .toList(growable: false);
    _writeLine(
      '  Steps:       ${steps.where((step) => step['status'] == 'completed').length}/${steps.length} completed',
    );
    _writeLine('  Tokens:      ${_formatNumber((run['totalTokens'] as num?)?.toInt() ?? 0)}');
    if (run['errorMessage'] != null) {
      _writeLine('  Error:       ${run['errorMessage']}');
    }

    if (steps.isEmpty) {
      return;
    }
    _writeLine('');
    _writeLine('  ${'STEP'.padRight(6)}  ${'NAME'.padRight(30)}  ${'STATUS'.padRight(18)}  TASK');
    for (var index = 0; index < steps.length; index++) {
      final step = Map<String, dynamic>.from(steps[index]);
      final label = '${index + 1}/${steps.length}'.padRight(6);
      final name = _truncate(step['name']?.toString() ?? '', 30).padRight(30);
      final status = (step['status']?.toString() ?? 'pending').padRight(18);
      final taskId = step['taskId']?.toString() ?? '—';
      _writeLine('  $label  $name  $status  $taskId');
    }
  }

  void _printStandaloneTable(WorkflowRun run, List<Task> childTasks) {
    _writeLine('Workflow Run: ${run.id}');
    _writeLine('  Definition:  ${run.definitionName}');
    final pendingApprovalStepId = run.contextJson['_approval.pending.stepId'] as String?;
    final isApprovalPaused = run.status.name == 'paused' && pendingApprovalStepId != null;
    final statusDisplay = isApprovalPaused ? 'paused (awaiting approval)' : run.status.name;
    _writeLine('  Status:      $statusDisplay');
    _writeLine('  Started:     ${_formatDateTime(run.startedAt.toIso8601String())}');
    if (run.completedAt != null) {
      _writeLine('  Completed:   ${_formatDateTime(run.completedAt!.toIso8601String())}');
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

    if (childTasks.isEmpty) {
      return;
    }
    _writeLine('');
    _writeLine(
      '  ${'STEP'.padRight(6)}  ${'NAME'.padRight(30)}  ${'STATUS'.padRight(10)}  ${'TOKENS'.padRight(8)}  DURATION',
    );
    for (final task in childTasks) {
      final stepNum = task.stepIndex != null ? '${task.stepIndex! + 1}' : '?';
      final totalStr = _totalSteps(run).toString();
      final stepLabel = '$stepNum/$totalStr'.padRight(6);
      final name = _truncate(task.title, 30).padRight(30);
      final status = task.status.name.padRight(10);
      final tokens = '—'.padRight(8);
      final duration = _taskDuration(task);
      _writeLine('  $stepLabel  $name  $status  $tokens  $duration');
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
    final end = task.completedAt ?? DateTime.now();
    final duration = end.difference(task.startedAt!);
    if (duration.inMinutes > 0) {
      return '${duration.inMinutes}m ${duration.inSeconds % 60}s';
    }
    return '${duration.inSeconds}s';
  }
}

String _truncate(String value, int width) {
  if (value.length <= width) {
    return value;
  }
  return '${value.substring(0, width - 3)}...';
}

String _formatDateTime(String? value) {
  if (value == null || value.isEmpty) {
    return '—';
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    return value;
  }
  return '${parsed.year}-${parsed.month.toString().padLeft(2, '0')}-${parsed.day.toString().padLeft(2, '0')} '
      '${parsed.hour.toString().padLeft(2, '0')}:${parsed.minute.toString().padLeft(2, '0')}:${parsed.second.toString().padLeft(2, '0')}';
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

String? _serverOverride(ArgResults? results) {
  return _globalOptionString(results, 'server');
}

String? _globalOptionString(ArgResults? results, String name) {
  if (results == null) return null;
  try {
    return results[name] as String?;
  } on ArgumentError {
    return null;
  }
}
