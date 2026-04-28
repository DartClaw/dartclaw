@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_cli/src/commands/workflow/cli_workflow_wiring.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show ProviderValidator;
import 'package:dartclaw_core/dartclaw_core.dart' show Task, WorkflowStepCompletedEvent;
import 'package:dartclaw_models/dartclaw_models.dart'
    show
        MergeResolveConfig,
        OutputConfig,
        OutputFormat,
        WorkflowDefinition,
        WorkflowGitPublishStrategy,
        WorkflowGitStrategy,
        WorkflowGitWorktreeStrategy,
        WorkflowStep,
        WorkflowVariable;
import 'package:dartclaw_server/dartclaw_server.dart' show LogService;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        EventBus,
        MergeResolveAttemptArtifact,
        TaskStatusChangedEvent,
        WorkflowContext,
        WorkflowRunStatus,
        WorkflowRunStatusChangedEvent;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../fixtures/e2e_fixture.dart';

/// Real-harness merge-resolve proof for the two-story STATE.md conflict.
///
/// Canonical harness: Codex, because the existing workflow E2E suite already
/// uses the Codex real-harness path and this story needs one stable proof, not
/// a cross-harness matrix.
///
/// Gating preconditions: `codex --version` succeeds and provider auth is
/// available through Codex OAuth/auth-file state, `CODEX_API_KEY`, or
/// `OPENAI_API_KEY`. When the package-level `dart_test.yaml` marks integration
/// tests skipped, run locally with:
///
///     dart test --run-skipped packages/dartclaw_workflow/test/workflow/merge_resolve_integration_test.dart -t integration
///
/// The FIS shorthand invocation is:
///
///     dart test packages/dartclaw_workflow/test/workflow/merge_resolve_integration_test.dart -t integration
///
/// Flake budget: one retry per CI/manual run; flake = bug. The only recognized
/// transient signals are upstream 5xx/rate-limit/network transport failures
/// surfaced by the harness. Auth failures, workflow failures, assertion
/// failures, and merge-resolve failures are not retried.
///
const _projectId = 'merge-resolve-e2e-project';
const _statePath = 'docs/STATE.md';
const _storyOneMarker = '- S01: e2e marker';
const _storyTwoMarker = '- S02: e2e marker';
const _testTimeout = Duration(minutes: 25);

