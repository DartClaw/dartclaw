import 'workflow_connected_command.dart';
import '../command_path.dart';

import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_core/dartclaw_core.dart'
    show FileExecutionStore, FileTaskRepository, Task, TaskRepository, formatLocalDateTime, humanizeSpan;
import 'package:dartclaw_core/dartclaw_core.dart' show DatabaseTaskRepository, PostgresSchemaGate;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show DatabaseWorkflowRunRepository, WorkflowDefinition, WorkflowRun, WorkflowStep, workflowContextValue;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show FileWorkflowRunRepository, WorkflowRunRepository;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show scrubAgentReportedText;

import '../config_loader.dart';
import '../connected_command_support.dart' hide truncate;

/// Shows workflow run status from the server or the standalone file store.
class WorkflowStatusCommand extends WorkflowConnectedCommand {
  final DatabaseBackendFactory? _taskBackendFactory;
  final bool _taskBackendIsPrepared;
  final TaskRepository Function(DatabaseBackend)? _taskRepositoryFactory;
  final WorkflowRunRepository Function(DatabaseBackend)? _workflowRunRepositoryFactory;
  final String? _currentDirectory;
  final Map<String, String>? _environment;

  final bool standaloneOnly;

  new({
    this.standaloneOnly = false,
    super.config,
    DatabaseBackendFactory? taskBackendFactory,
    bool taskBackendIsPrepared = false,
    TaskRepository Function(DatabaseBackend)? taskRepositoryFactory,
    WorkflowRunRepository Function(DatabaseBackend)? workflowRunRepositoryFactory,
    String? currentDirectory,
    Map<String, String>? environment,
    super.connection,
    super.writeLine,
    super.exitFn,
  }) : _taskBackendFactory = taskBackendFactory,
       _taskBackendIsPrepared = taskBackendIsPrepared,
       _taskRepositoryFactory = taskRepositoryFactory,
       _workflowRunRepositoryFactory = workflowRunRepositoryFactory,
       _currentDirectory = currentDirectory,
       _environment = environment {
    argParser
      ..addFlag('json', negatable: false, help: 'Output as JSON')
      ..addFlag(
        'standalone',
        negatable: false,
        help: standaloneOnly
            ? 'Always on; accepted for script compatibility.'
            : 'Read workflow status from the local standalone execution file',
      );
  }

  @override
  String get name => 'status';

  @override
  String get description => 'Show workflow run status';

  @override
  String get invocation => '${commandPath(this)} <runId>';

