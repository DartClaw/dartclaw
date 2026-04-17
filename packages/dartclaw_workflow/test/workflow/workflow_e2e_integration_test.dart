@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/workflow/cli_workflow_wiring.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;
import 'package:dartclaw_core/dartclaw_core.dart' show MessageService, Task, WorkflowStepCompletedEvent;
import 'package:dartclaw_models/dartclaw_models.dart' show WorkflowDefinition;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        EventBus,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowRunStatus,
        WorkflowRunStatusChangedEvent,
        WorkflowService,
        WorkflowStepOutputTransformer;
import 'package:dartclaw_server/dartclaw_server.dart' show LogService, TaskService;
import 'package:dartclaw_workflow/src/workflow/context_extractor.dart';
import 'package:dartclaw_workflow/src/workflow/workflow_context.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Path resolution helpers
// ---------------------------------------------------------------------------

String _fixturesRoot() {
  var current = Directory.current;
  while (true) {
    final candidates = [
      p.join(current.path, 'test', 'fixtures'),
      p.join(current.path, 'packages', 'dartclaw_workflow', 'test', 'fixtures'),
    ];
    for (final candidate in candidates) {
      if (Directory(candidate).existsSync()) {
        return Directory(candidate).resolveSymbolicLinksSync();
      }
    }
    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('Could not locate workflow test fixtures');
    }
    current = parent;
  }
}

String _e2eFixtureProfileDir(String fixturesRoot) => p.join(fixturesRoot, 'workflow-e2e-profile');

// ---------------------------------------------------------------------------
// Config loading — replicates run.sh path templating
// ---------------------------------------------------------------------------

DartclawConfig _loadWorkflowsConfig({required String fixtureProfileDir, required String dataDir}) {
  final dataDirAbs = Directory(dataDir).resolveSymbolicLinksSync();
  final workspaceDir = p.join(dataDirAbs, 'workflow-workspace');
  final templatePath = p.join(fixtureProfileDir, 'workflow_profile.yaml');

  final templateYaml = File(templatePath).readAsStringSync();
  final resolvedYaml = templateYaml
      .replaceAll('__DATA_DIR__', dataDirAbs)
      .replaceAll('__WORKFLOW_WORKSPACE_DIR__', workspaceDir);

  final runtimePath = p.join(dataDirAbs, '.e2e-test.runtime.yaml');
  File(runtimePath).writeAsStringSync(resolvedYaml);

  return DartclawConfig.load(configPath: runtimePath);
}

// ---------------------------------------------------------------------------
// Codex availability check
// ---------------------------------------------------------------------------

