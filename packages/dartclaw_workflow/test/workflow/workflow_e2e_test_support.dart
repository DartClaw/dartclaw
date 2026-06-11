import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/workflow/cli_workflow_wiring.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show DartclawConfig;
import 'package:dartclaw_core/dartclaw_core.dart'
    show KvService, MessageService, Task, TaskEventCreatedEvent, WorkflowStepCompletedEvent;
import 'package:dartclaw_server/dartclaw_server.dart' show TaskService, WorkflowGitPortProcess;
import 'package:dartclaw_storage/dartclaw_storage.dart' show SqliteWorkflowStepExecutionRepository;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        EventBus,
        TaskStatus,
        TaskStatusChangedEvent,
        WorkflowDefinition,
        WorkflowRunStatus,
        WorkflowService,
        WorkflowStep;
import 'package:dartclaw_workflow/src/workflow/context_extractor.dart';
import 'package:dartclaw_workflow/src/workflow/workflow_context.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../fixtures/e2e_fixture.dart';

typedef WorkflowE2eProcessRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> arguments, {
      String? workingDirectory,
      Map<String, String>? environment,
    });

const fixtureSeedRegressionMessage =
    'Fixture upstream regressed; re-seed BUG-001..003 in DartClaw/workflow-test-todo-app docs/PRODUCT-BACKLOG.md';

const _todoAppFixtureReadOnlyUrl = 'https://github.com/DartClaw/workflow-test-todo-app.git';

const bugFileAllowlist = <String, List<String>>{
  'BUG-001': ['src/app/routes/todos.py', 'src/app/templates/partials/todo_deleted_oob.html'],
  'BUG-002': ['src/app/routes/todos.py', 'src/app/templates/app.html'],
  'BUG-003': ['src/app/routes/todos.py', 'src/app/templates/partials/todo_list_content.html'],
};

String e2eLogLevelFromEnv(Map<String, String> environment) {
  final levelName = (environment['DARTCLAW_E2E_LOG_LEVEL'] ?? 'INFO').trim();
  return levelName.isEmpty ? 'INFO' : levelName;
}

bool e2eRequireCompletedFromEnv(Map<String, String> environment) {
  final value = environment['DARTCLAW_E2E_REQUIRE_COMPLETED']?.trim().toLowerCase();
  return value == 'true' || value == '1' || value == 'yes';
}

Future<WorkflowE2ePrerequisiteResult> evaluateWorkflowE2ePrerequisites({
  required Map<String, String> environment,
  required WorkflowE2eProcessRunner runProcess,
}) async {
  final codex = await _runOk(runProcess, 'codex', ['--version']);
  if (!codex) {
    return const WorkflowE2ePrerequisiteResult.skip(
      'Codex is not available; install Codex, ensure it is on PATH, and authenticate or set CODEX_API_KEY.',
    );
  }

  final canCreateGitHubPr = await canCreateGitHubPrForEnv(environment: environment, runProcess: runProcess);
  if (canCreateGitHubPr) {
    return WorkflowE2ePrerequisiteResult.run(canCreateGitHubPr: true);
  }

  final canCloneFixture = await _canReadFixtureRepo(runProcess);
  if (!canCloneFixture) {
    return const WorkflowE2ePrerequisiteResult.skip(
      'Public HTTPS access to the workflow-test-todo-app fixture repo is required for branch-only workflow e2e; '
      'check network access or set GITHUB_TOKEN for authenticated HTTPS clone.',
    );
  }

  return WorkflowE2ePrerequisiteResult.run(canCreateGitHubPr: false);
}

Future<bool> canCreateGitHubPrForEnv({
  required Map<String, String> environment,
  required WorkflowE2eProcessRunner runProcess,
}) async {
  if (_hasGitHubTokenEnv(environment)) {
    return true;
  }
  final canCreatePr = await _runOk(runProcess, 'gh', ['auth', 'status']);
  return canCreatePr && await _runGitHubSshAuthenticated(runProcess);
}