  @override
  Future<void> run() async {
    final args = argResults!.rest;
    if (args.isEmpty) {
      throw UsageException('Run ID required', usage);
    }
    final runId = args.first;

    if (standaloneOnly || argResults!['standalone'] as bool) {
      await _runStandalone(runId);
      return;
    }

    await connection!.status(connectionContext, runId, (run) {
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
    if (_taskBackendFactory != null) {
      await _runWithInjectedBackend(runId, config);
      return;
    }

    final path = config.standaloneExecutionPath;
    if (!File(path).existsSync()) {
      writeLine('No standalone workflow data found at $path. Existing PostgreSQL runs are not imported.');
      exitFn(1);
    }
    final FileExecutionStore store;
    try {
      store = await FileExecutionStore.open(path);
    } on FormatException catch (error) {
      writeLine(error.message);
      exitFn(1);
    }
    try {
      await _printStoredRun(runId, FileWorkflowRunRepository(store), FileTaskRepository(store));
    } finally {
      await store.close();
    }
  }

  Future<void> _runWithInjectedBackend(String runId, DartclawConfig config) async {
    final backend = await _taskBackendFactory!(config.dartclawDbPath);
    try {
      if (!_taskBackendIsPrepared) {
        await PostgresSchemaGate.validateCurrent(backend, databaseIdentity: 'configured PostgreSQL database');
      }
      await _printStoredRun(
        runId,
        _workflowRunRepositoryFactory?.call(backend) ?? DatabaseWorkflowRunRepository(backend),
        _taskRepositoryFactory?.call(backend) ?? DatabaseTaskRepository(backend),
      );
    } finally {
      await backend.close();
    }
  }

  Future<void> _printStoredRun(String runId, WorkflowRunRepository runs, TaskRepository tasks) async {
    final run = await runs.getById(runId);
    if (run == null) {
      writeLine('Standalone workflow run not found: $runId');
      exitFn(1);
    }

    final childTasks = (await tasks.list()).where((task) => task.workflowRunId == runId).toList()
      ..sort((a, b) => (a.stepIndex ?? 0).compareTo(b.stepIndex ?? 0));

    if (argResults!['json'] as bool) {
      writeLine(
        const JsonEncoder.withIndent('  ')
            .convert({...run.toJson(), 'steps': childTasks.map((t) => t.toJson()).toList()}),
      );
    } else {
      _printStandaloneTable(run, childTasks);
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
    writeLine(
      '  Tokens:      ${_formatNumber((run['totalTokens'] as num?)?.toInt() ?? 0)}${run['tokenUsageComplete'] == true ? '' : ' (incomplete lower bound)'}',
    );
    _printApiWhyPaused(run);
    if (run['errorMessage'] != null) {
      writeLine('  Error:       ${scrubAgentReportedText('${run['errorMessage']}')}');
    }

    if (steps.isEmpty) {
      return;
    }
    writeLine('');
    writeLine(
      '  ${'STEP'.padRight(6)}  ${'NAME'.padRight(30)}  ${'STATUS'.padRight(18)}  ${'TOKENS'.padRight(11)}  TASK',
    );
    for (var index = 0; index < steps.length; index++) {
      final step = Map<String, dynamic>.from(steps[index]);
      final label = '${index + 1}/${steps.length}'.padRight(6);
      final name = truncate(step['name']?.toString() ?? '', 30, suffix: '...').padRight(30);
      final rawStatus = step['status']?.toString() ?? 'pending';
      final status = rawStatus.padRight(18);
      final tokens = step['tokenCount'] is num
          ? _formatNumber((step['tokenCount'] as num).toInt())
          : switch (rawStatus) {
              'skipped' => '0',
              'pending' => '—',
              _ => 'unavailable',
            };
      final taskId = step['taskId']?.toString() ?? '—';
      writeLine('  $label  $name  $status  ${tokens.padRight(11)}  $taskId');
      final reason = step['reason']?.toString();
      if (reason != null && reason.isNotEmpty) {
        writeLine('          Reason: ${scrubAgentReportedText(reason)}');
      }
    }
  }

  /// Appends the same why-paused / what-to-do synthesis the standalone table
  /// prints, sourced from the connected enriched-detail payload
  /// (`isApprovalPaused`, `pendingApprovalStepId`) plus the pending step's
  /// message at the flat context key `<stepId>.approval.message` — the same key
  /// the standalone path reads, so approval *and* needsInput holds both surface
  /// their reason.
  void _printApiWhyPaused(Map<String, dynamic> run) {
    final runId = run['id'];
    if (run['isApprovalPaused'] == true) {
      final pendingStepId = run['pendingApprovalStepId']?.toString();
      writeLine('  Approval:    Step "$pendingStepId" is awaiting approval');
      final contextJson = (run['contextJson'] as Map?) ?? const {};
      final approvalMessage = contextJson['$pendingStepId.approval.message']?.toString();
      if (approvalMessage != null && approvalMessage.isNotEmpty) {
        writeLine('  Request:     ${scrubAgentReportedText(approvalMessage)}');
      }
      writeLine('  Actions:     Run `${commandPrefix(this)} resume $runId` to approve');
      writeLine('               Run `${commandPrefix(this)} cancel $runId` to reject');
    } else if (run['status'] == 'paused') {
      writeLine('  Actions:     Run `${commandPrefix(this)} resume $runId` to continue');
    } else if (run['status'] == 'failed') {
      writeLine('  Actions:     Run `${commandPrefix(this)} retry $runId` to retry');
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
    writeLine(
      '  Tokens:      ${_formatNumber(run.totalTokens)}${run.tokenUsageComplete ? '' : ' (incomplete lower bound)'}',
    );
    if (isAwaitingApproval) {
      final approvalMessage = run.contextJson['$pendingApprovalStepId.approval.message'] as String?;
      writeLine('  Approval:    Step "$pendingApprovalStepId" is awaiting approval');
      if (approvalMessage != null) {
        writeLine('  Request:     ${scrubAgentReportedText(approvalMessage)}');
      }
      writeLine('  Actions:     Run `${commandPrefix(this)} resume ${run.id} --standalone` to approve');
      writeLine('               Run `${commandPrefix(this)} cancel ${run.id} --standalone` to reject');
    } else if (run.status == WorkflowRunStatus.failed) {
      writeLine('  Actions:     Run `${commandPrefix(this)} retry ${run.id} --standalone` to retry');
    }
    if (run.errorMessage != null) {
      writeLine('  Error:       ${scrubAgentReportedText(run.errorMessage!)}');
    }

    WorkflowDefinition? definition;
    try {
      definition = WorkflowDefinition.fromJson(run.definitionJson);
    } catch (_) {}
    for (final step in definition?.steps ?? const <WorkflowStep>[]) {
      if (workflowContextValue(run, '${step.id}.status') != 'failed') continue;
      final reason =
          workflowContextValue(run, 'step.${step.id}.outcome.reason') ?? workflowContextValue(run, '${step.id}.error');
      writeLine('  Step error:  ${step.name}${reason == null ? '' : ': ${scrubAgentReportedText('$reason')}'}');
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
      final name = truncate(scrubAgentReportedText(task.title), 30, suffix: '...').padRight(30);
      final status = task.status.name.padRight(10);
      final stepId = task.stepIndex != null && definition != null && task.stepIndex! < definition.steps.length
          ? definition.steps[task.stepIndex!].id
          : null;
      final count = stepId == null ? null : workflowContextValue(run, '$stepId.tokenCount');
      final tokens = (count is num ? _formatNumber(count.toInt()) : 'unavailable').padRight(8);
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