Future<bool> _codexAvailable() async {
  try {
    final result = await Process.run('codex', ['--version']);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

WorkflowStepOutputTransformer _forceSinglePlanReviewRemediationLoop({
  required String remediationPlan,
  required String implementationSummary,
}) {
  var forced = false;
  final log = Logger('E2E.ForcedRemediation');
  return (run, definition, step, task, outputs) {
    if (forced || definition.name != 'plan-and-implement' || step.id != 'plan-review') {
      return outputs;
    }

    final findingsValue = outputs['findings_count'];
    final findingsCount = switch (findingsValue) {
      final int numeric => numeric,
      _ => int.tryParse('$findingsValue') ?? 0,
    };
    if (findingsCount > 0) {
      return outputs;
    }

    forced = true;
    log.info(
      'Forcing a single remediation-loop iteration for workflow ${run.id} '
      'by overriding clean plan-review outputs',
    );
    return {
      ...outputs,
      'implementation_summary': (outputs['implementation_summary'] as String?)?.trim().isNotEmpty == true
          ? outputs['implementation_summary']
          : implementationSummary,
      'remediation_plan': remediationPlan,
      'findings_count': 1,
      'plan-review.findings_count': 1,
    };
  };
}

// ---------------------------------------------------------------------------
// TI02: Step capture infrastructure
// ---------------------------------------------------------------------------

class WorkflowStepTrace {
  final String runId;
  final String stepKey;
  final int occurrence;
  final String taskId;
  final String title;
  final String description;
  final TaskStatus terminalStatus;
  final int tokenCount;
  final Map<String, dynamic> configJson;
  final Map<String, dynamic>? worktreeJson;
  final String? sessionId;
  final Map<String, dynamic> contextInputs;
  final Map<String, dynamic> contextOutputs;
  final String? lastUserMessage;
  final String? lastAssistantMessage;
  final DateTime queuedAt;
  final DateTime? completedAt;

  WorkflowStepTrace({
    required this.runId,
    required this.stepKey,
    required this.occurrence,
    required this.taskId,
    required this.title,
    required this.description,
    required this.terminalStatus,
    required this.tokenCount,
    required this.configJson,
    this.worktreeJson,
    this.sessionId,
    this.contextInputs = const {},
    this.contextOutputs = const {},
    this.lastUserMessage,
    this.lastAssistantMessage,
    required this.queuedAt,
    this.completedAt,
  });
}

class WorkflowExecutionRecorder {
  final EventBus _eventBus;
  final TaskService _taskService;
  final MessageService _messageService;
  final WorkflowService _workflowService;
  final ContextExtractor _contextExtractor;
  final WorkflowDefinition _definition;
  final Directory _artifactDir;
  final Logger _log;
  final List<WorkflowStepTrace> traces = [];
  final List<String> stepOrder = [];
  final Map<String, List<String>> descriptionsByStep = {};
  final Map<String, int> _occurrenceByStep = {};

  late final StreamSubscription<TaskStatusChangedEvent> _queuedSub;
  late final StreamSubscription<WorkflowStepCompletedEvent> _completedSub;

  final _pending = <String, WorkflowStepTrace>{};

  WorkflowExecutionRecorder(
    this._eventBus,
    this._taskService,
    this._messageService,
    this._workflowService,
    this._definition, {
    required Directory artifactDir,
    required String dataDir,
  }) : _artifactDir = artifactDir,
       _contextExtractor = ContextExtractor(
         taskService: _taskService,
         messageService: _messageService,
         dataDir: dataDir,
       ),
       _log = Logger('E2E.StepArtifacts');

  void start() {
    _queuedSub = _eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      final task = await _taskService.get(e.taskId);
      if (task == null || task.stepIndex == null || task.workflowRunId == null) return;

      final step = _definition.steps[task.stepIndex!];
      final stepKey = step.id;
      final occurrence = (_occurrenceByStep[stepKey] ?? 0) + 1;
      _occurrenceByStep[stepKey] = occurrence;
      final run = await _workflowService.get(task.workflowRunId!);
      final contextData = _contextData(run?.contextJson);
      final contextInputs = <String, dynamic>{for (final key in step.contextInputs) key: contextData[key]};

      stepOrder.add(stepKey);
      descriptionsByStep.putIfAbsent(stepKey, () => []).add(task.description);
      _pending[task.id] = WorkflowStepTrace(
        runId: task.workflowRunId!,
        stepKey: stepKey,
        occurrence: occurrence,
        taskId: task.id,
        title: task.title,
        description: task.description,
        terminalStatus: TaskStatus.queued,
        tokenCount: 0,
        configJson: Map<String, dynamic>.from(task.configJson),
        worktreeJson: task.worktreeJson,
        contextInputs: contextInputs,
        queuedAt: DateTime.now(),
      );
    });

    _completedSub = _eventBus.on<WorkflowStepCompletedEvent>().listen((event) async {
      await Future<void>.delayed(Duration.zero);
      final pending = _pending.remove(event.taskId);
      if (pending == null) return;

      final task = await _taskService.get(event.taskId);
      if (task == null) return;
      final sessionId = task.sessionId;
      String? lastUserMessage;
      String? lastAssistantMessage;
      List<Map<String, dynamic>> persistedMessages = const [];
      if (sessionId != null && sessionId.isNotEmpty) {
        final messages = await _messageService.getMessages(sessionId);
        persistedMessages = messages
            .map(
              (message) => <String, dynamic>{
                'cursor': message.cursor,
                'id': message.id,
                'role': message.role,
                'content': message.content,
                'metadata': message.metadata,
                'createdAt': message.createdAt.toIso8601String(),
              },
            )
            .toList(growable: false);
        for (final message in messages.reversed) {
          if (lastAssistantMessage == null && message.role == 'assistant') {
            lastAssistantMessage = message.content;
          }
          if (lastUserMessage == null && message.role == 'user') {
            lastUserMessage = message.content;
          }
          if (lastUserMessage != null && lastAssistantMessage != null) {
            break;
          }
        }
      }

      Map<String, dynamic> contextOutputs = const {};
      try {
        contextOutputs = await _contextExtractor.extract(_definition.steps[event.stepIndex], task);
      } catch (error, st) {
        _log.warning('Failed to extract context outputs for ${event.stepId}', error, st);
      }
      final stepScopedContext = _buildStepScopedContext(
        runContext: _contextData((await _workflowService.get(event.runId))?.contextJson),
        stepId: event.stepId,
      );

      await _writeArtifact(
        pending: pending,
        task: task,
        stepName: event.stepName,
        terminalStatus: task.status,
        tokenCount: event.tokenCount,
        sessionId: sessionId,
        contextOutputs: contextOutputs,
        stepScopedContext: stepScopedContext,
        lastUserMessage: lastUserMessage,
        lastAssistantMessage: lastAssistantMessage,
        persistedMessages: persistedMessages,
      );

      traces.add(
        WorkflowStepTrace(
          runId: pending.runId,
          stepKey: pending.stepKey,
          occurrence: pending.occurrence,
          taskId: pending.taskId,
          title: pending.title,
          description: pending.description,
          terminalStatus: task.status,
          tokenCount: event.tokenCount,
          configJson: pending.configJson,
          worktreeJson: task.worktreeJson ?? pending.worktreeJson,
          sessionId: sessionId,
          contextInputs: pending.contextInputs,
          contextOutputs: contextOutputs,
          lastUserMessage: lastUserMessage,
          lastAssistantMessage: lastAssistantMessage,
          queuedAt: pending.queuedAt,
          completedAt: DateTime.now(),
        ),
      );
    });
  }

  Future<void> dispose() async {
    await _queuedSub.cancel();
    await _completedSub.cancel();
  }

  int count(String stepKey) => stepOrder.where((s) => s == stepKey).length;

  List<WorkflowStepTrace> tracesForStep(String stepKey) => traces.where((t) => t.stepKey == stepKey).toList();

  Future<void> _writeArtifact({
    required WorkflowStepTrace pending,
    required Task task,
    required String stepName,
    required TaskStatus terminalStatus,
    required int tokenCount,
    required String? sessionId,
    required Map<String, dynamic> contextOutputs,
    required Map<String, dynamic> stepScopedContext,
    required String? lastUserMessage,
    required String? lastAssistantMessage,
    required List<Map<String, dynamic>> persistedMessages,
  }) async {
    _artifactDir.createSync(recursive: true);
    final fileName =
        '${(traces.length + 1).toString().padLeft(2, '0')}-'
        '${_sanitizeFileComponent(pending.stepKey)}-'
        'occ${pending.occurrence.toString().padLeft(2, '0')}-'
        '${pending.taskId}.json';
    final file = File(p.join(_artifactDir.path, fileName));
    final payload = <String, dynamic>{
      'runId': pending.runId,
      'stepKey': pending.stepKey,
      'stepName': stepName,
      'occurrence': pending.occurrence,
      'taskId': pending.taskId,
      'title': pending.title,
      'description': pending.description,
      'terminalStatus': terminalStatus.name,
      'tokenCount': tokenCount,
      'queuedAt': pending.queuedAt.toIso8601String(),
      'completedAt': DateTime.now().toIso8601String(),
      'sessionId': sessionId,
      'provider': task.provider,
      'providerSessionId': task.configJson['_workflowProviderSessionId'],
      'workflowRunId': task.workflowRunId,
      'stepIndex': task.stepIndex,
      'configJson': pending.configJson,
      'worktreeJson': task.worktreeJson ?? pending.worktreeJson,
      'contextInputs': pending.contextInputs,
      'contextOutputs': contextOutputs,
      'stepScopedContext': stepScopedContext,
      'lastUserMessage': lastUserMessage,
      'lastAssistantMessage': lastAssistantMessage,
      'messages': persistedMessages,
    };
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(payload));
    _log.info('Wrote step artifact: ${file.path}');
  }
}