void expectWorkflowFinalStatus({
  required WorkflowRunStatus finalStatus,
  required bool requireCompleted,
  required String runId,
  Logger? logger,
}) {
  if (requireCompleted) {
    expect(
      finalStatus,
      WorkflowRunStatus.completed,
      reason: 'completed was required; paused is not acceptable in strict mode for workflow $runId',
    );
    return;
  }

  expect(
    finalStatus,
    anyOf(WorkflowRunStatus.completed, WorkflowRunStatus.paused),
    reason: 'workflow should complete or pause (loop exhausted)',
  );
  if (finalStatus == WorkflowRunStatus.paused) {
    (logger ?? Logger('E2E')).warning(
      'Workflow $runId ended in $finalStatus - soft-paused (loop exhausted) accepted; '
      'export DARTCLAW_E2E_REQUIRE_COMPLETED=true to require completed.',
    );
  }
}

void expectStepOrderSubsequence(Iterable<String> actualSteps, List<String> expectedSteps) {
  final actual = actualSteps.toList(growable: false);
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

void expectStepOrderStrict(Iterable<String> actualSteps, List<String> expectedSteps) {
  final actual = actualSteps.toList(growable: false);
  expectStepOrderSubsequence(actual, expectedSteps);

  var searchStart = 0;
  for (var expectedIndex = 0; expectedIndex < expectedSteps.length - 1; expectedIndex++) {
    final current = expectedSteps[expectedIndex];
    final next = expectedSteps[expectedIndex + 1];
    final currentIndex = actual.indexOf(current, searchStart);
    final nextIndex = actual.indexOf(next, currentIndex + 1);
    final gap = actual.sublist(currentIndex + 1, nextIndex);
    final unexpected = gap.where((step) => !expectedSteps.contains(step)).toList(growable: false);
    if (unexpected.isNotEmpty) {
      fail(
        'Unexpected step(s) $unexpected appeared between "$current" and "$next".\n'
        'Expected strict sequence: $expectedSteps\nActual step order: $actual',
      );
    }
    searchStart = nextIndex;
  }
}

void expectStepInputsContainProjectIndex(List<Map<String, dynamic>> inputsByOccurrence, String stepKey) {
  if (inputsByOccurrence.isEmpty) {
    fail('No inputs recorded for step "$stepKey".');
  }
  for (final inputs in inputsByOccurrence) {
    final projectIndex = inputs['project_index'];
    if (projectIndex is! Map || projectIndex.isEmpty) {
      fail('Step "$stepKey" inputs["project_index"] should be a non-empty Map.');
    }
    final keys = projectIndex.keys.map((key) => '$key').toSet();
    final missing = const {'framework', 'state_protocol'}.difference(keys);
    if (missing.isNotEmpty) {
      fail('Step "$stepKey" project_index is missing key(s): ${missing.join(', ')}');
    }
  }
}

void expectStepInputContainsAll(List<String> descriptions, String stepKey, List<String> expectedSubstrings) {
  if (descriptions.isEmpty) {
    fail('No descriptions recorded for step "$stepKey".');
  }
  for (final expected in expectedSubstrings) {
    if (!descriptions.any((description) => description.contains(expected))) {
      final previews = descriptions.map((d) => d.length > 300 ? '${d.substring(0, 300)}...' : d).toList();
      fail('Step "$stepKey" description does not contain "$expected".\nPreviews: $previews');
    }
  }
}

void expectPreservedArtifactsHaveNonZeroTokenKeys(Directory artifactDir, {required List<String> agentSteps}) {
  final files = artifactDir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList();
  expect(files, isNotEmpty, reason: 'No preserved artifacts found under ${artifactDir.path}');

  final tokenKeys = const ['_workflowInputTokensNew', '_workflowCacheReadTokens', '_workflowOutputTokens'];
  final agentStepSet = agentSteps.toSet();
  final inspected = <String>[];
  final missing = <String>[];

  for (final file in files) {
    final payload = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final stepKey = payload['stepKey'] as String? ?? '';
    if (!agentStepSet.contains(stepKey)) continue;
    final configJson = (payload['configJson'] as Map?)?.cast<String, dynamic>() ?? const {};
    final values = {for (final key in tokenKeys) key: configJson[key]};
    inspected.add('${p.basename(file.path)} -> $values');
    final hasNonZero = tokenKeys.any((key) {
      final value = configJson[key];
      return value is num && value > 0;
    });
    if (!hasNonZero) {
      missing.add('$stepKey (${p.basename(file.path)})');
    }
  }

  expect(
    inspected,
    isNotEmpty,
    reason: 'Expected at least one preserved artifact for steps $agentSteps; inspected: $inspected',
  );
  expect(
    missing,
    isEmpty,
    reason:
        'Expected every preserved artifact under ${artifactDir.path} for agent steps $agentSteps '
        'to have at least one non-zero _workflow*Tokens* key.\nMissing: $missing\nInspected: $inspected',
  );
}

void assertKnownDefectsBacklogEntries(String targetDir) {
  final backlog = File(p.join(targetDir, 'docs', 'PRODUCT-BACKLOG.md'));
  if (!backlog.existsSync()) {
    fail(fixtureSeedRegressionMessage);
  }
  final text = backlog.readAsStringSync();
  final missing = const ['BUG-001', 'BUG-002', 'BUG-003'].where((id) => !text.contains(id)).toList();
  if (missing.isNotEmpty) {
    fail(fixtureSeedRegressionMessage);
  }
}

void expectDistinctWorktreePaths(List<String> paths) {
  expect(
    paths.toSet().length,
    paths.length,
    reason: 'per-story worktrees should be distinct paths; got duplicates: $paths',
  );
}

Future<void> assertDiffTouchesExpectedFiles({
  required String projectDir,
  required String headRef,
  required String publishedBranch,
  required Map<String, List<String>> bugAllowlist,
  required List<String> activeBugs,
  WorkflowE2eProcessRunner runProcess = Process.run,
}) async {
  final result = await runProcess('git', [
    'diff',
    '--name-only',
    '$headRef..$publishedBranch',
  ], workingDirectory: projectDir);
  if (result.exitCode != 0) {
    fail('git diff failed for $headRef..$publishedBranch: ${result.stderr}');
  }
  final touched = (result.stdout as String)
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);
  assertTouchedFilesMatchAllowlist(
    touched: touched,
    publishedBranch: publishedBranch,
    bugAllowlist: bugAllowlist,
    activeBugs: activeBugs,
  );
}

