import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig, WorkflowApprovalPolicy, WorkflowRunStatus;
import 'package:dartclaw_core/dartclaw_core.dart'
    show HarnessFactory, MapIterationCompletedEvent, TaskStatus, WorkflowLifecycleEvent, WorkflowStepCompletedEvent;
import 'package:dartclaw_storage/dartclaw_storage.dart' show SearchDbFactory, TaskDbFactory;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        ProviderAuthPreflight,
        WorkflowDefinition,
        WorkflowExclusion,
        WorkflowPreflightException,
        WorkflowRun,
        SkillIntrospector,
        WorkflowTaskType;
import 'package:path/path.dart' as p;

import '../../dartclaw_api_client.dart';
import '../cli_global_options.dart';
import '../config_loader.dart';
import '../serve_command.dart' show ExitFn, WriteLine;
import 'cli_progress_printer.dart';
import 'cli_workflow_wiring.dart';
import 'credential_preflight.dart';
import 'live_status_line.dart';
import 'standalone_lifecycle_support.dart' show requiredWorkflowProviders;
import 'standalone_run_harness.dart';
import 'workflow_event_printer_dispatch.dart';

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
  final bool _runWorkflowSkillsBootstrap;
  final SkillIntrospector? _skillIntrospector;
  final ProviderAuthPreflight? _providerAuthPreflight;

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
    bool runWorkflowSkillsBootstrap = true,
    SkillIntrospector? skillIntrospector,
    ProviderAuthPreflight? providerAuthPreflight,
  }) : _config = config,
       _searchDbFactory = searchDbFactory,
       _taskDbFactory = taskDbFactory,
       _harnessFactory = harnessFactory,
       _apiClient = apiClient,
       _environment = environment,
       _stdoutLine = stdoutLine ?? stdout.writeln,
       _stderrLine = stderrLine ?? stderr.writeln,
       _exitFn = exitFn ?? exit,
       _interrupts = interrupts ?? (() => ProcessSignal.sigint.watch().map((_) {})),
       _runWorkflowSkillsBootstrap = runWorkflowSkillsBootstrap,
       _skillIntrospector = skillIntrospector,
       _providerAuthPreflight = providerAuthPreflight {
    argParser
      ..addMultiOption('var', abbr: 'v', help: 'Variable (KEY=VALUE)', valueHelp: 'KEY=VALUE', splitCommas: false)
      ..addOption('project', abbr: 'p', help: 'Project ID for project-scoped steps')
      ..addOption(
        'approvals',
        help: 'Approval-resolution policy for this run',
        allowed: ['manual', 'auto-on-stall', 'auto'],
        allowedHelp: {
          'manual': 'Pause for needsInput and approval steps',
          'auto-on-stall': 'Auto-resolve needsInput stalls but pause at approval steps',
          'auto': 'Auto-resolve needsInput stalls and approval steps',
        },
      )
      ..addFlag(
        'allow-dirty-localpath',
        negatable: false,
        help: 'Allow workflows to run against dirty or branch-mismatched localPath projects',
      )
      ..addFlag(
        'inline',
        negatable: false,
        help:
            'Run on the current branch with no workflow-owned integration branch, worktree, or merge-back. '
            'Overrides the definition git strategy; does not relax --allow-dirty-localpath.',
      )
      ..addFlag('standalone', negatable: false, help: 'Run the workflow in-process without using the server API')
      ..addFlag('force', negatable: false, help: 'Bypass the standalone safety check')
      ..addFlag('json', negatable: false, help: 'Output structured JSON events')
      ..addFlag(
        'no-skill-bootstrap',
        negatable: false,
        help:
            'Skip DartClaw-native workflow skill provisioning in standalone mode. Use when skills are pre-staged or '
            'when running in an installed/AOT layout that cannot resolve the built-in skill source.',
      );
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
    final approvals = _parseApprovalPolicy(argResults!['approvals'] as String?);
    final allowDirtyLocalPath = argResults!['allow-dirty-localpath'] as bool;
    final inline = argResults!['inline'] as bool;
    final standalone = argResults!['standalone'] as bool;
    final force = argResults!['force'] as bool;
    final jsonOutput = argResults!['json'] as bool;
    final skipSkillBootstrap = argResults!['no-skill-bootstrap'] as bool;

    if (force && !standalone) {
      throw UsageException('--force can only be used together with --standalone', usage);
    }
    if (skipSkillBootstrap && !standalone) {
      throw UsageException('--no-skill-bootstrap can only be used together with --standalone', usage);
    }

    if (standalone) {
      final config = _config ?? _loadStandaloneConfigOrExit();
      await _runStandaloneWithSafety(
        config: config,
        workflowName: workflowName,
        variables: variables,
        projectId: projectId,
        approvals: approvals,
        allowDirtyLocalPath: allowDirtyLocalPath,
        inline: inline,
        force: force,
        jsonOutput: jsonOutput,
        runWorkflowSkillsBootstrap: _runWorkflowSkillsBootstrap && !skipSkillBootstrap,
        preferSourceTreeAssets: _resolvePreferSourceTreeAssets(),
      );
      return;
    }

    final config = _config ?? loadCliConfig(configPath: globalOptionString(globalResults, 'config'));
    final apiClient =
        _apiClient ??
        DartclawApiClient.fromConfig(
          config: config,
          serverOverride: serverOverride(globalResults),
          tokenOverride: globalOptionString(globalResults, 'token'),
        );
    try {
      await _runConnected(
        apiClient: apiClient,
        workflowName: workflowName,
        variables: variables,
        projectId: projectId,
        approvals: approvals,
        allowDirtyLocalPath: allowDirtyLocalPath,
        inline: inline,
        jsonOutput: jsonOutput,
      );
    } on DartclawApiException catch (error) {
      _stderrLine(_connectedErrorMessage(error));
      _exitFn(1);
    }
  }

  DartclawConfig _loadStandaloneConfigOrExit() {
    final configPath = resolveStandaloneWorkflowConfigPath(
      configPath: globalOptionString(globalResults, 'config'),
      env: _environment,
    );
    if (!File(configPath).existsSync()) {
      _stderrLine('No config found at $configPath. Run: dartclaw init --workflow');
      _exitFn(1);
    }
    return loadCliConfig(configPath: configPath, env: _environment);
  }

  Future<void> _runStandaloneWithSafety({
    required DartclawConfig config,
    required String workflowName,
    required Map<String, String> variables,
    required String? projectId,
    required WorkflowApprovalPolicy? approvals,
    required bool allowDirtyLocalPath,
    required bool inline,
    required bool force,
    required bool jsonOutput,
    required bool runWorkflowSkillsBootstrap,
    required bool preferSourceTreeAssets,
  }) async {
    final apiClient =
        _apiClient ??
        DartclawApiClient.fromConfig(
          config: config,
          serverOverride: serverOverride(globalResults),
          tokenOverride: globalOptionString(globalResults, 'token'),
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

    final wiring = CliWorkflowWiring(
      config: config,
      dataDir: dataDir,
      environment: _environment,
      harnessFactory: _harnessFactory,
      searchDbFactory: _searchDbFactory,
      taskDbFactory: _taskDbFactory,
      runWorkflowSkillsBootstrap: runWorkflowSkillsBootstrap,
      preferSourceTreeAssets: preferSourceTreeAssets,
      skillIntrospector: _skillIntrospector,
      providerAuthPreflight: _providerAuthPreflight,
    );
    var preWired = false;
    try {
      await wiring.wirePreHarness();
      preWired = true;
    } on CredentialPreflightException catch (error) {
      for (final item in error.errors) {
        _stderrLine(item.message);
      }
      _exitFn(1);
    }

    try {
      final definition = wiring.registry.getByName(workflowName);
      if (definition == null) {
        final allExclusions = wiring.registry.exclusions;
        // Match parse-failure entries (workflowName == null) by filename
        // basename so "dartclaw run foo" surfaces a foo.yaml parse failure.
        bool matchesRequested(WorkflowExclusion excl) {
          if (excl.workflowName != null) return excl.workflowName == workflowName;
          return p.basenameWithoutExtension(excl.sourcePath) == workflowName;
        }

        final namedExclusions = allExclusions.where(matchesRequested).toList();
        final otherExclusions = allExclusions.where((excl) => !matchesRequested(excl)).toList();
        if (namedExclusions.isNotEmpty) {
          _stderrLine('Workflow "$workflowName" was excluded at load time:');
          for (final excl in namedExclusions) {
            _stderrLine('  ${excl.sourcePath}:');
            for (final err in excl.errors) {
              _stderrLine('    - $err');
            }
          }
        } else {
          _stderrLine('Unknown workflow: $workflowName');
        }
        final available = wiring.registry.listAll().map((item) => item.name).join(', ');
        if (available.isNotEmpty) {
          _stderrLine('Available: $available');
        }
        if (otherExclusions.isNotEmpty) {
          // Surface sibling failures so partial-registry damage is visible
          // even when the operator's requested workflow exists or doesn't.
          _stderrLine(
            available.isEmpty
                ? 'No workflows are registered. Excluded at load time:'
                : 'Other workflows excluded at load time:',
          );
          for (final excl in otherExclusions) {
            final label = excl.workflowName ?? excl.sourcePath;
            _stderrLine('  $label: ${excl.errors.join('; ')}');
          }
        }
        // Suppress the --no-skill-bootstrap skill hint when an explicit
        // exclusion reason was already surfaced — the hint tells the operator
        // to fix skill provisioning, which is misleading if the actual cause
        // was (e.g.) a structural validation error.
        if (!runWorkflowSkillsBootstrap && allExclusions.isEmpty) {
          // Workflows that reference unresolved skills are silently excluded
          // by WorkflowRegistry; with --no-skill-bootstrap that almost always
          // means workflow skills weren't pre-staged. Surface the hint.
          _stderrLine(
            'Note: --no-skill-bootstrap was set. If "$workflowName" uses DartClaw-native workflow skills, '
            'pre-stage them under the data-dir native skill roots and materialize the project workspace links, '
            'or omit --no-skill-bootstrap to provision those native skills automatically. '
            'Externally provided skills (e.g. andthen:*) must be installed separately for the selected provider.',
          );
        }
        _exitFn(1);
      }
      // Gate referenced-provider auth before any harness starts: derive the
      // run's referenced providers, preflight them, and only then start
      // harnesses for that exact set. A logged-out referenced provider aborts
      // here with the friendly remediation, before `harness.start()`; an
      // unreferenced provider (e.g. a logged-out default) is never started or
      // probed.
      final referencedProviders = requiredWorkflowProviders(definition, config);
      try {
        await wiring.preflightProviderAuth(referencedProviders);
      } on WorkflowPreflightException catch (error) {
        _stderrLine(error.message);
        _exitFn(1);
      }
      await wiring.startHarnesses(referencedProviders);

      final printer = CliProgressPrinter(
        totalSteps: definition.steps.length,
        workflowName: definition.name,
        writeLine: _stdoutLine,
        standalone: true,
        liveStatusLine: LiveStatusLine.forStdout(jsonOutput: jsonOutput),
      );

      final finalRun = await driveStandaloneWorkflowRun(
        service: wiring.workflowService,
        taskService: wiring.taskService,
        definition: definition,
        eventBus: wiring.eventBus,
        printer: printer,
        jsonOutput: jsonOutput,
        stdoutLine: _stdoutLine,
        interrupts: _interrupts,
        exitFn: _exitFn,
        trigger: () => wiring.workflowService.start(
          definition,
          variables,
          projectId: projectId,
          allowDirtyLocalPath: allowDirtyLocalPath,
          inline: inline,
          approvals: approvals,
        ),
      );
      _exitFn(standaloneWorkflowExitCode(finalRun.status));
    } finally {
      if (preWired) {
        await wiring.dispose();
      }
    }
  }

  Future<void> _runConnected({
    required DartclawApiClient apiClient,
    required String workflowName,
    required Map<String, String> variables,
    required String? projectId,
    required WorkflowApprovalPolicy? approvals,
    required bool allowDirtyLocalPath,
    required bool inline,
    required bool jsonOutput,
  }) async {
    final started = await apiClient.postObject(
      '/api/workflows/run',
      body: {
        'definition': workflowName,
        'variables': variables,
        if (projectId != null && projectId.isNotEmpty) 'project': projectId,
        if (approvals != null) 'approvals': approvals.yamlValue,
        if (allowDirtyLocalPath) 'allowDirtyLocalPath': true,
        if (inline) 'inline': true,
      },
    );
    final run = WorkflowRun.fromJson(started);
    final definition = WorkflowDefinition.fromJson(Map<String, dynamic>.from(started['definitionJson'] as Map));
    final printer = CliProgressPrinter(
      totalSteps: definition.steps.length,
      workflowName: definition.name,
      writeLine: _stdoutLine,
      liveStatusLine: LiveStatusLine.forStdout(jsonOutput: jsonOutput),
    );

    if (jsonOutput) {
      _stdoutLine(jsonEncode({'type': 'run_started', 'run': started}));
    } else {
      printer.workflowStarted();
    }

    final completer = Completer<int>();
    final startedSteps = <String, DateTime>{};
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
              completer.complete(standaloneWorkflowExitCode(lastStatus));
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
            final newStatus = event['newStatus']?.toString();
            final settledStatus = newStatus == null ? null : TaskStatus.values.asNameMap()[newStatus];
            if (settledStatus != null && taskSettlesLiveEntry(settledStatus)) {
              // A parallel-group member settles long before the barrier emits
              // workflow_step_completed – retire its live entry now so the
              // live line counts actually-running tasks.
              if (!jsonOutput) {
                final key = taskProgressKey(event['taskId']?.toString());
                if (key != null) printer.stepSettled(key, countTokens: settledStatus == TaskStatus.accepted);
              }
              break;
            }
            final stepIndex = event['stepIndex'] as int?;
            if (stepIndex == null || stepIndex >= definition.steps.length) {
              break;
            }
            final step = definition.steps[stepIndex];
            final displayScope = _eventDisplayScope(event);
            final taskId = event['taskId']?.toString();
            if (newStatus == TaskStatus.running.name) {
              final runningKey = progressStartKey(stepIndex: stepIndex, taskId: taskId, displayScope: displayScope);
              startedSteps[runningKey] = DateTime.now();
              if (!jsonOutput) {
                printer.stepRunning(
                  stepIndex,
                  step.id,
                  step.name,
                  step.provider,
                  displayScope: displayScope,
                  progressKey: runningKey,
                );
              }
            } else if (newStatus == TaskStatus.review.name && !jsonOutput) {
              printer.stepReview(stepIndex, step.id, displayScope: displayScope);
            }
            break;
          case 'workflow_step_completed':
            final WorkflowStepCompletedEvent completed;
            try {
              completed = WorkflowLifecycleEvent.fromJson(event) as WorkflowStepCompletedEvent;
            } on FormatException {
              // Skip malformed/version-skewed frames instead of aborting the
              // stream; the post-loop status refetch still resolves the run.
              break;
            }
            final stepIndex = completed.stepIndex;
            final displayScope = _eventDisplayScope(event);
            final taskId = completed.taskId;
            final key = progressStartKey(stepIndex: stepIndex, taskId: taskId, displayScope: displayScope);
            final duration = startedSteps.remove(key)?.let(DateTime.now().difference);
            if (!jsonOutput) {
              dispatchWorkflowStepCompletedToPrinter(
                printer: printer,
                event: completed,
                duration: duration,
                progressKey: key,
              );
            }
            break;
          case 'map_iteration_completed':
            final MapIterationCompletedEvent completed;
            try {
              completed = WorkflowLifecycleEvent.fromJson(event) as MapIterationCompletedEvent;
            } on FormatException {
              break;
            }
            final stepId = completed.stepId;
            final stepIndex = definition.steps.indexWhere((step) => step.id == stepId);
            final taskId = completed.taskId;
            if (stepIndex < 0) break;
            if (definition.steps[stepIndex].taskType == WorkflowTaskType.foreach && taskId.trim().isNotEmpty) {
              break;
            }
            final displayScope = _eventDisplayScope(event);
            final key = progressStartKey(stepIndex: stepIndex, taskId: taskId, displayScope: displayScope);
            final duration = startedSteps.remove(key)?.let(DateTime.now().difference);
            if (!jsonOutput) {
              dispatchMapIterationCompletedToPrinter(
                printer: printer,
                event: completed,
                stepIndex: stepIndex,
                duration: duration,
                progressKey: key,
                displayScope: displayScope,
              );
            }
            break;
          case 'workflow_cli_turn_progress':
            if (!jsonOutput) {
              final key = taskProgressKey(event['taskId']?.toString());
              final cumulative = event['cumulativeTokens'] as int?;
              if (key != null && cumulative != null) {
                printer.stepTokens(key, cumulative);
              }
            }
            break;
          case 'workflow_status_changed':
            final newStatusName = event['newStatus']?.toString();
            final newStatus = newStatusName == null ? null : WorkflowRunStatus.values.asNameMap()[newStatusName];
            if (newStatus == null) {
              break;
            }
            lastStatus = newStatus;
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
              completer.complete(standaloneWorkflowExitCode(lastStatus));
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
          completer.complete(standaloneWorkflowExitCode(lastStatus));
        }
      } else {
        throw DartclawApiException('${error.message} Use `dartclaw workflow status ${run.id}` to inspect the run.');
      }
    } finally {
      printer.disposeLive();
      await interruptSub.cancel();
    }

    final exitCode = completer.isCompleted ? await completer.future : standaloneWorkflowExitCode(lastStatus);
    if (!jsonOutput && lastStatus == WorkflowRunStatus.cancelled && lastError == null && cancelRequested) {
      _stdoutLine('[workflow] Cancelled: ${run.id}');
    }
    _exitFn(exitCode);
  }

  String _connectedErrorMessage(DartclawApiException error) {
    if (error.code == 'CONNECTION_REFUSED') {
      return '${error.message} Or use `dartclaw workflow run --standalone <name>` if you need in-process execution.';
    }
    return error.message;
  }

  /// Reads the `DARTCLAW_WORKFLOWS_PREFER_SOURCE` env var.
  ///
  /// The maintainer profile (`dev/tools/dartclaw-workflows/run.sh`) sets this
  /// to `1` so live source-tree edits to skills and workflow YAMLs win over
  /// embedded built-ins. Currently
  /// consulted only on the `--standalone` path; a connected `dartclaw run`
  /// dispatches to whatever the running server's wiring decided at startup,
  /// so this env var has no effect there. The maintainer `run.sh` only
  /// invokes standalone, which is the only path that needs the override.
  bool _resolvePreferSourceTreeAssets() {
    final env = _environment ?? Platform.environment;
    final value = env['DARTCLAW_WORKFLOWS_PREFER_SOURCE']?.trim().toLowerCase();
    return value == '1' || value == 'true' || value == 'yes';
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

  WorkflowApprovalPolicy? _parseApprovalPolicy(String? raw) {
    if (raw == null) return null;
    return WorkflowApprovalPolicy.fromYaml(raw);
  }
}

String? _eventDisplayScope(Map<String, dynamic> event) {
  final scope = event['displayScope'] ?? event['itemId'];
  if (scope is! String) return null;
  final trimmed = scope.trim();
  return trimmed.isEmpty ? null : trimmed;
}

extension<T> on T {
  R let<R>(R Function(T value) fn) => fn(this);
}
