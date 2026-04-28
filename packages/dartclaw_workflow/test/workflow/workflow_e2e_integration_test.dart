@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/workflow/cli_workflow_wiring.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;
import 'package:dartclaw_core/dartclaw_core.dart'
    show KvService, MessageService, Task, TaskEventCreatedEvent, WorkflowStepCompletedEvent;
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

import '../fixtures/e2e_fixture.dart';
import 'workflow_e2e_test_support.dart';

WorkflowStepOutputTransformer _forceSinglePlanReviewRemediationLoop({
  required String remediationPlan,
  required String implementationSummary,
  required Set<String> targetReviews,
}) {
  final forcedTargets = <String>{};
  final log = Logger('E2E.ForcedRemediation');
  return (run, definition, step, task, outputs) {
    if (definition.name != 'plan-and-implement' ||
        !targetReviews.contains(step.id) ||
        forcedTargets.contains(step.id)) {
      return outputs;
    }
    final transformed = forcedReviewRemediationOutputs(
      stepId: step.id,
      outputs: outputs,
      targetReviews: targetReviews,
      remediationPlan: remediationPlan,
      implementationSummary: implementationSummary,
    );
    if (identical(transformed, outputs)) {
      return outputs;
    }

    forcedTargets.add(step.id);
    log.info(
      'Forcing a single remediation-loop iteration for workflow ${run.id} '
      'by overriding clean ${step.id} outputs',
    );
    return transformed;
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
  // sessionTotalTokens mirrors session_cost:<sessionId>['total_tokens'],
  // which TaskExecutor._trackWorkflowSessionUsage writes as input + output
  // (excludes cache-read/write). step_delta_tokens is the per-step baseline-subtracted delta.
  final int sessionTotalTokens;
  final int stepDeltaTokens;
  final int inputTokensNew;
  final int cacheReadTokens;
  final int outputTokens;
  final Map<String, dynamic> configJson;
  final Map<String, dynamic>? worktreeJson;
  final String? sessionId;
  final Map<String, dynamic> inputs;
  final Map<String, dynamic> outputs;
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
    required this.sessionTotalTokens,
    required this.stepDeltaTokens,
    required this.inputTokensNew,
    required this.cacheReadTokens,
    required this.outputTokens,
    required this.configJson,
    this.worktreeJson,
    this.sessionId,
    this.inputs = const {},
    this.outputs = const {},
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
  final KvService _kvService;
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
  late final StreamSubscription<TaskEventCreatedEvent> _taskEventSub;

  final _pending = <String, WorkflowStepTrace>{};

  // Per-task accumulator for TaskEvent rows so they land in the preserved
  // per-step artifact alongside messages. The backing task_events.db lives
  // inside the test's temp runtime directory and gets wiped in tearDown —
  // without this capture, post-test inspection would have to infer event
  // kinds from transcripts (S25 TI11 follow-up).
  final Map<String, List<Map<String, dynamic>>> _taskEventsByTaskId = {};

  WorkflowExecutionRecorder(
    this._eventBus,
    this._taskService,
    this._messageService,
    this._workflowService,
    this._kvService,
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
    _taskEventSub = _eventBus.on<TaskEventCreatedEvent>().listen((event) {
      _taskEventsByTaskId.putIfAbsent(event.taskId, () => []).add({
        'eventId': event.eventId,
        'kind': event.kind,
        'details': event.details,
        'timestamp': event.timestamp.toIso8601String(),
      });
    });

    _queuedSub = _eventBus.on<TaskStatusChangedEvent>().where((e) => e.newStatus == TaskStatus.queued).listen((
      e,
    ) async {
      await Future<void>.delayed(Duration.zero);
      final task = await _taskService.get(e.taskId);
      if (task == null || task.stepIndex == null || task.workflowRunId == null) return;
      if (task.stepIndex! < 0 || task.stepIndex! >= _definition.steps.length) {
        _log.warning(
          'Skipping auxiliary workflow task ${task.id} with out-of-range stepIndex=${task.stepIndex} '
          'for definition "${_definition.name}" (${_definition.steps.length} steps)',
        );
        return;
      }

      final step = _definition.steps[task.stepIndex!];
      final stepKey = step.id;
      final occurrence = (_occurrenceByStep[stepKey] ?? 0) + 1;
      _occurrenceByStep[stepKey] = occurrence;
      final run = await _workflowService.get(task.workflowRunId!);
      final contextData = _contextData(run?.contextJson);
      final inputs = <String, dynamic>{for (final key in step.inputs) key: contextData[key]};

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
        sessionTotalTokens: 0,
        stepDeltaTokens: 0,
        inputTokensNew: 0,
        cacheReadTokens: 0,
        outputTokens: 0,
        configJson: Map<String, dynamic>.from(task.configJson),
        worktreeJson: task.worktreeJson,
        inputs: inputs,
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
      final sessionCost = sessionId == null ? const <String, dynamic>{} : await _readSessionCost(sessionId);
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

      Map<String, dynamic> outputs = const {};
      try {
        outputs = await _contextExtractor.extract(_definition.steps[event.stepIndex], task);
      } catch (error, st) {
        _log.warning('Failed to extract context outputs for ${event.stepId}', error, st);
      }
      final stepScopedContext = _buildStepScopedContext(
        runContext: _contextData((await _workflowService.get(event.runId))?.contextJson),
        stepId: event.stepId,
      );

      final taskEvents = List<Map<String, dynamic>>.unmodifiable(_taskEventsByTaskId[task.id] ?? const []);

      await _writeArtifact(
        pending: pending,
        task: task,
        stepName: event.stepName,
        stepSuccess: event.success,
        terminalStatus: task.status,
        tokenCount: event.tokenCount,
        sessionTotalTokens: (sessionCost['total_tokens'] as num?)?.toInt() ?? 0,
        stepDeltaTokens: event.tokenCount,
        inputTokensNew: _tokenMetric(task.configJson, 'inputTokensNew'),
        cacheReadTokens: _tokenMetric(task.configJson, 'cacheReadTokens'),
        outputTokens: _tokenMetric(task.configJson, 'outputTokens'),
        sessionId: sessionId,
        outputs: outputs,
        stepScopedContext: stepScopedContext,
        lastUserMessage: lastUserMessage,
        lastAssistantMessage: lastAssistantMessage,
        persistedMessages: persistedMessages,
        taskEvents: taskEvents,
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
          sessionTotalTokens: (sessionCost['total_tokens'] as num?)?.toInt() ?? 0,
          stepDeltaTokens: event.tokenCount,
          inputTokensNew: _tokenMetric(task.configJson, 'inputTokensNew'),
          cacheReadTokens: _tokenMetric(task.configJson, 'cacheReadTokens'),
          outputTokens: _tokenMetric(task.configJson, 'outputTokens'),
          configJson: pending.configJson,
          worktreeJson: task.worktreeJson ?? pending.worktreeJson,
          sessionId: sessionId,
          inputs: pending.inputs,
          outputs: outputs,
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
    await _taskEventSub.cancel();
  }

  int count(String stepKey) => stepOrder.where((s) => s == stepKey).length;

  List<WorkflowStepTrace> tracesForStep(String stepKey) => traces.where((t) => t.stepKey == stepKey).toList();

  Future<void> _writeArtifact({
    required WorkflowStepTrace pending,
    required Task task,
    required String stepName,
    required bool stepSuccess,
    required TaskStatus terminalStatus,
    required int tokenCount,
    required int sessionTotalTokens,
    required int stepDeltaTokens,
    required int inputTokensNew,
    required int cacheReadTokens,
    required int outputTokens,
    required String? sessionId,
    required Map<String, dynamic> outputs,
    required Map<String, dynamic> stepScopedContext,
    required String? lastUserMessage,
    required String? lastAssistantMessage,
    required List<Map<String, dynamic>> persistedMessages,
    required List<Map<String, dynamic>> taskEvents,
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
      'stepSuccess': stepSuccess,
      'stepOutcome': stepScopedContext['step.${pending.stepKey}.outcome'],
      'stepOutcomeReason': stepScopedContext['step.${pending.stepKey}.outcome.reason'],
      'tokenCount': tokenCount,
      'session_total_tokens': sessionTotalTokens,
      'step_delta_tokens': stepDeltaTokens,
      'input_tokens_new': inputTokensNew,
      'cache_read_tokens': cacheReadTokens,
      'output_tokens': outputTokens,
      'queuedAt': pending.queuedAt.toIso8601String(),
      'completedAt': DateTime.now().toIso8601String(),
      'sessionId': sessionId,
      'provider': task.provider,
      'providerSessionId': null,
      'workflowRunId': task.workflowRunId,
      'stepIndex': task.stepIndex,
      'configJson': task.configJson,
      'worktreeJson': task.worktreeJson ?? pending.worktreeJson,
      'inputs': pending.inputs,
      'outputs': outputs,
      'stepScopedContext': stepScopedContext,
      'lastUserMessage': lastUserMessage,
      'lastAssistantMessage': lastAssistantMessage,
      'messages': persistedMessages,
      'taskEvents': taskEvents,
    };
    await file.writeAsString(const JsonEncoder.withIndent('  ').convert(payload));
    _log.info('Wrote step artifact: ${file.path}');
  }

  Future<Map<String, dynamic>> _readSessionCost(String sessionId) async {
    final raw = await _kvService.get('session_cost:$sessionId');
    if (raw == null || raw.isEmpty) return const <String, dynamic>{};
    final decoded = jsonDecode(raw);
    return decoded is Map<String, dynamic> ? decoded : const <String, dynamic>{};
  }
}

int _tokenMetric(Map<String, dynamic> configJson, String key) {
  final workflowKey = switch (key) {
    'inputTokensNew' => '_workflowInputTokensNew',
    'cacheReadTokens' => '_workflowCacheReadTokens',
    'outputTokens' => '_workflowOutputTokens',
    _ => key,
  };
  final value = configJson[workflowKey];
  return switch (value) {
    final int intValue when intValue >= 0 => intValue,
    final num numValue when numValue >= 0 => numValue.toInt(),
    _ => 0,
  };
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
    if (entry.key == stepId ||
        entry.key.startsWith('$stepId.') ||
        entry.key.startsWith('$stepId[') ||
        entry.key.startsWith('step.$stepId.') ||
        entry.key.startsWith('step.$stepId[')) {
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
  expectStepOrderStrict(recorder.stepOrder, expectedSteps);
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

void expectStepInputContainsProjectIndex(WorkflowExecutionRecorder recorder, String stepKey) {
  final inputs = recorder.tracesForStep(stepKey).map((trace) => trace.inputs).toList(growable: false);
  expectStepInputsContainProjectIndex(inputs, stepKey);
}

void expectStepInputContainsAllSubstrings(
  WorkflowExecutionRecorder recorder,
  String stepKey,
  List<String> expectedSubstrings,
) {
  expectStepInputContainsAll(recorder.descriptionsByStep[stepKey] ?? const [], stepKey, expectedSubstrings);
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

void expectNoMissingFisFallbacks(Directory artifactDir) {
  final banned = ['fallback because FIS file is missing', 'MISSING REQUIREMENT'];
  final offenders = <String>[];
  for (final file in artifactDir.listSync().whereType<File>().where((file) => file.path.endsWith('.json'))) {
    final text = file.readAsStringSync();
    for (final marker in banned) {
      if (text.contains(marker)) {
        offenders.add('${p.basename(file.path)} contains "$marker"');
      }
    }
  }
  expect(offenders, isEmpty, reason: offenders.join('\n'));
}

void expectCommittedPlanArtifacts({required String projectDir, required Directory artifactDir}) {
  final planArtifacts = artifactDir
      .listSync()
      .whereType<File>()
      .where((file) => file.path.endsWith('.json'))
      .map((file) => jsonDecode(file.readAsStringSync()) as Map<String, dynamic>)
      .where((payload) => payload['stepKey'] == 'plan')
      .toList(growable: false);
  expect(planArtifacts, isNotEmpty, reason: 'Expected at least one preserved plan artifact.');

  final requiredPaths = <String>{};
  for (final payload in planArtifacts) {
    final outputs = (payload['outputs'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    final planPath = outputs['plan'] as String?;
    if (planPath != null && planPath.trim().isNotEmpty) {
      requiredPaths.add(planPath.trim());
      final planDir = p.dirname(planPath.trim());
      requiredPaths.add(p.join(planDir, '.technical-research.md'));
    }
    final storySpecs = outputs['story_specs'];
    if (storySpecs is Map<Object?, Object?> && storySpecs['items'] is List<Object?>) {
      for (final item in (storySpecs['items'] as List<Object?>).whereType<Map<Object?, Object?>>()) {
        final specPath = item['spec_path']?.toString().trim();
        if (specPath != null && specPath.isNotEmpty) {
          requiredPaths.add(specPath);
        }
      }
    }
  }

  final missing = <String>[];
  for (final relativePath in requiredPaths) {
    final result = Process.runSync('git', ['cat-file', '-e', 'HEAD:$relativePath'], workingDirectory: projectDir);
    if (result.exitCode != 0) {
      missing.add(relativePath);
    }
  }
  expect(missing, isEmpty, reason: 'Expected committed plan artifacts at HEAD: $missing');
}

void expectPublishSuccess(Map<String, dynamic> contextJson) {
  final contextData = (contextJson['data'] as Map?)?.cast<String, dynamic>() ?? contextJson;
  expect(
    contextData['publish.status'],
    'success',
    reason: 'Workflow publish should have status "success", got "${contextData['publish.status']}"',
  );
}

/// Fails loudly when the workflow terminated in `failed` state with a
/// publish-step error.
///
/// Without this check, a publish failure (push rejected, `gh pr create`
/// non-zero, auth miss, etc.) would cause the test's existing
/// `if (finalStatus == completed)` guard to silently skip the URL assertion
/// and the test would pass with a broken publish path.
void expectPublishFailureNotSilent(dynamic completedRun, WorkflowRunStatus finalStatus) {
  if (finalStatus != WorkflowRunStatus.failed) return;
  final contextJson = completedRun?.contextJson as Map<String, dynamic>? ?? const {};
  final data = (contextJson['data'] as Map?)?.cast<String, dynamic>() ?? contextJson;
  final publishStatus = data['publish.status'] as String?;
  final publishError = data['publish.error'] as String?;
  if (publishStatus == 'failed' || (publishError != null && publishError.isNotEmpty)) {
    fail('Workflow terminated in failed state during publish: ${publishError ?? '(no error detail)'}');
  }
  // Non-publish failures (e.g. earlier step failure) are the test's existing
  // concern — don't double-report here.
}

/// Asserts the workflow's publish callback produced a valid PR URL that
/// resolves to a real GitHub pull request.
///
/// Proves the full pipeline: publish hook → `WorkflowGitPublishResult.prUrl`
/// → `context['publish.pr_url']` → serialized `contextJson`. Also verifies
/// `publish.branch` matches the branch that was actually pushed to origin
/// and that `gh pr view <url>` resolves (protects against stale or
/// fabricated URLs landing in the context).
void expectWorkflowCreatedPr(Map<String, dynamic> contextJson, {required String? expectedBranch}) {
  final contextData = (contextJson['data'] as Map?)?.cast<String, dynamic>() ?? contextJson;

  final prUrl = contextData['publish.pr_url'] as String? ?? '';
  expect(prUrl, isNotEmpty, reason: 'Workflow publish should have emitted a non-empty publish.pr_url; got "$prUrl"');
  expect(
    prUrl,
    matches(RegExp(r'^https://github\.com/[^/\s]+/[^/\s]+/pull/\d+$')),
    reason: 'publish.pr_url should be a GitHub pull-request URL, got "$prUrl"',
  );

  if (expectedBranch != null) {
    expect(
      contextData['publish.branch'],
      expectedBranch,
      reason: 'publish.branch should match the branch that was pushed to origin',
    );
  }
  expect(contextData['publish.remote'], 'origin', reason: 'publish.remote should be "origin"');

  // Resolve the URL against GitHub to confirm the PR exists — catches the
  // case where the context carries a well-shaped but fabricated URL.
  final prView = Process.runSync('gh', ['pr', 'view', prUrl, '--json', 'url']);
  expect(prView.exitCode, 0, reason: 'gh pr view failed for $prUrl: ${prView.stderr}');
}

void expectWorkflowPublishedBranchOnly(Map<String, dynamic> contextJson, {required String expectedBranch}) {
  final contextData = (contextJson['data'] as Map?)?.cast<String, dynamic>() ?? contextJson;
  expectPublishSuccess(contextJson);
  expect(contextData['publish.branch'], expectedBranch, reason: 'publish.branch should match the pushed branch');
  expect(contextData['publish.remote'], 'origin', reason: 'publish.remote should be "origin"');
  expect(
    contextData['publish.pr_url'] as String? ?? '',
    isEmpty,
    reason: 'publish.pr_url should stay empty when gh PR creation is unavailable',
  );
}

// ---------------------------------------------------------------------------
// TI05: PR cleanup helpers
// ---------------------------------------------------------------------------

Future<void> _closePr(String prUrl) async {
  if (prUrl.isEmpty) return;
  await Process.run('gh', ['pr', 'close', prUrl, '--delete-branch']);
}

Future<void> _closePrByBranch(String branch, String repo, {String? projectDir}) async {
  await closePrByBranch(branch: branch, repo: repo, projectDir: projectDir);
}

Future<void> _cloneTodoAppFixtureRepo(String targetDir) async {
  Directory(targetDir).parent.createSync(recursive: true);

  // Two auth paths:
  // 1. HTTPS+token — for CI / headless envs. Chosen when GITHUB_TOKEN is set.
  // 2. SSH — for a developer who already has their key in ssh-agent locally.
  //    Uses BatchMode=yes so any missing-agent/passphrase situation fails
  //    fast with a clear error instead of hanging on an interactive prompt.
  final githubToken = Platform.environment['GITHUB_TOKEN']?.trim();
  final useHttps = githubToken != null && githubToken.isNotEmpty;
  final cloneUri = useHttps
      ? Uri(
          scheme: 'https',
          userInfo: 'x-access-token:$githubToken',
          host: 'github.com',
          path: '/DartClaw/workflow-test-todo-app.git',
        ).toString()
      : 'git@github.com:DartClaw/workflow-test-todo-app.git';
  final cloneEnv = <String, String>{
    'GIT_TERMINAL_PROMPT': '0',
    if (!useHttps) 'GIT_SSH_COMMAND': 'ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new',
  };

  final result = await Process.run('git', ['clone', '--depth', '1', cloneUri, targetDir], environment: cloneEnv);
  if (result.exitCode != 0) {
    final mode = useHttps ? 'HTTPS+token' : 'SSH (ssh-agent)';
    throw StateError(
      'Failed to clone workflow-test-todo-app fixture repo over $mode: ${result.stderr}\n'
      'Tip: set GITHUB_TOKEN for HTTPS, or ensure your SSH key is loaded via `ssh-add` for SSH.',
    );
  }
  Process.runSync('git', ['config', 'user.name', 'Workflow E2E Test'], workingDirectory: targetDir);
  Process.runSync('git', ['config', 'user.email', 'workflow-e2e@example.com'], workingDirectory: targetDir);
  assertKnownDefectsBacklogEntries(targetDir);
}

// ---------------------------------------------------------------------------
// Main test group
// ---------------------------------------------------------------------------

void main() {
  late String fixtureDir;
  late DartclawConfig config;
  E2EFixtureInstance? fixture;
  final createdPrUrls = <String>[];
  final createdBranches = <String>{};
  var canCreateGitHubPr = false;
  late final bool requireCompleted;

  CliWorkflowWiring? wiring;
  LogService? logService;

  // EventBus diagnostic subscriptions — cancelled in tearDownAll.
  final diagnosticSubs = <StreamSubscription<Object>>[];

  setUpAll(() async {
    // ── Logging ──────────────────────────────────────────────────────────
    logService = LogService.fromConfig(level: e2eLogLevelFromEnv(Platform.environment));
    logService!.install();
    requireCompleted = e2eRequireCompletedFromEnv(Platform.environment);

    final prereqs = await evaluateWorkflowE2ePrerequisites(environment: Platform.environment, runProcess: Process.run);
    if (prereqs.shouldSkip) {
      markTestSkipped(prereqs.skipReason!);
      return;
    }
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
    canCreateGitHubPr = await canCreateGitHubPrForEnv(environment: Platform.environment, runProcess: Process.run);
    if (!canCreateGitHubPr) {
      Logger('E2E.Setup').warning(
        'gh PR creation is unavailable; workflow e2e will validate branch publish only. '
        'Export GITHUB_TOKEN or fix `gh auth status` to enable PR URL assertions.',
      );
    }
    fixture = await E2EFixture()
        .withProject(
          'workflow-test-todo-app',
          credentials: Platform.environment['GITHUB_TOKEN']?.trim().isNotEmpty == true ? 'github-main' : null,
          localPath: Platform.environment['GITHUB_TOKEN']?.trim().isNotEmpty != true,
        )
        .withProjectSetup(_cloneTodoAppFixtureRepo)
        .build();
    fixtureDir = fixture!.projectDir;
    // Keep the cloned project checkout pristine so workflow bootstrap can
    // switch to its owned branch before the first step runs. The fixture
    // workspace/workflow-workspace already provide the AGENTS.md content that
    // the workflow task path injects into prompts and Codex home.
    assertKnownDefectsBacklogEntries(fixtureDir);
    config = fixture!.config;
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
      await _closePrByBranch(branch, 'DartClaw/workflow-test-todo-app', projectDir: fixtureDir);
    }

    if (fixture != null) {
      await fixture!.dispose();
      fixture = null;
    }
  });

  // -------------------------------------------------------------------------
  // Shared helper: create PR after push and track for cleanup
  // Declared before [wireUp] so the injected `prCreator` closure can capture
  // it without a forward-reference error.
  // -------------------------------------------------------------------------
  Future<String> createPr({required String branch, required String title}) async {
    createdBranches.add(branch);
    final result = await Process.run('gh', [
      'pr',
      'create',
      '--repo',
      'DartClaw/workflow-test-todo-app',
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
  // Shared helper: wire up CliWorkflowWiring with in-memory SQLite
  //
  // [prTitle] is used to build the PR title if the workflow reaches publish.
  // Production CliWorkflowWiring does not inject a prCreator (standalone
  // publish only pushes the branch). The e2e test injects one that shells
  // out to `gh pr create` so `publish.pr_url` can be asserted end to end.
  // -------------------------------------------------------------------------
  Future<CliWorkflowWiring> wireUp({WorkflowStepOutputTransformer? outputTransformer, String? prTitle}) async {
    final resolvedTitle = prTitle ?? 'E2E workflow run ${DateTime.now().millisecondsSinceEpoch}';
    final w = CliWorkflowWiring(
      config: config,
      dataDir: config.server.dataDir,
      searchDbFactory: (_) => sqlite3.openInMemory(),
      taskDbFactory: (_) => sqlite3.openInMemory(),
      workflowStepOutputTransformer: outputTransformer,
      prCreator: canCreateGitHubPr
          ? ({required runId, required projectId, required branch}) async {
              // Mirror the server-backed PrCreator contract: never throw — surface
              // errors as status='failed' so the workflow's publish step records a
              // clean failure and the test's `expect(finalStatus, isNot(failed))`
              // safety net below reports it clearly.
              try {
                final url = await createPr(branch: branch, title: resolvedTitle);
                return CliWorkflowPrResult(status: 'success', prUrl: url);
              } catch (e) {
                return CliWorkflowPrResult(status: 'failed', prUrl: '', error: 'createPr failed: $e');
              }
            }
          : null,
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
  // TI03: spec-and-implement e2e
  // -------------------------------------------------------------------------
  test('spec-and-implement e2e with real Codex harness and git operations', () async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final w = await wireUp(prTitle: 'E2E spec-and-implement $timestamp');
    final artifactDir = _createPreservedArtifactDir('spec-and-implement-e2e');
    Logger('E2E.StepArtifacts').info('Preserving step artifacts in ${artifactDir.path}');

    // Look up the built-in definition
    final definition = w.registry.getByName('spec-and-implement')!;

    // Start step recorder
    final recorder = WorkflowExecutionRecorder(
      w.eventBus,
      w.taskService,
      w.messageService,
      w.workflowService,
      w.kvService,
      definition,
      artifactDir: artifactDir,
      dataDir: config.server.dataDir,
    );
    recorder.start();

    // Start workflow
    //
    // The FEATURE text references a defect tracked in the fixture repo's
    // docs/PRODUCT-BACKLOG.md. The agent is expected to consult the backlog
    // via discover-project / spec steps rather than reason from the prose
    // description alone — this exercises the project-index → spec handoff
    // that a trivial "create a markdown file" prompt cannot.
    final variables = {
      'FEATURE':
          'Fix BUG-001 from docs/PRODUCT-BACKLOG.md (Known Defects section): '
          'the sidebar incomplete-count is not updated when a todo is deleted. '
          'Follow the codebase\'s existing HTMX out-of-band swap pattern — '
          'see how toggle_todo updates the same count in its response.',
      'PROJECT': 'workflow-test-todo-app',
      'BRANCH': 'main',
    };
    final run = await w.workflowService.start(definition, variables, headless: true);
    final completionFuture = awaitWorkflowCompletion(w.eventBus, run.id);

    // 60 min covers up to ~3 remediation iterations (maxIterations=3); the
    // happy path runs in ~15-18 min.
    final finalStatus = await completionFuture.timeout(
      Duration(minutes: 60),
      onTimeout: () {
        fail('Workflow timed out after 60 minutes');
      },
    );

    // Allow pending events to settle
    await Future<void>.delayed(Duration(seconds: 2));
    await recorder.dispose();

    expectWorkflowFinalStatus(finalStatus: finalStatus, requireCompleted: requireCompleted, runId: run.id);

    // Core pipeline steps that must ALWAYS appear in order. Gated/optional
    // steps (revise-spec runs only when spec_source=synthesized & confidence<7;
    // remediate/re-review only when integrated-review finds issues) are
    // excluded — assert their runs separately if they occur.
    final expectedOrder = ['discover-project', 'spec', 'implement', 'integrated-review'];
    expectStepOrder(recorder, expectedOrder);

    // Assert context handoff: discover output flows into spec
    expectStepInputContainsProjectIndex(recorder, 'spec');

    // Assert worktrees were recorded for coding steps
    expectWorktreeRecorded(recorder, 'implement');

    // Prove the token-mirroring path wrote non-zero `_workflow*Tokens*`
    // onto task.configJson for steps that ran agent turns. Catches the
    // regression where artifact consumers saw zero totals despite the
    // step completing with real usage.
    expectPreservedArtifactsHaveNonZeroTokenKeys(
      artifactDir,
      agentSteps: const ['discover-project', 'spec', 'implement', 'integrated-review'],
    );
    expectNoMissingFisFallbacks(artifactDir);

    // Safety net: publish step runs at the end of the workflow. A `failed`
    // terminal state here usually means the publish callback (push or PR
    // creation) errored — surface that up front so the test doesn't pass
    // silently by skipping the publish block below.
    expectPublishFailureNotSilent(await w.workflowService.get(run.id), finalStatus);

    // Publish assertions only apply when the workflow completed.
    if (finalStatus == WorkflowRunStatus.completed) {
      final completedRun = await w.workflowService.get(run.id);
      expect(completedRun, isNotNull, reason: 'Completed run should be retrievable');
      expectPublishSuccess(completedRun!.contextJson);

      final publishBranch = _findPublishedBranch(fixtureDir, run.id);
      expect(publishBranch, isNotNull, reason: 'Integration branch should have been pushed to origin');
      final branch = publishBranch!;
      createdBranches.add(branch);
      await assertDiffTouchesExpectedFiles(
        projectDir: fixtureDir,
        headRef: 'main',
        publishedBranch: 'origin/$branch',
        bugAllowlist: bugFileAllowlist,
        activeBugs: const ['BUG-001'],
      );

      if (canCreateGitHubPr) {
        // Assert the workflow itself produced the PR URL via its publish
        // callback (injected test prCreator → `gh pr create` → URL → context).
        expectWorkflowCreatedPr(completedRun.contextJson, expectedBranch: branch);
      } else {
        expectWorkflowPublishedBranchOnly(completedRun.contextJson, expectedBranch: branch);
      }
    }
  }, timeout: Timeout(Duration(minutes: 65)));

  // -------------------------------------------------------------------------
  // TI04: plan-and-implement e2e
  // -------------------------------------------------------------------------
  test('plan-and-implement e2e with real Codex harness and per-story worktrees', () async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final w = await wireUp(
      outputTransformer: _forceSinglePlanReviewRemediationLoop(
        remediationPlan:
            'Synthetic test remediation: rerun one remediation iteration and confirm '
            'the batch remains clean after re-validation and re-review.',
        implementationSummary:
            'Synthetic test summary: both story implementations merged cleanly, '
            'but the E2E test is forcing one remediation iteration for coverage.',
        targetReviews: const {'plan-review', 'architecture-review'},
      ),
      prTitle: 'E2E plan-and-implement $timestamp',
    );
    final artifactDir = _createPreservedArtifactDir('plan-and-implement-e2e');
    Logger('E2E.StepArtifacts').info('Preserving step artifacts in ${artifactDir.path}');

    final definition = w.registry.getByName('plan-and-implement')!;

    final recorder = WorkflowExecutionRecorder(
      w.eventBus,
      w.taskService,
      w.messageService,
      w.workflowService,
      w.kvService,
      definition,
      artifactDir: artifactDir,
      dataDir: config.server.dataDir,
    );
    recorder.start();

    // Two independent defects from the fixture repo's Known Defects backlog.
    // Chosen so the two story worktrees touch disjoint files and can merge
    // without conflict, while still exercising the full plan → parallel
    // implement → review → remediate pipeline against a realistic codebase.
    final variables = {
      'REQUIREMENTS':
          'Fix BUG-002 and BUG-003 from docs/PRODUCT-BACKLOG.md (Known Defects section) '
          'as two independent, thin stories. '
          'Story 1: BUG-002 — due dates set in the edit dialog do not persist after save. '
          'Story 2: BUG-003 — quick-add todos have no default priority. '
          'Keep each story isolated to its own files; they must merge without conflict.',
      'PROJECT': 'workflow-test-todo-app',
      'BRANCH': 'main',
      'MAX_PARALLEL': '2',
    };
    final run = await w.workflowService.start(definition, variables, headless: true);
    final completionFuture = awaitWorkflowCompletion(w.eventBus, run.id);

    final finalStatus = await completionFuture.timeout(
      Duration(minutes: 75),
      onTimeout: () {
        fail('Workflow timed out after 75 minutes');
      },
    );

    await Future<void>.delayed(Duration(seconds: 2));
    await recorder.dispose();

    expectWorkflowFinalStatus(finalStatus: finalStatus, requireCompleted: requireCompleted, runId: run.id);

    // This E2E forces at least one remediation-loop iteration when plan-review
    // would otherwise be clean, so the remediation loop should always appear.
    final coreSteps = [
      'discover-project',
      'prd',
      'plan',
      'implement',
      'quick-review',
      'plan-review',
      'remediate',
      're-review',
    ];
    expectStepOrder(recorder, coreSteps);

    // merged plan step now emits both stories and story_specs in a single pass — runs exactly once.
    expect(recorder.count('plan'), 1, reason: 'plan should run exactly once');
    expect(recorder.count('prd'), 1, reason: 'prd should run exactly once');
    expect(
      recorder.count('revise-prd'),
      inInclusiveRange(0, 1),
      reason: 'revise-prd should be skipped on high-confidence PRDs and run at most once otherwise',
    );

    expect(
      recorder.count('implement'),
      greaterThanOrEqualTo(2),
      reason: 'implement should run at least twice (once per story)',
    );

    expect(recorder.count('quick-review'), greaterThanOrEqualTo(2), reason: 'quick-review should run at least twice');
    expect(recorder.count('plan-review'), 1, reason: 'plan-review should run exactly once');
    expect(recorder.count('remediate'), greaterThanOrEqualTo(1), reason: 'remediate should run at least once');
    expect(recorder.count('re-review'), greaterThanOrEqualTo(1), reason: 're-review should run at least once');
    expectStepInputContainsAllSubstrings(recorder, 'remediate', [
      '<review_findings>',
      '<architecture_review_findings>',
    ]);

    // Assert worktrees were recorded for coding steps
    expectWorktreeRecorded(recorder, 'implement');
    final implementPaths = recorder
        .tracesForStep('implement')
        .map((trace) => trace.worktreeJson!['path'] as String)
        .toList(growable: false);
    expectDistinctWorktreePaths(implementPaths);
    expectNoMissingFisFallbacks(artifactDir);
    expectCommittedPlanArtifacts(projectDir: fixtureDir, artifactDir: artifactDir);

    // Safety net — see spec-and-implement test above for rationale.
    expectPublishFailureNotSilent(await w.workflowService.get(run.id), finalStatus);

    // Publish assertions only when completed
    if (finalStatus == WorkflowRunStatus.completed) {
      final completedRun = await w.workflowService.get(run.id);
      expect(completedRun, isNotNull, reason: 'Completed run should be retrievable');
      expectPublishSuccess(completedRun!.contextJson);

      final publishBranch = _findPublishedBranch(fixtureDir, run.id);
      expect(publishBranch, isNotNull, reason: 'Integration branch should have been pushed to origin');
      final branch = publishBranch!;
      createdBranches.add(branch);
      await assertDiffTouchesExpectedFiles(
        projectDir: fixtureDir,
        headRef: 'main',
        publishedBranch: 'origin/$branch',
        bugAllowlist: bugFileAllowlist,
        activeBugs: const ['BUG-002', 'BUG-003'],
      );

      if (canCreateGitHubPr) {
        // Assert the workflow itself produced the PR URL via its publish
        // callback (injected test prCreator → `gh pr create` → URL → context).
        expectWorkflowCreatedPr(completedRun.contextJson, expectedBranch: branch);
      } else {
        expectWorkflowPublishedBranchOnly(completedRun.contextJson, expectedBranch: branch);
      }
    }
  }, timeout: Timeout(Duration(minutes: 80)));
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