Future<void> closePrByBranch({
  required String branch,
  required String repo,
  String? projectDir,
  WorkflowE2eProcessRunner runProcess = Process.run,
  Logger? logger,
}) async {
  if (branch.isEmpty) return;
  final ghResult = await runProcess('gh', ['pr', 'close', branch, '--repo', repo, '--delete-branch']);
  if (ghResult.exitCode == 0 || projectDir == null) return;

  final gitResult = await runProcess(
    'git',
    ['push', 'origin', '--delete', branch],
    workingDirectory: projectDir,
    environment: const {
      'GIT_TERMINAL_PROMPT': '0',
      'GIT_SSH_COMMAND': 'ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new',
    },
  );
  if (gitResult.exitCode == 0) return;

  (logger ?? Logger('E2E.Cleanup')).warning(
    'Cleanup failed for branch $branch: '
    'gh pr close stderr=${ghResult.stderr}; '
    'git push --delete stderr=${gitResult.stderr}',
  );
}

void assertTouchedFilesMatchAllowlist({
  required List<String> touched,
  required String publishedBranch,
  required Map<String, List<String>> bugAllowlist,
  required List<String> activeBugs,
}) {
  if (touched.isEmpty) {
    fail('Published branch "$publishedBranch" has an empty diff against HEAD.');
  }
  for (final bug in activeBugs) {
    final allowed = bugAllowlist[bug] ?? const <String>[];
    final matches = touched.any((file) => allowed.any(file.contains));
    if (!matches) {
      fail(
        'Diff for "$publishedBranch" touched none of the allow-list paths for $bug.\nAllow-list: $allowed\nTouched: $touched',
      );
    }
  }
}