String _sanitizeFileComponent(String value) => value.replaceAll(RegExp(r'[^a-zA-Z0-9._-]+'), '_');

Map<String, dynamic> _contextData(Map<String, dynamic>? contextJson) {
  if (contextJson == null) return const {};
  final context = WorkflowContext.fromJson(contextJson);
  return Map<String, dynamic>.from(context.data);
}

Map<String, dynamic> _buildStepScopedContext({required Map<String, dynamic> runContext, required String stepId}) {
  final result = <String, dynamic>{};
  for (final entry in runContext.entries) {
    if (entry.key == stepId || entry.key.startsWith('$stepId.') || entry.key.startsWith('$stepId[')) {
      result[entry.key] = entry.value;
    }
  }
  return result;
}

Directory _createPreservedArtifactDir(String testName) {
  final configuredRoot = Platform.environment['DARTCLAW_E2E_LOG_DIR']?.trim();
  final root = configuredRoot != null && configuredRoot.isNotEmpty
      ? Directory(configuredRoot)
      : Directory(p.join(Directory.current.path, '.dart_tool', 'dartclaw_e2e_logs'));
  root.createSync(recursive: true);

  final runDir = Directory(
    p.join(root.path, '${DateTime.now().millisecondsSinceEpoch}-${_sanitizeFileComponent(testName)}'),
  );
  runDir.createSync(recursive: true);
  return runDir;
}

