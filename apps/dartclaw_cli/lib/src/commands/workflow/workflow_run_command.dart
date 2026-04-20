import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart' show ArgResults;
import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;
import 'package:dartclaw_core/dartclaw_core.dart'
    show
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
import 'package:dartclaw_server/dartclaw_server.dart' show TaskService, WorkspaceService;
import 'package:dartclaw_storage/dartclaw_storage.dart' show SearchDbFactory, TaskDbFactory;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show WorkflowService;

import '../../dartclaw_api_client.dart';
import '../config_loader.dart';
import '../serve_command.dart' show ExitFn, WriteLine;
import 'cli_progress_printer.dart';
import 'cli_workflow_wiring.dart';
import 'credential_preflight.dart';

/// Runs a workflow either against a live server or in standalone mode.
class WorkflowRunCommand extends Command<void> {
  final DartclawConfig? _config;
  final SearchDbFactory? _searchDbFactory;
  final TaskDbFactory? _taskDbFactory;
  final HarnessFactory? _harnessFactory;
  final DartclawApiClient? _apiClient;
  final Map<String, String>? _environment;
  final WriteLine _stdoutLine;
  final WriteLine _stderrLine;
  final ExitFn _exitFn;
  final Stream<void> Function() _interrupts;

  WorkflowRunCommand({
    DartclawConfig? config,
    SearchDbFactory? searchDbFactory,
    TaskDbFactory? taskDbFactory,
    HarnessFactory? harnessFactory,
    DartclawApiClient? apiClient,
    Map<String, String>? environment,
    WriteLine? stdoutLine,
    WriteLine? stderrLine,
    ExitFn? exitFn,
    Stream<void> Function()? interrupts,
  }) : _config = config,
       _searchDbFactory = searchDbFactory,
       _taskDbFactory = taskDbFactory,
       _harnessFactory = harnessFactory,
       _apiClient = apiClient,
       _environment = environment,
       _stdoutLine = stdoutLine ?? stdout.writeln,
       _stderrLine = stderrLine ?? stderr.writeln,
       _exitFn = exitFn ?? exit,
       _interrupts = interrupts ?? (() => ProcessSignal.sigint.watch().map((_) {})) {
    argParser
      ..addMultiOption('var', abbr: 'v', help: 'Variable (KEY=VALUE)', valueHelp: 'KEY=VALUE', splitCommas: false)
      ..addOption('project', abbr: 'p', help: 'Project ID for project-scoped steps')
      ..addFlag('standalone', negatable: false, help: 'Run the workflow in-process without using the server API')
      ..addFlag('force', negatable: false, help: 'Bypass the standalone safety check')
      ..addFlag('json', negatable: false, help: 'Output structured JSON events');
  }

  @override
  String get name => 'run';

  @override
  String get description => 'Run a workflow';

  @override
  String get invocation => '${runner!.executableName} workflow run <name>';

  @override
  Future<void> run() async {
    final args = argResults!.rest;
    if (args.isEmpty) {
      throw UsageException('Workflow name required', usage);
    }
    final workflowName = args.first;
    final variables = _parseVariables(argResults!['var'] as List<String>);
    final projectId = argResults!['project'] as String?;
    final standalone = argResults!['standalone'] as bool;
    final force = argResults!['force'] as bool;
    final jsonOutput = argResults!['json'] as bool;

    if (force && !standalone) {
      throw UsageException('--force can only be used together with --standalone', usage);
    }

    final config = _config ?? loadCliConfig(configPath: _globalOptionString(globalResults, 'config'));
    if (standalone) {
      await _runStandaloneWithSafety(
        config: config,
        workflowName: workflowName,
        variables: variables,
        projectId: projectId,
        force: force,
        jsonOutput: jsonOutput,
      );
      return;
    }

    final apiClient =
        _apiClient ??
        DartclawApiClient.fromConfig(
          config: config,
          serverOverride: _serverOverride(globalResults),
          tokenOverride: _globalOptionString(globalResults, 'token'),
        );
    try {
      await _runConnected(
        apiClient: apiClient,
        workflowName: workflowName,
        variables: variables,
        projectId: projectId,
        jsonOutput: jsonOutput,
      );
    } on DartclawApiException catch (error) {
      _stderrLine(_connectedErrorMessage(error));
      _exitFn(1);
    }
  }