Map<String, dynamic> forcedReviewRemediationOutputs({
  required String stepId,
  required Map<String, dynamic> outputs,
  required Set<String> targetReviews,
  required String remediationPlan,
  required String implementationSummary,
}) {
  final reviewConfig = switch (stepId) {
    'plan-review' when targetReviews.contains('plan-review') => (
      findings: 'review_findings',
      count: 'findings_count',
      scopedCount: 'plan-review.findings_count',
      scopedGatingCount: 'plan-review.gating_findings_count',
    ),
    'architecture-review' when targetReviews.contains('architecture-review') => (
      findings: 'architecture-review.review_findings',
      count: 'findings_count',
      scopedCount: 'architecture-review.findings_count',
      scopedGatingCount: 'architecture-review.gating_findings_count',
    ),
    _ => null,
  };
  if (reviewConfig == null) return outputs;

  final findingsValue = outputs[reviewConfig.count];
  final findingsCount = switch (findingsValue) {
    final int numeric => numeric,
    _ => int.tryParse('$findingsValue') ?? 0,
  };
  if (findingsCount > 0) return outputs;

  return {
    ...outputs,
    'implementation_summary': (outputs['implementation_summary'] as String?)?.trim().isNotEmpty == true
        ? outputs['implementation_summary']
        : implementationSummary,
    'remediation_plan': remediationPlan,
    reviewConfig.count: 1,
    reviewConfig.scopedCount: 1,
    reviewConfig.scopedGatingCount: 1,
  };
}