// ---------------------------------------------------------------------------
// TI06: Assertion helpers
// ---------------------------------------------------------------------------

void expectStepOrder(WorkflowExecutionRecorder recorder, List<String> expectedSteps) {
  final actual = recorder.stepOrder;
  var expectedIdx = 0;
  for (var i = 0; i < actual.length && expectedIdx < expectedSteps.length; i++) {
    if (actual[i] == expectedSteps[expectedIdx]) {
      expectedIdx++;
    }
  }
  if (expectedIdx < expectedSteps.length) {
    fail(
      'Step ordering mismatch: expected steps ${expectedSteps.sublist(expectedIdx)} '
      'were not found in order.\nActual step order: $actual',
    );
  }
}

void expectStepInputContains(WorkflowExecutionRecorder recorder, String stepKey, String expectedSubstring) {
  final descriptions = recorder.descriptionsByStep[stepKey];
  if (descriptions == null || descriptions.isEmpty) {
    fail(
      'No descriptions recorded for step "$stepKey".\nAvailable steps: ${recorder.descriptionsByStep.keys.toList()}',
    );
  }
  final anyMatch = descriptions.any((d) => d.contains(expectedSubstring));
  if (!anyMatch) {
    final previews = descriptions.map((d) => d.length > 300 ? '${d.substring(0, 300)}...' : d).toList();
    fail('Step "$stepKey" description does not contain "$expectedSubstring".\nPreviews: $previews');
  }
}

void expectWorktreeRecorded(WorkflowExecutionRecorder recorder, String stepKey) {
  final stepTraces = recorder.tracesForStep(stepKey);
  if (stepTraces.isEmpty) {
    fail('No traces recorded for step "$stepKey"');
  }
  for (final trace in stepTraces) {
    expect(trace.worktreeJson, isNotNull, reason: 'Step "$stepKey" (task ${trace.taskId}) should have worktreeJson');
    expect(trace.worktreeJson!['path'], isNotNull, reason: 'Step "$stepKey" worktreeJson should contain a "path" key');
  }
}

void expectPublishSuccess(Map<String, dynamic> contextJson) {
  final contextData = (contextJson['data'] as Map?)?.cast<String, dynamic>() ?? contextJson;
  expect(
    contextData['publish.status'],
    'success',
    reason: 'Workflow publish should have status "success", got "${contextData['publish.status']}"',
  );
}

// ---------------------------------------------------------------------------
// TI05: PR cleanup helpers
// ---------------------------------------------------------------------------

Future<void> _closePr(String prUrl) async {
  if (prUrl.isEmpty) return;
  await Process.run('gh', ['pr', 'close', prUrl, '--delete-branch']);
}

Future<void> _closePrByBranch(String branch, String repo) async {
  if (branch.isEmpty) return;
  await Process.run('gh', ['pr', 'close', branch, '--repo', repo, '--delete-branch']);
}

void _copyDirectorySync(Directory source, Directory target) {
  target.createSync(recursive: true);
  for (final entity in source.listSync(recursive: true, followLinks: false)) {
    final relativePath = p.relative(entity.path, from: source.path);
    if (entity is File) {
      final destination = File(p.join(target.path, relativePath));
      destination.parent.createSync(recursive: true);
      entity.copySync(destination.path);
    } else if (entity is Directory) {
      Directory(p.join(target.path, relativePath)).createSync(recursive: true);
    }
  }
}