  Future<void> _runStandaloneWithSafety({
    required DartclawConfig config,
    required String workflowName,
    required Map<String, String> variables,
    required String? projectId,
    required bool force,
    required bool jsonOutput,
  }) async {
    final apiClient =
        _apiClient ??
        DartclawApiClient.fromConfig(
          config: config,
          serverOverride: _serverOverride(globalResults),
          tokenOverride: _globalOptionString(globalResults, 'token'),
        );
    final serverReachable = await apiClient.probeHealth();
    if (serverReachable && !force) {
      _stderrLine(
        'A DartClaw server is running at ${apiClient.baseUri.origin}. Use connected mode or add --force to override.',
      );
      _exitFn(1);
    }

    final dataDir = config.server.dataDir;
    Directory(dataDir).createSync(recursive: true);

    final workspace = WorkspaceService(dataDir: dataDir);
    await workspace.migrate();

    final wiring = CliWorkflowWiring(
      config: config,
      dataDir: dataDir,
      environment: _environment,
      harnessFactory: _harnessFactory,
      searchDbFactory: _searchDbFactory,
      taskDbFactory: _taskDbFactory,
    );
    var wired = false;
    try {
      await wiring.wire();
      wired = true;
    } on CredentialPreflightException catch (error) {
      for (final item in error.errors) {
        _stderrLine(item.message);
      }
      _exitFn(1);
    }

    try {
      final definition = wiring.registry.getByName(workflowName);
      if (definition == null) {
        _stderrLine('Unknown workflow: $workflowName');
        final available = wiring.registry.listAll().map((item) => item.name).join(', ');
        if (available.isNotEmpty) {
          _stderrLine('Available: $available');
        }
        _exitFn(1);
      }
      await wiring.ensureTaskRunnersForProviders(_requiredWorkflowProviders(definition, config.agent.provider));

      final printer = CliProgressPrinter(
        totalSteps: definition.steps.length,
        workflowName: definition.name,
        writeLine: _stdoutLine,
      );

      final exitCode = await _runStandalone(
        service: wiring.workflowService,
        taskService: wiring.taskService,
        definition: definition,
        variables: variables,
        eventBus: wiring.eventBus,
        printer: printer,
        projectId: projectId,
        jsonOutput: jsonOutput,
      );
      _exitFn(exitCode);
    } finally {
      if (wired) {
        await wiring.dispose();
      }
    }
  }