Future<bool> _codexAvailable() async {
  try {
    final result = await Process.run('codex', ['--version']);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

bool _hasEnv(String name) => Platform.environment[name]?.trim().isNotEmpty == true;

Future<bool> _codexAuthAvailable() async {
  if (_hasEnv('CODEX_API_KEY') || _hasEnv('OPENAI_API_KEY')) {
    return true;
  }
  return ProviderValidator.probeAuthStatus('codex', providerId: 'codex');
}

Future<String?> _codexGateSkipReason() async {
  final hasBinary = await _codexAvailable();
  if (!hasBinary) {
    return 'S65 merge-resolve integration skipped: codex binary is not on PATH.';
  }
  final hasAuth = await _codexAuthAvailable();
  if (!hasAuth) {
    return 'S65 merge-resolve integration skipped: Codex provider auth unavailable '
        '(checked ~/.codex/auth.json, CODEX_API_KEY, and OPENAI_API_KEY).';
  }
  return null;
}

WorkflowDefinition _mergeResolveIntegrationDefinition() {
  return WorkflowDefinition(
    name: 'merge-resolve-integration-e2e',
    description: 'Real-harness merge-resolve integration proof',
    variables: const {
      'PROJECT': WorkflowVariable(description: 'Project id for the local fixture project.'),
      'BRANCH': WorkflowVariable(required: false, description: 'Base branch for workflow git.', defaultValue: 'main'),
    },
    project: '{{PROJECT}}',
    gitStrategy: const WorkflowGitStrategy(
      bootstrap: true,
      worktree: WorkflowGitWorktreeStrategy(mode: 'per-map-item'),
      promotion: 'merge',
      publish: WorkflowGitPublishStrategy(enabled: false),
      mergeResolve: MergeResolveConfig(enabled: true, maxAttempts: 2, tokenCeiling: 100000),
    ),
    steps: const [
      WorkflowStep(
        id: 'seed-stories',
        name: 'Seed stories',
        type: 'bash',
        prompts: ['printf \'%s\\n\' \'[{"id":"S01"},{"id":"S02"}]\''],
        outputs: {'stories': OutputConfig(format: OutputFormat.json)},
      ),
      WorkflowStep(
        id: 'story-foreach',
        name: 'Story foreach',
        type: 'foreach',
        mapOver: 'stories',
        mapAlias: 'story',
        maxParallel: 2,
        foreachSteps: ['apply-story'],
      ),
      WorkflowStep(
        id: 'apply-story',
        name: 'Apply story',
        type: 'coding',
        typeAuthored: true,
        provider: 'codex',
        project: '{{PROJECT}}',
        prompts: [
          'In the current task worktree, edit docs/STATE.md only. '
              'Append exactly this line as the final line: '
              '- {{story.item.id}}: e2e marker\n'
              'Save the file. Do not edit any other file. '
              'Return a concise completion note.',
        ],
      ),
    ],
  );
}

Future<void> _setupLocalProject(String projectDir) async {
  final root = Directory(projectDir)..createSync(recursive: true);
  await _runGit(root.path, ['init', '-b', 'main']);
  await _runGit(root.path, ['config', 'user.name', 'DartClaw E2E']);
  await _runGit(root.path, ['config', 'user.email', 'e2e@example.invalid']);
  final stateFile = File(p.join(root.path, _statePath));
  stateFile.parent.createSync(recursive: true);
  stateFile.writeAsStringSync('# State\n\n- phase: in-progress\n');
  await _runGit(root.path, ['add', _statePath]);
  await _runGit(root.path, ['commit', '-m', 'Seed state']);
}

Future<ProcessResult> _runGit(String projectDir, List<String> args) async {
  final result = await Process.run('git', args, workingDirectory: projectDir);
  if (result.exitCode != 0) {
    fail('git ${args.join(' ')} failed in $projectDir\nstdout: ${result.stdout}\nstderr: ${result.stderr}');
  }
  return result;
}

Future<WorkflowRunStatus> _awaitWorkflowCompletion(EventBus eventBus, String runId) {
  final completer = Completer<WorkflowRunStatus>();
  late final StreamSubscription<WorkflowRunStatusChangedEvent> sub;
  sub = eventBus.on<WorkflowRunStatusChangedEvent>().listen((event) {
    if (event.runId != runId) return;
    if (event.newStatus.terminal || event.newStatus == WorkflowRunStatus.paused) {
      if (!completer.isCompleted) {
        completer.complete(event.newStatus);
      }
      unawaited(sub.cancel());
    }
  });
  completer.future.whenComplete(() => unawaited(sub.cancel()));
  return completer.future;
}

Directory _createPreservedArtifactDir(String testName) {
  final configuredRoot = Platform.environment['DARTCLAW_E2E_LOG_DIR']?.trim();
  final root = configuredRoot != null && configuredRoot.isNotEmpty
      ? Directory(configuredRoot)
      : Directory(p.join(Directory.current.path, '.dart_tool', 'dartclaw_e2e_logs'));
  root.createSync(recursive: true);

  final runDir = Directory(p.join(root.path, '${DateTime.now().millisecondsSinceEpoch}-$testName'));
  runDir.createSync(recursive: true);
  return runDir;
}

bool _isRecognizedTransient(Object error) {
  final text = error.toString().toLowerCase();
  return text.contains(' 429 ') ||
      text.contains('rate limit') ||
      text.contains('too many requests') ||
      text.contains(' 5xx ') ||
      text.contains(' 500 ') ||
      text.contains(' 502 ') ||
      text.contains(' 503 ') ||
      text.contains(' 504 ') ||
      text.contains('connection reset') ||
      text.contains('connection closed') ||
      text.contains('network is unreachable') ||
      text.contains('temporarily unavailable') ||
      text.contains('timed out receiving response');
}

Future<_RunEvidence> _runAndAssertOnce({required int attempt}) async {
  final definition = _mergeResolveIntegrationDefinition();
  _assertDefinitionContract(definition);

  final artifactDir = _createPreservedArtifactDir('merge-resolve-integration-e2e-attempt-$attempt');
  final log = Logger('E2E.Diagnostics');
  final fixture = await E2EFixture()
      .withProject(_projectId, localPath: true, credentials: null, branch: 'main')
      .withProjectSetup(_setupLocalProject)
      .withPoolSize(3)
      .withLoggingLevel('FINE')
      .build();

  CliWorkflowWiring? wiring;
  final diagnosticSubs = <StreamSubscription<Object>>[];
  String? runId;
  var lastStepId = '<none>';
  try {
    wiring = await _wireUp(fixture);
    diagnosticSubs.add(
      wiring.eventBus.on<WorkflowStepCompletedEvent>().listen((event) {
        lastStepId = event.stepId;
        log.info(
          'Step completed: ${event.stepId} '
          '${event.success ? "OK" : "FAILED"} (${event.tokenCount} tokens, task=${event.taskId})',
        );
      }),
    );
    diagnosticSubs.add(
      wiring.eventBus.on<TaskStatusChangedEvent>().listen((event) {
        log.info('Task ${event.taskId}: ${event.oldStatus} -> ${event.newStatus}');
      }),
    );

    final run = await wiring.workflowService.start(
      definition,
      const {'PROJECT': _projectId, 'BRANCH': 'main'},
      projectId: _projectId,
      headless: true,
    );
    runId = run.id;
    final completionFuture = _awaitWorkflowCompletion(wiring.eventBus, run.id);

    final terminalStatus = await completionFuture.timeout(
      _testTimeout,
      onTimeout: () async {
        await wiring?.workflowService.cancel(run.id);
        fail(
          'Workflow timed out after ${_testTimeout.inMinutes} minutes; '
          'runId=${run.id}; last step ID=$lastStepId; preserved artifacts=${artifactDir.path}',
        );
      },
    );

    final refreshedRun = await wiring.workflowService.get(run.id);
    if (terminalStatus != WorkflowRunStatus.completed) {
      final failureDetails = await _workflowFailureDetails(wiring, run.id, refreshedRun?.errorMessage);
      throw _RunFailure('workflow terminal status was $terminalStatus; $failureDetails', original: failureDetails);
    }
    expect(terminalStatus, equals(WorkflowRunStatus.completed));

    final context = WorkflowContext.fromJson(refreshedRun!.contextJson);
    final integrationBranch = (context.data['_workflow.git.integration_branch'] as String?)?.trim();
    expect(integrationBranch, isNotNull, reason: 'workflow git bootstrap should record integration branch');
    expect(integrationBranch, isNotEmpty, reason: 'workflow git integration branch must be non-empty');

    final showResult = await Process.run('git', [
      'show',
      '$integrationBranch:$_statePath',
    ], workingDirectory: fixture.projectDir);
    expect(showResult.exitCode, equals(0), reason: 'git show failed: ${showResult.stderr}');
    final stateMdContent = showResult.stdout as String;
    expect(stateMdContent, contains(_storyOneMarker));
    expect(stateMdContent, contains(_storyTwoMarker));

    final tasks = (await wiring.taskService.list()).where((task) => task.workflowRunId == run.id).toList();
    final mergeResolveTask = _singleMergeResolveTask(tasks);
    final conflictIndex = mergeResolveTask.workflowStepExecution?.mapIterationIndex;
    expect(conflictIndex, isNotNull, reason: 'merge-resolve task must carry the conflicted iteration index');
    final storyTask = _storyTaskForIteration(tasks, conflictIndex!);
    expect(
      mergeResolveTask.workflowStepExecution?.mapIterationIndex,
      equals(storyTask.workflowStepExecution?.mapIterationIndex),
      reason: 'S65: real-harness binding chain must match the C1 component-tier regression',
    );
    expect(mergeResolveTask.worktreeJson?['path'], equals(storyTask.worktreeJson?['path']));

    final artifacts = await _readMergeResolveArtifacts(wiring, storyTask);
    final resolvedArtifacts = artifacts
        .where((artifact) => artifact.value.outcome == 'resolved')
        .toList(growable: false);
    expect(resolvedArtifacts, isNotEmpty, reason: 'BPC-27: at least one attempt must have outcome=resolved');
    for (final artifact in artifacts) {
      _assertArtifactFields(artifact, conflictedIterationIndex: conflictIndex);
    }

    return _RunEvidence(
      runId: run.id,
      lastStepId: lastStepId,
      preservedArtifactsDir: artifactDir,
      terminalStatus: terminalStatus,
    );
  } catch (error) {
    Error.throwWithStackTrace(
      _RunFailure(
        'merge-resolve integration attempt $attempt failed; '
        'runId=${runId ?? "<not-started>"}; last step ID=$lastStepId; preserved artifacts=${artifactDir.path}; '
        'error=$error',
        original: error,
      ),
      StackTrace.current,
    );
  } finally {
    for (final sub in diagnosticSubs) {
      await sub.cancel();
    }
    if (wiring != null) {
      await wiring.dispose();
    }
    await fixture.dispose();
  }
}

Future<CliWorkflowWiring> _wireUp(E2EFixtureInstance fixture) async {
  final wiring = CliWorkflowWiring(
    config: fixture.config,
    dataDir: fixture.config.server.dataDir,
    searchDbFactory: (_) => sqlite3.openInMemory(),
    taskDbFactory: (_) => sqlite3.openInMemory(),
  );
  await wiring.wire();
  return wiring;
}

Future<String> _workflowFailureDetails(CliWorkflowWiring wiring, String runId, String? runError) async {
  final tasks = (await wiring.taskService.list()).where((task) => task.workflowRunId == runId).toList();
  final failedTasks = tasks
      .where((task) => task.status.name == 'failed')
      .map((task) {
        final stepId = task.workflowStepExecution?.stepId ?? '<no-step>';
        final errorSummary = task.configJson['errorSummary'] ?? task.configJson['lastError'];
        return [
          '${task.id}[$stepId] ${task.title} status=${task.status.name}',
          if (errorSummary is String && errorSummary.trim().isNotEmpty) 'errorSummary=$errorSummary',
        ].join(' ');
      })
      .join('; ');
  return [
    if (runError != null && runError.trim().isNotEmpty) 'runError=$runError',
    if (failedTasks.isNotEmpty) 'failedTasks=$failedTasks',
  ].join(' ');
}

void _assertDefinitionContract(WorkflowDefinition definition) {
  expect(definition.gitStrategy?.mergeResolve.enabled, isTrue);
  final seed = definition.steps.firstWhere((step) => step.id == 'seed-stories');
  final foreach = definition.steps.firstWhere((step) => step.id == 'story-foreach');
  expect(seed.type, equals('bash'));
  expect(seed.outputKeys, contains('stories'));
  expect(foreach.type, equals('foreach'));
  expect(foreach.mapOver, equals('stories'));
  expect(foreach.mapAlias, equals('story'));
}

Task _singleMergeResolveTask(List<Task> tasks) {
  final matches = tasks.where((task) => task.configJson.containsKey('_workflowMergeResolveEnv')).toList();
  expect(matches, hasLength(1), reason: 'Exactly one merge-resolve task should be dispatched for the conflict.');
  return matches.single;
}

Task _storyTaskForIteration(List<Task> tasks, int iterationIndex) {
  final matches = tasks
      .where(
        (task) =>
            task.workflowStepExecution?.stepId == 'apply-story' &&
            task.workflowStepExecution?.mapIterationIndex == iterationIndex,
      )
      .toList();
  expect(matches, hasLength(1), reason: 'Expected one story task for conflicted iteration $iterationIndex.');
  return matches.single;
}

Future<List<_ArtifactEvidence>> _readMergeResolveArtifacts(CliWorkflowWiring wiring, Task storyTask) async {
  final records = await wiring.taskService.listArtifacts(storyTask.id);
  final artifacts = <_ArtifactEvidence>[];
  for (final record in records.where((artifact) => artifact.name.startsWith('merge_resolve_iter_'))) {
    final file = File(record.path);
    expect(file.existsSync(), isTrue, reason: 'Merge-resolve artifact file should exist: ${record.path}');
    final decoded = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    artifacts.add(_ArtifactEvidence(raw: decoded, value: MergeResolveAttemptArtifact.fromJson(decoded)));
  }
  artifacts.sort((a, b) => a.value.attemptNumber.compareTo(b.value.attemptNumber));
  return artifacts;
}

void _assertArtifactFields(_ArtifactEvidence evidence, {required int conflictedIterationIndex}) {
  final raw = evidence.raw;
  final artifact = evidence.value;
  const requiredKeys = {
    'iteration_index',
    'story_id',
    'attempt_number',
    'outcome',
    'conflicted_files',
    'resolution_summary',
    'error_message',
    'agent_session_id',
    'tokens_used',
  };
  expect(raw.keys.toSet(), containsAll(requiredKeys), reason: 'artifact raw JSON must include all PRD-required keys');
  expect(raw['iteration_index'], equals(conflictedIterationIndex), reason: 'iteration_index must match conflict');
  expect(raw['story_id'], isA<String>().having((value) => value.trim(), 'trimmed', isNotEmpty));
  expect(raw['attempt_number'], isA<int>().having((value) => value, 'value', greaterThan(0)));
  expect(raw['outcome'], isIn(const ['resolved', 'failed', 'cancelled']), reason: 'outcome must be a valid enum value');
  expect(raw['conflicted_files'], isA<List<dynamic>>(), reason: 'conflicted_files must be a JSON list');
  expect(artifact.conflictedFiles, contains(_statePath), reason: 'conflicted_files must name the STATE.md conflict');
  expect(raw['resolution_summary'], isA<String>().having((value) => value.trim(), 'trimmed', isNotEmpty));
  expect(raw['agent_session_id'], isA<String>().having((value) => value.trim(), 'trimmed', isNotEmpty));
  expect(raw['tokens_used'], isA<int>().having((value) => value, 'value', greaterThanOrEqualTo(0)));
  if (raw.containsKey('started_at')) {
    expect(artifact.startedAt, isNotNull, reason: 'started_at must parse when written');
  }
  if (raw.containsKey('elapsed_ms')) {
    expect(artifact.elapsedMs, greaterThanOrEqualTo(0), reason: 'elapsed_ms must be non-negative when written');
  }
}

final class _ArtifactEvidence {
  final Map<String, dynamic> raw;
  final MergeResolveAttemptArtifact value;

  const _ArtifactEvidence({required this.raw, required this.value});
}

final class _RunEvidence {
  final String runId;
  final String lastStepId;
  final Directory preservedArtifactsDir;
  final WorkflowRunStatus terminalStatus;

  const _RunEvidence({
    required this.runId,
    required this.lastStepId,
    required this.preservedArtifactsDir,
    required this.terminalStatus,
  });
}

final class _RunFailure implements Exception {
  final String message;
  final Object original;

  const _RunFailure(this.message, {required this.original});

  @override
  String toString() => message;
}

void main() {
  LogService? logService;

  setUpAll(() {
    logService = LogService.fromConfig(level: 'FINE');
    logService!.install();
  });

  tearDownAll(() async {
    await logService?.dispose();
  });

  test('real Codex harness resolves a workflow STATE.md promotion conflict', () async {
    final skipReason = await _codexGateSkipReason();
    if (skipReason != null) {
      markTestSkipped(skipReason);
      return;
    }

    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        final evidence = await _runAndAssertOnce(attempt: attempt);
        Logger('E2E.Diagnostics').info(
          'Merge-resolve integration passed: runId=${evidence.runId}; '
          'last step ID=${evidence.lastStepId}; status=${evidence.terminalStatus}; '
          'preserved artifacts=${evidence.preservedArtifactsDir.path}',
        );
        return;
      } on _RunFailure catch (error) {
        if (attempt == 1 && _isRecognizedTransient(error.original)) {
          Logger('E2E.Diagnostics').warning('WARNING: known-flake retry attempted: ${error.original}');
          continue;
        }
        fail(error.message);
      }
    }
  }, timeout: Timeout(_testTimeout));
}