Future<void> _cloneWorkflowTestingRepo(String targetDir) async {
  Directory(targetDir).parent.createSync(recursive: true);
  final result = await Process.run('git', [
    'clone',
    '--depth',
    '1',
    'https://github.com/tolo/dartclaw-workflow-testing.git',
    targetDir,
  ]);
  if (result.exitCode != 0) {
    throw StateError('Failed to clone workflow-testing fixture repo: ${result.stderr}');
  }
  Process.runSync('git', ['config', 'user.name', 'Workflow E2E Test'], workingDirectory: targetDir);
  Process.runSync('git', ['config', 'user.email', 'workflow-e2e@example.com'], workingDirectory: targetDir);
}

void _overlayInstructionFiles({required String sourceDir, required String targetDir}) {
  for (final name in ['AGENTS.md', 'CLAUDE.md']) {
    File(p.join(sourceDir, name)).copySync(p.join(targetDir, name));
  }
}

// ---------------------------------------------------------------------------
// Main test group
// ---------------------------------------------------------------------------

void main() {
  late String fixturesRoot;
  late String e2eFixtureProfileDir;
  late Directory runtimeDir;
  late String fixtureDir;
  late DartclawConfig config;
  final createdPrUrls = <String>[];
  final createdBranches = <String>[];

  CliWorkflowWiring? wiring;
  LogService? logService;

  // EventBus diagnostic subscriptions — cancelled in tearDownAll.
  final diagnosticSubs = <StreamSubscription<Object>>[];

  setUpAll(() async {
    // ── Logging ──────────────────────────────────────────────────────────
    // Install LogService at FINE level so every _log.info / _log.fine call
    // across WorkflowExecutor, TaskExecutor, TurnRunner, etc. is visible.
    logService = LogService.fromConfig(level: 'FINE');
    logService!.install();

    final hasCodex = await _codexAvailable();
    if (!hasCodex) {
      markTestSkipped(
        'Codex is not available — skipping e2e integration tests. '
        'Install Codex and authenticate, or set CODEX_API_KEY.',
      );
      return;
    }

    fixturesRoot = _fixturesRoot();
    e2eFixtureProfileDir = _e2eFixtureProfileDir(fixturesRoot);
  });

  tearDownAll(() async {
    for (final sub in diagnosticSubs) {
      await sub.cancel();
    }
    diagnosticSubs.clear();
    await logService?.dispose();
  });

  setUp(() async {
    createdPrUrls.clear();
    createdBranches.clear();
    runtimeDir = Directory.systemTemp.createTempSync('dartclaw_workflow_e2e_');
    final dataDir = p.join(runtimeDir.path, 'data');
    _copyDirectorySync(Directory(p.join(e2eFixtureProfileDir, 'workspace')), Directory(p.join(dataDir, 'workspace')));
    _copyDirectorySync(
      Directory(p.join(e2eFixtureProfileDir, 'workflow-workspace')),
      Directory(p.join(dataDir, 'workflow-workspace')),
    );
    fixtureDir = p.join(dataDir, 'projects', 'workflow-testing');
    await _cloneWorkflowTestingRepo(fixtureDir);
    _overlayInstructionFiles(sourceDir: e2eFixtureProfileDir, targetDir: fixtureDir);
    config = _loadWorkflowsConfig(fixtureProfileDir: e2eFixtureProfileDir, dataDir: dataDir);
  });

  tearDown(() async {
    // Dispose wiring first (stops harness pool, cancels tasks)
    if (wiring != null) {
      await wiring!.dispose();
      wiring = null;
    }

    // Close any PRs created during the test
    for (final url in createdPrUrls) {
      await _closePr(url);
    }
    for (final branch in createdBranches) {
      await _closePrByBranch(branch, 'tolo/dartclaw-workflow-testing');
    }

    if (runtimeDir.existsSync()) {
      runtimeDir.deleteSync(recursive: true);
    }
  });

  // -------------------------------------------------------------------------
  // Shared helper: wire up CliWorkflowWiring with in-memory SQLite
  // -------------------------------------------------------------------------
  Future<CliWorkflowWiring> wireUp({WorkflowStepOutputTransformer? outputTransformer}) async {
    final w = CliWorkflowWiring(
      config: config,
      dataDir: config.server.dataDir,
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      workflowStepOutputTransformer: outputTransformer,
    );
    await w.wire();
    wiring = w;

    // ── EventBus diagnostics ──────────────────────────────────────────
    // Log workflow step completions and task status transitions so the
    // test runner output shows real-time progress beyond Logger output.
    final diagLog = Logger('E2E.Diagnostics');
    diagnosticSubs.add(
      w.eventBus.on<WorkflowStepCompletedEvent>().listen((e) {
        diagLog.info(
          'Step completed: ${e.stepId} [${e.stepIndex + 1}/${e.totalSteps}] '
          '${e.success ? "OK" : "FAILED"} (${e.tokenCount} tokens, task=${e.taskId})',
        );
      }),
    );
    diagnosticSubs.add(
      w.eventBus.on<TaskStatusChangedEvent>().listen((e) {
        diagLog.info('Task ${e.taskId}: ${e.oldStatus} → ${e.newStatus}');
      }),
    );
    diagnosticSubs.add(
      w.eventBus.on<WorkflowRunStatusChangedEvent>().listen((e) {
        diagLog.info('Workflow ${e.runId}: ${e.oldStatus} → ${e.newStatus}');
      }),
    );

    return w;
  }

  // -------------------------------------------------------------------------
  // Shared helper: await workflow completion via EventBus
  // -------------------------------------------------------------------------
  Future<WorkflowRunStatus> awaitWorkflowCompletion(EventBus eventBus, String runId) {
    final completer = Completer<WorkflowRunStatus>();
    late final StreamSubscription<WorkflowRunStatusChangedEvent> sub;
    sub = eventBus.on<WorkflowRunStatusChangedEvent>().listen((event) {
      if (event.runId != runId) return;
      // Resolve on terminal states AND on paused (e.g. remediation loop exhausted
      // max iterations, or publish failure). Without this, the future would hang
      // until the test timeout when the workflow pauses.
      if (event.newStatus.terminal || event.newStatus == WorkflowRunStatus.paused) {
        if (!completer.isCompleted) {
          completer.complete(event.newStatus);
        }
        unawaited(sub.cancel());
      }
    });
    // Ensure subscription is cancelled even on timeout or test failure
    completer.future.whenComplete(() => unawaited(sub.cancel()));
    return completer.future;
  }

  // -------------------------------------------------------------------------
  // Shared helper: create PR after push and track for cleanup
  // -------------------------------------------------------------------------
  Future<String> createPr({required String branch, required String title}) async {
    createdBranches.add(branch);
    final result = await Process.run('gh', [
      'pr',
      'create',
      '--repo',
      'tolo/dartclaw-workflow-testing',
      '--head',
      branch,
      '--base',
      'main',
      '--title',
      title,
      '--body',
      'Automated e2e integration test PR — will be auto-closed.',
      '--draft',
    ], workingDirectory: fixtureDir);
    if (result.exitCode != 0) {
      fail('Failed to create PR for branch "$branch": ${result.stderr}');
    }
    final prUrl = (result.stdout as String).trim();
    createdPrUrls.add(prUrl);
    return prUrl;
  }

  // -------------------------------------------------------------------------
  // TI03: spec-and-implement e2e
  // -------------------------------------------------------------------------
  test('spec-and-implement e2e with real Codex harness and git operations', () async {
    final w = await wireUp();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final artifactDir = _createPreservedArtifactDir('spec-and-implement-e2e');
    Logger('E2E.StepArtifacts').info('Preserving step artifacts in ${artifactDir.path}');

    // Set CWD to fixture repo for git operations
    final savedCwd = Directory.current;
    Directory.current = Directory(fixtureDir);

    try {
      // Look up the built-in definition
      final definition = w.registry.getByName('spec-and-implement')!;

      // Start step recorder
      final recorder = WorkflowExecutionRecorder(
        w.eventBus,
        w.taskService,
        w.messageService,
        w.workflowService,
        definition,
        artifactDir: artifactDir,
        dataDir: config.server.dataDir,
      );
      recorder.start();

      // Start workflow
      final variables = {
        'FEATURE':
            'Create exactly one new markdown file at notes/e2e-spec-$timestamp.md '
            'with one heading "E2E Spec Test" and one bullet "Automated test artifact" only.',
        'PROJECT': 'workflow-testing',
        'BRANCH': 'main',
      };
      final run = await w.workflowService.start(definition, variables, headless: true);
      final completionFuture = awaitWorkflowCompletion(w.eventBus, run.id);

      // Wait for workflow to complete
      final finalStatus = await completionFuture.timeout(
        Duration(minutes: 25),
        onTimeout: () {
          fail('Workflow timed out after 25 minutes');
        },
      );

      // Allow pending events to settle
      await Future<void>.delayed(Duration(seconds: 2));
      await recorder.dispose();

      // Accept completed or paused (paused = remediation loop exhausted max iterations,
      // which is a valid non-deterministic outcome in an LLM-driven e2e test).
      expect(
        finalStatus,
        anyOf(WorkflowRunStatus.completed, WorkflowRunStatus.paused),
        reason: 'spec-and-implement should complete or pause (remediation loop exhausted)',
      );

      // Core pipeline steps must appear in order. When paused after remediation
      // loop exhaustion, update-state won't run.
      final expectedOrder = finalStatus == WorkflowRunStatus.completed
          ? [
              'discover-project',
              'spec',
              'revise-spec',
              'implement',
              'verify-refine',
              'integrated-review',
              'update-state',
            ]
          : ['discover-project', 'spec', 'revise-spec', 'implement', 'verify-refine', 'integrated-review'];
      expectStepOrder(recorder, expectedOrder);

      // Assert context handoff: discover output flows into spec
      expectStepInputContains(recorder, 'spec', 'framework');

      // Assert worktrees were recorded for coding steps
      expectWorktreeRecorded(recorder, 'implement');

      // Publish assertions only apply when the workflow completed.
      if (finalStatus == WorkflowRunStatus.completed) {
        final completedRun = await w.workflowService.get(run.id);
        expect(completedRun, isNotNull, reason: 'Completed run should be retrievable');
        expectPublishSuccess(completedRun!.contextJson);

        final publishBranch = _findPublishedBranch(fixtureDir, run.id);
        expect(publishBranch, isNotNull, reason: 'Integration branch should have been pushed to origin');

        if (publishBranch != null) {
          final prUrl = await createPr(branch: publishBranch, title: 'E2E spec-and-implement $timestamp');

          final prView = await Process.run('gh', ['pr', 'view', prUrl, '--json', 'url']);
          expect(prView.exitCode, 0, reason: 'PR should exist at $prUrl');
        }
      }
    } finally {
      Directory.current = savedCwd;
    }
  }, timeout: Timeout(Duration(minutes: 30)));

  // -------------------------------------------------------------------------
  // TI04: plan-and-implement e2e
  // -------------------------------------------------------------------------
  test('plan-and-implement e2e with real Codex harness and per-story worktrees', () async {
    final w = await wireUp(
      outputTransformer: _forceSinglePlanReviewRemediationLoop(
        remediationPlan:
            'Synthetic test remediation: rerun one remediation iteration and confirm '
            'the batch remains clean after re-validation and re-review.',
        implementationSummary:
            'Synthetic test summary: both story implementations merged cleanly, '
            'but the E2E test is forcing one remediation iteration for coverage.',
      ),
    );
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final artifactDir = _createPreservedArtifactDir('plan-and-implement-e2e');
    Logger('E2E.StepArtifacts').info('Preserving step artifacts in ${artifactDir.path}');

    final savedCwd = Directory.current;
    Directory.current = Directory(fixtureDir);

    try {
      final definition = w.registry.getByName('plan-and-implement')!;

      final recorder = WorkflowExecutionRecorder(
        w.eventBus,
        w.taskService,
        w.messageService,
        w.workflowService,
        definition,
        artifactDir: artifactDir,
        dataDir: config.server.dataDir,
      );
      recorder.start();

      final variables = {
        'REQUIREMENTS':
            'Split the work into exactly two THIN stories. '
            'Story 1: Create notes/e2e-plan-a-$timestamp.md with heading "Plan A" and one bullet only. '
            'Story 2: Create notes/e2e-plan-b-$timestamp.md with heading "Plan B" and one bullet only.',
        'PROJECT': 'workflow-testing',
        'BRANCH': 'main',
        'MAX_PARALLEL': '1',
      };
      final run = await w.workflowService.start(definition, variables, headless: true);
      final completionFuture = awaitWorkflowCompletion(w.eventBus, run.id);

      final finalStatus = await completionFuture.timeout(
        Duration(minutes: 25),
        onTimeout: () {
          fail('Workflow timed out after 25 minutes');
        },
      );

      await Future<void>.delayed(Duration(seconds: 2));
      await recorder.dispose();

      // Accept completed or paused (paused = remediation/review loop exhausted).
      expect(
        finalStatus,
        anyOf(WorkflowRunStatus.completed, WorkflowRunStatus.paused),
        reason: 'plan-and-implement should complete or pause (loop exhausted)',
      );

      // This E2E forces at least one remediation-loop iteration when plan-review
      // would otherwise be clean, so the remediation loop should always appear.
      final coreSteps = finalStatus == WorkflowRunStatus.completed
          ? [
              'discover-project',
              'plan',
              'revise-plan',
              'spec-plan',
              'implement',
              'verify-refine',
              'quick-review',
              'plan-review',
              'remediate',
              're-verify-refine',
              're-review',
              'update-state',
            ]
          : [
              'discover-project',
              'plan',
              'revise-plan',
              'spec-plan',
              'implement',
              'verify-refine',
              'quick-review',
              'plan-review',
              'remediate',
              're-verify-refine',
              're-review',
            ];
      expectStepOrder(recorder, coreSteps);

      // spec-plan runs once
      expect(recorder.count('spec-plan'), 1, reason: 'spec-plan should run exactly once');

      // implement, verify-refine should run at least twice (per story) — regardless of final status
      expect(
        recorder.count('implement'),
        greaterThanOrEqualTo(2),
        reason: 'implement should run at least twice (once per story)',
      );
      expect(
        recorder.count('verify-refine'),
        greaterThanOrEqualTo(2),
        reason: 'verify-refine should run at least twice',
      );

      expect(recorder.count('quick-review'), greaterThanOrEqualTo(2), reason: 'quick-review should run at least twice');
      expect(recorder.count('plan-review'), 1, reason: 'plan-review should run exactly once');
      expect(recorder.count('remediate'), greaterThanOrEqualTo(1), reason: 'remediate should run at least once');
      expect(
        recorder.count('re-verify-refine'),
        greaterThanOrEqualTo(1),
        reason: 're-verify-refine should run at least once',
      );
      expect(recorder.count('re-review'), greaterThanOrEqualTo(1), reason: 're-review should run at least once');
      expectStepInputContains(recorder, 'remediate', '<review_findings>');

      // Assert worktrees were recorded for coding steps
      expectWorktreeRecorded(recorder, 'implement');

      // Publish assertions only when completed
      if (finalStatus == WorkflowRunStatus.completed) {
        final completedRun = await w.workflowService.get(run.id);
        expect(completedRun, isNotNull, reason: 'Completed run should be retrievable');
        expectPublishSuccess(completedRun!.contextJson);

        final publishBranch = _findPublishedBranch(fixtureDir, run.id);
        expect(publishBranch, isNotNull, reason: 'Integration branch should have been pushed to origin');

        if (publishBranch != null) {
          final prUrl = await createPr(branch: publishBranch, title: 'E2E plan-and-implement $timestamp');

          final prView = await Process.run('gh', ['pr', 'view', prUrl, '--json', 'url,files']);
          expect(prView.exitCode, 0, reason: 'PR should exist at $prUrl');
        }
      }
    } finally {
      Directory.current = savedCwd;
    }
  }, timeout: Timeout(Duration(minutes: 30)));
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Finds the workflow integration branch that was pushed to origin.
String? _findPublishedBranch(String projectDir, String runId) {
  final sanitizedId = runId.replaceAll('-', '');
  final candidates = ['dartclaw/workflow/$sanitizedId/integration', 'dartclaw/workflow/$sanitizedId'];
  for (final branch in candidates) {
    final result = Process.runSync('git', ['rev-parse', '--verify', 'origin/$branch'], workingDirectory: projectDir);
    if (result.exitCode == 0) return branch;
  }
  return null;
}