  Future<void> _runConnected({
    required DartclawApiClient apiClient,
    required String workflowName,
    required Map<String, String> variables,
    required String? projectId,
    required bool jsonOutput,
  }) async {
    final started = await apiClient.postObject(
      '/api/workflows/run',
      body: {
        'definition': workflowName,
        'variables': variables,
        if (projectId != null && projectId.isNotEmpty) 'project': projectId,
      },
    );
    final run = WorkflowRun.fromJson(started);
    final definition = WorkflowDefinition.fromJson(Map<String, dynamic>.from(started['definitionJson'] as Map));
    final printer = CliProgressPrinter(
      totalSteps: definition.steps.length,
      workflowName: definition.name,
      writeLine: _stdoutLine,
    );

    if (jsonOutput) {
      _stdoutLine(jsonEncode({'type': 'run_started', 'run': started}));
    } else {
      printer.workflowStarted();
    }

    final completer = Completer<int>();
    final startedSteps = <int, DateTime>{};
    var lastStatus = run.status;
    var lastError = run.errorMessage;
    var cancelRequested = false;

    final interruptSub = _interrupts().listen((_) async {
      if (cancelRequested) {
        _exitFn(1);
      }
      cancelRequested = true;
      if (jsonOutput) {
        _stdoutLine(jsonEncode({'type': 'interrupt_received', 'runId': run.id}));
      } else {
        printer.workflowCancelling();
      }
      try {
        await apiClient.post('/api/workflows/runs/${run.id}/cancel');
      } on DartclawApiException catch (error) {
        _stderrLine(error.message);
      }
    });

    try {
      eventLoop:
      await for (final event in apiClient.streamEvents(
        '/api/workflows/runs/${run.id}/events',
        onDisconnect: (attempt) async {
          final refreshed = await apiClient.getObject('/api/workflows/runs/${run.id}');
          final refreshedRun = WorkflowRun.fromJson(refreshed);
          lastStatus = refreshedRun.status;
          lastError = refreshedRun.errorMessage;
          if (lastStatus.terminal ||
              lastStatus == WorkflowRunStatus.paused ||
              lastStatus == WorkflowRunStatus.awaitingApproval) {
            if (!completer.isCompleted) {
              completer.complete(_exitCodeForStatus(lastStatus));
            }
            return false;
          }
          if (jsonOutput) {
            _stdoutLine(
              jsonEncode({
                'type': 'stream_reconnecting',
                'runId': run.id,
                'attempt': attempt,
                'status': lastStatus.name,
              }),
            );
          } else {
            _stderrLine(
              'Workflow event stream disconnected. Reconnecting (attempt $attempt/3) after re-fetching status...',
            );
          }
          return true;
        },
      )) {
        if (jsonOutput) {
          _stdoutLine(jsonEncode(event));
        }
        switch (event['type']) {
          case 'task_status_changed':
            final stepIndex = event['stepIndex'] as int?;
            if (stepIndex == null || stepIndex >= definition.steps.length) {
              break;
            }
            final step = definition.steps[stepIndex];
            final newStatus = event['newStatus']?.toString();
            if (newStatus == TaskStatus.running.name) {
              startedSteps[stepIndex] = DateTime.now();
              if (!jsonOutput) {
                printer.stepRunning(stepIndex, step.id, step.name, step.provider);
              }
            } else if (newStatus == TaskStatus.review.name && !jsonOutput) {
              printer.stepReview(stepIndex, step.id);
            }
            break;
          case 'workflow_step_completed':
            final stepIndex = event['stepIndex'] as int? ?? 0;
            final stepId = event['stepId']?.toString() ?? '';
            final success = event['success'] == true;
            final tokenCount = event['tokenCount'] as int? ?? 0;
            final duration = startedSteps.remove(stepIndex)?.let(DateTime.now().difference) ?? Duration.zero;
            if (!jsonOutput) {
              if (success) {
                printer.stepCompleted(stepIndex, stepId, duration, tokenCount);
              } else {
                printer.stepFailed(stepIndex, stepId, null);
              }
            }
            break;
          case 'workflow_status_changed':
            final newStatusName = event['newStatus']?.toString();
            if (newStatusName == null) {
              break;
            }
            lastStatus = WorkflowRunStatus.values.byName(newStatusName);
            lastError = event['errorMessage']?.toString();
            if (!lastStatus.terminal &&
                lastStatus != WorkflowRunStatus.paused &&
                lastStatus != WorkflowRunStatus.awaitingApproval) {
              break;
            }
            if (!jsonOutput) {
              switch (lastStatus) {
                case WorkflowRunStatus.completed:
                  printer.workflowCompleted(definition.steps.length, event['totalTokens'] as int? ?? run.totalTokens);
                  break;
                case WorkflowRunStatus.failed:
                  printer.workflowFailed((event['currentStepIndex'] as int? ?? 0), lastError);
                  break;
                case WorkflowRunStatus.cancelled:
                  printer.workflowFailed((event['currentStepIndex'] as int? ?? 0), lastError ?? 'Cancelled');
                  break;
                case WorkflowRunStatus.paused:
                  printer.workflowPaused((event['currentStepIndex'] as int? ?? 0), lastError);
                  break;
                case WorkflowRunStatus.awaitingApproval:
                  printer.workflowPaused((event['currentStepIndex'] as int? ?? 0), lastError);
                  break;
                case WorkflowRunStatus.pending || WorkflowRunStatus.running:
                  break;
              }
            }
            if (!completer.isCompleted) {
              completer.complete(_exitCodeForStatus(lastStatus));
            }
            break eventLoop;
          default:
            break;
        }
      }
    } on DartclawApiException catch (error) {
      final refreshed = await apiClient.getObject('/api/workflows/runs/${run.id}');
      lastStatus = WorkflowRun.fromJson(refreshed).status;
      lastError = WorkflowRun.fromJson(refreshed).errorMessage;
      if (lastStatus.terminal ||
          lastStatus == WorkflowRunStatus.paused ||
          lastStatus == WorkflowRunStatus.awaitingApproval) {
        if (!completer.isCompleted) {
          completer.complete(_exitCodeForStatus(lastStatus));
        }
      } else {
        throw DartclawApiException('${error.message} Use `dartclaw workflow status ${run.id}` to inspect the run.');
      }
    } finally {
      await interruptSub.cancel();
    }

    final exitCode = completer.isCompleted ? await completer.future : _exitCodeForStatus(lastStatus);
    if (!jsonOutput && lastStatus == WorkflowRunStatus.cancelled && lastError == null && cancelRequested) {
      _stdoutLine('[workflow] Cancelled: ${run.id}');
    }
    _exitFn(exitCode);
  }