Future<bool> _runOk(WorkflowE2eProcessRunner runProcess, String executable, List<String> arguments) async {
  try {
    final result = await runProcess(executable, arguments);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<bool> _canReadFixtureRepo(WorkflowE2eProcessRunner runProcess) async {
  try {
    final result = await runProcess(
      'git',
      ['ls-remote', '--exit-code', _todoAppFixtureReadOnlyUrl, 'HEAD'],
      environment: const {'GIT_TERMINAL_PROMPT': '0'},
    );
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

Future<bool> _runGitHubSshAuthenticated(WorkflowE2eProcessRunner runProcess) async {
  try {
    final result = await runProcess('ssh', [
      '-o',
      'BatchMode=yes',
      '-o',
      'ConnectTimeout=10',
      '-o',
      'StrictHostKeyChecking=accept-new',
      '-T',
      'git@github.com',
    ]);
    final output = '${result.stdout}\n${result.stderr}';
    return output.contains("You've successfully authenticated");
  } catch (_) {
    return false;
  }
}

bool _hasGitHubTokenEnv(Map<String, String> environment) {
  final token = environment['GITHUB_TOKEN']?.trim();
  return token != null && token.isNotEmpty;
}

final class WorkflowE2ePrerequisiteResult {
  final String? skipReason;
  final bool canCreateGitHubPr;

  const WorkflowE2ePrerequisiteResult.run({required this.canCreateGitHubPr}) : skipReason = null;

  const WorkflowE2ePrerequisiteResult.skip(this.skipReason) : canCreateGitHubPr = false;

  bool get shouldSkip => skipReason != null;
}

class WorkflowStepTrace {
  final String runId;
  final String stepKey;
  final int occurrence;
  final String taskId;
  final String title;
  final String description;
  final TaskStatus terminalStatus;
  final int tokenCount;
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
  final Map<String, dynamic> _isolationDiagnostics;
  final List<WorkflowStepTrace> traces = [];
  final List<String> stepOrder = [];
  final Map<String, List<String>> descriptionsByStep = {};
  final Map<String, int> _occurrenceByStep = {};
  var _artifactSequence = 0;

  late final StreamSubscription<TaskStatusChangedEvent> _queuedSub;
  late final StreamSubscription<WorkflowStepCompletedEvent> _completedSub;
  late final StreamSubscription<TaskEventCreatedEvent> _taskEventSub;

  final _pending = <String, WorkflowStepTrace>{};

  final Map<String, List<Map<String, dynamic>>> _taskEventsByTaskId = {};

  WorkflowExecutionRecorder(
    this._eventBus,
    this._taskService,
    this._messageService,
    this._workflowService,
    this._kvService,
    this._definition, {
    required Directory artifactDir,
    required ContextExtractor contextExtractor,
    Map<String, dynamic> isolationDiagnostics = const {},
  }) : _artifactDir = artifactDir,
       _isolationDiagnostics = isolationDiagnostics,
       _contextExtractor = contextExtractor,
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
      final step = _definitionStepForIndex(task.stepIndex!);
      final stepKey = step?.id ?? task.workflowStepExecution?.stepId ?? 'synthetic-step-${task.stepIndex}';
      if (step == null) {
        _log.info(
          'Recording auxiliary workflow task ${task.id} with synthetic step "$stepKey" '
          '(stepIndex=${task.stepIndex}, definition steps=${_definition.steps.length})',
        );
      }
      final occurrence = (_occurrenceByStep[stepKey] ?? 0) + 1;
      _occurrenceByStep[stepKey] = occurrence;
      final run = await _workflowService.get(task.workflowRunId!);
      final contextData = _contextData(run?.contextJson);
      final inputs = step == null
          ? <String, dynamic>{}
          : <String, dynamic>{for (final key in step.inputs) key: contextData[key]};

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
      String? outputsExtractError;
      final step = _definitionStepForIndex(event.stepIndex);
      if (step == null) {
        _log.info(
          'Skipping structured output extraction for auxiliary workflow step ${event.stepId} '
          '(stepIndex=${event.stepIndex}, definition steps=${_definition.steps.length})',
        );
      } else {
        try {
          outputs = await _contextExtractor.extract(step, task);
        } catch (error, st) {
          outputsExtractError = '$error';
          _log.warning('Failed to extract context outputs for ${event.stepId}', error, st);
        }
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
        outputsExtractError: outputsExtractError,
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
          configJson: Map<String, dynamic>.from(task.configJson),
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

  WorkflowStep? _definitionStepForIndex(int stepIndex) {
    if (stepIndex < 0 || stepIndex >= _definition.steps.length) return null;
    return _definition.steps[stepIndex];
  }

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
    required String? outputsExtractError,
    required Map<String, dynamic> stepScopedContext,
    required String? lastUserMessage,
    required String? lastAssistantMessage,
    required List<Map<String, dynamic>> persistedMessages,
    required List<Map<String, dynamic>> taskEvents,
  }) async {
    _artifactDir.createSync(recursive: true);
    final sequence = ++_artifactSequence;
    final fileName =
        '${sequence.toString().padLeft(2, '0')}-'
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
      'outputsExtractError': outputsExtractError,
      'stepScopedContext': stepScopedContext,
      'lastUserMessage': lastUserMessage,
      'lastAssistantMessage': lastAssistantMessage,
      'messages': persistedMessages,
      'taskEvents': taskEvents,
      'isolation': _isolationDiagnostics,
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

ContextExtractor productionLikeContextExtractor(CliWorkflowWiring wiring, DartclawConfig config) {
  return ContextExtractor(
    taskService: wiring.taskService,
    messageService: wiring.messageService,
    dataDir: config.server.dataDir,
    workflowStepExecutionRepository: SqliteWorkflowStepExecutionRepository(wiring.taskDb),
    workflowGitPort: WorkflowGitPortProcess(worktreeManager: wiring.worktreeManager),
  );
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

Directory createPreservedArtifactDir(String testName) {
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
    final payload = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final evidence = <String, Object?>{
      'lastAssistantMessage': payload['lastAssistantMessage'],
      'outputs': payload['outputs'],
      'stepOutcomeReason': payload['stepOutcomeReason'],
      'stepScopedContext': payload['stepScopedContext'],
      'assistantMessages': (payload['messages'] as List? ?? const [])
          .whereType<Map<dynamic, dynamic>>()
          .where((message) => message['role'] == 'assistant')
          .map((message) => message['content'])
          .toList(growable: false),
    };
    for (final marker in banned) {
      if (_jsonContainsString(evidence, marker)) {
        offenders.add('${p.basename(file.path)} contains "$marker"');
      }
    }
  }
  expect(offenders, isEmpty, reason: offenders.join('\n'));
}

bool _jsonContainsString(Object? value, String needle) {
  if (value is String) return value.contains(needle);
  if (value is Iterable) return value.any((item) => _jsonContainsString(item, needle));
  if (value is Map) return value.values.any((item) => _jsonContainsString(item, needle));
  return false;
}

void expectIsolationDiagnostics(Directory artifactDir, E2EFixtureInstance fixture) {
  final payloads = artifactDir
      .listSync()
      .whereType<File>()
      .where((file) => file.path.endsWith('.json'))
      .map((file) => jsonDecode(file.readAsStringSync()) as Map<String, dynamic>)
      .toList(growable: false);
  expect(payloads, isNotEmpty, reason: 'Expected step artifacts with isolation diagnostics.');
  for (final payload in payloads) {
    final isolation = (payload['isolation'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    expect(isolation['runtimeCwd'], fixture.runtimeCwd);
    expect(isolation['projectDir'], fixture.projectDir);
    expect(isolation['workflowWorkspaceDir'], fixture.workflowWorkspaceDir);
    expect(p.isWithin(fixture.dataDir, isolation['runtimeCwd'] as String), isTrue);
    expect(p.isWithin(fixture.projectDir, isolation['runtimeCwd'] as String), isFalse);
  }
}

void expectStepArtifactOutputs(Directory artifactDir, String stepKey, Set<String> requiredKeys) {
  final payloads = artifactDir
      .listSync()
      .whereType<File>()
      .where((file) => file.path.endsWith('.json'))
      .map((file) => jsonDecode(file.readAsStringSync()) as Map<String, dynamic>)
      .where((payload) => payload['stepKey'] == stepKey)
      .toList(growable: false);
  expect(payloads, isNotEmpty, reason: 'Expected preserved artifact for step "$stepKey".');
  for (final payload in payloads) {
    final extractError = payload['outputsExtractError'];
    expect(extractError, isNull, reason: 'Step "$stepKey" extractor failed before output assertion: $extractError');
    final outputs = (payload['outputs'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{};
    for (final key in requiredKeys) {
      expect(outputs, contains(key), reason: 'Step "$stepKey" artifact should include output "$key".');
      final value = outputs[key];
      if (key.endsWith('_findings')) {
        expect(
          value?.toString().trim(),
          allOf(isNotEmpty, endsWith('.md')),
          reason: 'Step "$stepKey" output "$key" should be a durable markdown report path.',
        );
      }
    }
  }
}

Map<String, dynamic> isolationDiagnosticsFor(E2EFixtureInstance fixture) => {
  'runtimeCwd': fixture.runtimeCwd,
  'projectDir': fixture.projectDir,
  'workflowWorkspaceDir': fixture.workflowWorkspaceDir,
};

void expectCommittedPlanArtifacts({required String projectDir, required Directory artifactDir, required String ref}) {
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
    final result = Process.runSync('git', ['cat-file', '-e', '$ref:$relativePath'], workingDirectory: projectDir);
    if (result.exitCode != 0) {
      missing.add(relativePath);
    }
  }
  expect(missing, isEmpty, reason: 'Expected committed plan artifacts at $ref: $missing');
}

void expectPublishSuccess(Map<String, dynamic> contextJson) {
  final contextData = (contextJson['data'] as Map?)?.cast<String, dynamic>() ?? contextJson;
  expect(
    contextData['publish.status'],
    'success',
    reason: 'Workflow publish should have status "success", got "${contextData['publish.status']}"',
  );
}

void expectPublishFailureNotSilent(dynamic completedRun, WorkflowRunStatus finalStatus) {
  if (finalStatus != WorkflowRunStatus.failed) return;
  final contextJson = completedRun?.contextJson as Map<String, dynamic>? ?? const {};
  final data = (contextJson['data'] as Map?)?.cast<String, dynamic>() ?? contextJson;
  final publishStatus = data['publish.status'] as String?;
  final publishError = data['publish.error'] as String?;
  if (publishStatus == 'failed' || (publishError != null && publishError.isNotEmpty)) {
    fail('Workflow terminated in failed state during publish: ${publishError ?? '(no error detail)'}');
  }
}

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