  Future<int> _runStandalone({
    required WorkflowService service,
    required TaskService taskService,
    required WorkflowDefinition definition,
    required Map<String, String> variables,
    required EventBus eventBus,
    required CliProgressPrinter printer,
    String? projectId,
    required bool jsonOutput,
  }) async {
    final runCompleter = Completer<WorkflowRun>();
    String? activeRunId;
    final stepStartTimes = <int, DateTime>{};
    WorkflowApprovalRequestedEvent? lastApprovalEvent;

    final runSub = eventBus.on<WorkflowRunStatusChangedEvent>().listen((event) {
      final runId = activeRunId;
      if (runId != null && event.runId != runId) return;
      if (jsonOutput) {
        _stdoutLine(
          jsonEncode({
            'type': 'workflow_status_changed',
            'runId': event.runId,
            'definitionName': event.definitionName,
            'oldStatus': event.oldStatus.name,
            'newStatus': event.newStatus.name,
            'errorMessage': event.errorMessage,
          }),
        );
      }
      if (event.newStatus.terminal ||
          event.newStatus == WorkflowRunStatus.paused ||
          event.newStatus == WorkflowRunStatus.awaitingApproval) {
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
      if (jsonOutput) {
        _stdoutLine(
          jsonEncode({
            'type': 'workflow_approval_requested',
            'runId': event.runId,
            'stepId': event.stepId,
            'message': event.message,
            'timeoutSeconds': event.timeoutSeconds,
          }),
        );
      }
    });

    final stepSub = eventBus.on<WorkflowStepCompletedEvent>().listen((event) {
      if (activeRunId != null && event.runId != activeRunId) return;
      final startTime = stepStartTimes.remove(event.stepIndex);
      final duration = startTime != null ? DateTime.now().difference(startTime) : Duration.zero;
      if (jsonOutput) {
        _stdoutLine(
          jsonEncode({
            'type': 'workflow_step_completed',
            'runId': event.runId,
            'stepId': event.stepId,
            'stepIndex': event.stepIndex,
            'totalSteps': event.totalSteps,
            'taskId': event.taskId,
            'success': event.success,
            'tokenCount': event.tokenCount,
            'durationMs': duration.inMilliseconds,
          }),
        );
        return;
      }
      if (event.success) {
        printer.stepCompleted(event.stepIndex, event.stepId, duration, event.tokenCount);
      } else {
        printer.stepFailed(event.stepIndex, event.stepId, null);
      }
    });

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
          }
          if (jsonOutput) {
            _stdoutLine(
              jsonEncode({
                'type': 'task_status_changed',
                'runId': runId,
                'taskId': event.taskId,
                'stepIndex': stepIndex,
                'stepId': stepId,
                'oldStatus': event.oldStatus.name,
                'newStatus': event.newStatus.name,
              }),
            );
            return;
          }
          if (event.newStatus == TaskStatus.running) {
            printer.stepRunning(stepIndex, stepId, task.title, task.provider ?? definition.steps[stepIndex].provider);
          } else {
            printer.stepReview(stepIndex, stepId);
          }
        });
      }
    });

    StreamSubscription<void>? sigintSub;
    DateTime? firstSigint;
    sigintSub = _interrupts().listen((_) {
      final now = DateTime.now();
      final first = firstSigint;
      if (first != null && now.difference(first) < const Duration(seconds: 3)) {
        _exitFn(1);
      }
      firstSigint = now;
      if (jsonOutput) {
        _stdoutLine(jsonEncode({'type': 'interrupt_received', 'runId': activeRunId}));
      } else {
        printer.workflowCancelling();
      }
      final runId = activeRunId;
      if (runId != null) {
        unawaited(service.cancel(runId));
      }
    });

    try {
      final run = await service.start(definition, variables, projectId: projectId, headless: true);
      activeRunId = run.id;
      if (jsonOutput) {
        _stdoutLine(jsonEncode({'type': 'run_started', 'run': run.toJson()}));
      } else {
        printer.workflowStarted();
      }

      final finalRun = await runCompleter.future;
      return switch (finalRun.status) {
        WorkflowRunStatus.completed => () {
          if (!jsonOutput) {
            printer.workflowCompleted(finalRun.currentStepIndex, finalRun.totalTokens);
          }
          return 0;
        }(),
        WorkflowRunStatus.paused || WorkflowRunStatus.awaitingApproval => () {
          final approval = lastApprovalEvent;
          if (!jsonOutput && approval != null) {
            printer.workflowApprovalPaused(
              finalRun.id,
              finalRun.currentStepIndex - 1,
              approval.stepId,
              approval.message,
            );
          } else if (!jsonOutput) {
            printer.workflowPaused(finalRun.currentStepIndex, finalRun.errorMessage);
          }
          return 2;
        }(),
        WorkflowRunStatus.failed || WorkflowRunStatus.cancelled => () {
          if (!jsonOutput) {
            printer.workflowFailed(finalRun.currentStepIndex, finalRun.errorMessage ?? 'Cancelled');
          }
          return finalRun.status == WorkflowRunStatus.cancelled ? 2 : 1;
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

  String _connectedErrorMessage(DartclawApiException error) {
    if (error.code == 'CONNECTION_REFUSED') {
      return '${error.message} Or use `dartclaw workflow run --standalone <name>` if you need in-process execution.';
    }
    return error.message;
  }

  int _exitCodeForStatus(WorkflowRunStatus status) {
    return switch (status) {
      WorkflowRunStatus.completed => 0,
      WorkflowRunStatus.failed => 1,
      WorkflowRunStatus.cancelled || WorkflowRunStatus.paused || WorkflowRunStatus.awaitingApproval => 2,
      WorkflowRunStatus.pending || WorkflowRunStatus.running => 1,
    };
  }

  Map<String, String> _parseVariables(List<String> varArgs) {
    final variables = <String, String>{};
    for (final arg in varArgs) {
      final eqIndex = arg.indexOf('=');
      if (eqIndex < 1) {
        throw UsageException('Invalid variable format: "$arg" (expected KEY=VALUE)', usage);
      }
      final key = arg.substring(0, eqIndex);
      final value = arg.substring(eqIndex + 1);
      variables[key] = value;
    }
    return variables;
  }
}

extension<T> on T {
  R let<R>(R Function(T value) fn) => fn(this);
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

Set<String> _requiredWorkflowProviders(WorkflowDefinition definition, String defaultProvider) {
  final providers = <String>{};
  for (final step in definition.steps) {
    providers.add(step.provider ?? defaultProvider);
  }
  return providers;
}
