@Tags(['integration'])
library;

// Live step/declared-output canary, pinned to Claude.
//
// Each step runs through the production `WorkflowOneShotRunner` over a real
// `ClaudeCodeHarness`, so the provider enforces the execution-envelope schema
// (`--json-schema`) and the runner owns validation, marker stamping and
// persistence. Codex is not interchangeable here: the app-server harness
// reports `supportsStructuredOutput == false`, so `TaskExecutor` refuses a
// schema-bearing step on it before dispatch (ADR-031, amendment 2026-08-22).
// The sibling `step_artifacts_env_live_canary_test.dart` stays on Codex — it
// proves spawn-environment export, which needs no schema.
//
// Posture is `permissionMode: bypassPermissions`, so this suite is not guard
// evidence.

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        HarnessFactory,
        HarnessFactoryConfig,
        SqliteAgentExecutionRepository,
        SqliteTaskRepository,
        SqliteWorkflowStepExecutionRepository,
        TurnOutcome,
        TurnStatus;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show BehaviorFileService, TaskService, TurnRunner;
import 'package:dartclaw_runtime/src/task/task_budget_policy.dart' show TaskBudgetPolicy;
import 'package:dartclaw_runtime/src/task/workflow_one_shot_runner.dart' show WorkflowOneShotRunner;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        ContextExtractor,
        MapContext,
        MessageService,
        PromptAugmenter,
        SessionService,
        SkillPromptBuilder,
        WorkflowDefinition,
        WorkflowDefinitionParser,
        WorkflowContext,
        WorkflowStep;
import 'package:dartclaw_workflow/src/workflow/execution_envelope_schema.dart' show buildExecutionEnvelopeSchema;
import 'package:dartclaw_workflow/src/workflow/workflow_run_paths.dart'
    show stepArtifactsDirEnvVar, workflowStepArtifactsDir;
import 'package:dartclaw_workflow/src/workflow/workflow_template_engine.dart' show WorkflowTemplateEngine;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../fixtures/e2e_fixture.dart';
import '_support/workflow_test_paths.dart';

String _stepIsolationFixtureTemplateDir(String fixturesRoot) => p.join(fixturesRoot, 'workflow-step-isolation');

const _defaultLiveStepTimeout = Duration(minutes: 8);
const _defaultLiveTestTimeout = Timeout(Duration(minutes: 10));

WorkflowStep _stepById(WorkflowDefinition definition, String stepId) =>
    definition.steps.firstWhere((step) => step.id == stepId);

List<dynamic> _normalizeStoryList(Object? raw) {
  return switch (raw) {
    final List<dynamic> list => list,
    final Map<dynamic, dynamic> map when map['items'] is List<dynamic> => map['items'] as List<dynamic>,
    _ => throw StateError('Expected story list, got ${raw.runtimeType}: $raw'),
  };
}

void expectStorySpecShape(Object? raw) {
  // Matches the `story_specs` preset schema: items require id, title,
  // spec_path, dependencies. (FIS body content lives on disk at spec_path
  // rather than being carried inline.)
  expect(raw, isA<Map<Object?, Object?>>());
  final storySpec = raw! as Map<Object?, Object?>;
  expect(storySpec['id'], isA<String>());
  expect((storySpec['id'] as String).trim(), isNotEmpty);
  expect(storySpec['title'], isA<String>());
  expect((storySpec['title'] as String).trim(), isNotEmpty);
  expect(storySpec['spec_path'], isA<String>());
  expect((storySpec['spec_path'] as String).trim(), isNotEmpty);
  expect(storySpec['dependencies'], isA<List<Object?>>());
}

void _writeMarkdownNote(String rootDir, String relativePath, String heading, String bullet) {
  final file = File(p.join(rootDir, relativePath));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync('# $heading\n- $bullet\n');
}

String _sanitizeFileComponent(String value) => value.replaceAll(RegExp(r'[^a-zA-Z0-9._-]+'), '_');

String _canonicalExistingDirectoryPath(String path) {
  try {
    return Directory(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return p.normalize(path);
  }
}

String _canonicalExistingEntityPath(String path) {
  try {
    if (File(path).existsSync()) return File(path).resolveSymbolicLinksSync();
    if (Directory(path).existsSync()) return Directory(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    // Fall through to a lexical normalization when the path is only a claim.
  }
  return p.normalize(path);
}

Directory _createPreservedArtifactDir(String testName) {
  final configuredRoot = Platform.environment['DARTCLAW_STEP_LOG_DIR']?.trim();
  final root = configuredRoot != null && configuredRoot.isNotEmpty
      ? Directory(configuredRoot)
      : Directory(p.join(Directory.current.path, '.dart_tool', 'dartclaw_step_logs'));
  root.createSync(recursive: true);

  final runDir = Directory(
    p.join(root.path, '${DateTime.now().millisecondsSinceEpoch}-${_sanitizeFileComponent(testName)}'),
  );
  runDir.createSync(recursive: true);
  return runDir;
}

String _requireRelativeExistingMarkdownPath(
  Object? value, {
  required String rootDir,
  required String artifactPath,
  required String label,
}) {
  return _requireRelativeExistingPath(
    value,
    rootDir: rootDir,
    artifactPath: artifactPath,
    label: label,
    allowedExtensions: const {'.md'},
  );
}

String _requireRelativeExistingPlanPath(_StepExecutionResult result, String outputKey, {required String rootDir}) {
  return _requireRelativeExistingPath(
    result.outputs[outputKey],
    rootDir: rootDir,
    artifactPath: result.artifactPath,
    label: outputKey,
    allowedExtensions: const {'.json', '.md'},
  );
}

String _requireRelativeExistingPath(
  Object? value, {
  required String rootDir,
  required String artifactPath,
  required String label,
  required Set<String> allowedExtensions,
}) {
  expect(value, isA<String>(), reason: 'Expected $label to be a path string. Artifact: $artifactPath');
  final relativePath = (value as String).trim();
  expect(relativePath, isNotEmpty, reason: 'Expected $label to be non-empty. Artifact: $artifactPath');
  expect(
    p.isAbsolute(relativePath),
    isFalse,
    reason: 'Expected $label to be workspace-relative, got $relativePath. Artifact: $artifactPath',
  );
  expect(
    allowedExtensions,
    contains(p.extension(relativePath)),
    reason: 'Expected $label extension to be one of $allowedExtensions. Artifact: $artifactPath',
  );
  expect(
    File(p.join(rootDir, relativePath)).existsSync(),
    isTrue,
    reason: 'Expected $label file to exist at $relativePath. Artifact: $artifactPath',
  );
  return relativePath;
}

int _requireFindingsCount(_StepExecutionResult result, String outputKey) {
  final value = result.outputs[outputKey];
  final count = switch (value) {
    final int numeric => numeric,
    _ => int.tryParse('$value'),
  };
  expect(count, isNotNull, reason: 'Expected $outputKey to be parseable as int. Artifact: ${result.artifactPath}');
  return count!;
}

String _requireRelativeMarkdownArtifactPath(_StepExecutionResult result, String outputKey, {required String rootDir}) {
  return _requireRelativeExistingMarkdownPath(
    result.outputs[outputKey],
    rootDir: rootDir,
    artifactPath: result.artifactPath,
    label: outputKey,
  );
}

int _expectReviewReportPathOrCleanCounts(
  _StepExecutionResult result,
  String reportKey,
  String findingsCountKey, {
  required String rootDir,
  required String runtimeArtifactsDir,
}) {
  final findingsCount = _requireFindingsCount(result, findingsCountKey);
  final reportPath = (result.outputs[reportKey] as String?)?.trim() ?? '';
  expect(
    reportPath,
    isNotEmpty,
    reason: 'Expected $reportKey to be a durable report path. Artifact: ${result.artifactPath}',
  );
  if (p.isAbsolute(reportPath)) {
    final canonicalRuntimeArtifactsDir = _canonicalExistingDirectoryPath(runtimeArtifactsDir);
    final canonicalReportPath = _canonicalExistingEntityPath(reportPath);
    expect(
      canonicalReportPath == canonicalRuntimeArtifactsDir ||
          p.isWithin(canonicalRuntimeArtifactsDir, canonicalReportPath),
      isTrue,
      reason:
          'Expected absolute $reportKey to stay under workflow.runtime_artifacts_dir, got $reportPath. '
          'Artifact: ${result.artifactPath}',
    );
    expect(
      File(reportPath).existsSync(),
      isTrue,
      reason: 'Expected $reportKey file to exist. Artifact: ${result.artifactPath}',
    );
    return findingsCount;
  }
  _requireRelativeMarkdownArtifactPath(result, reportKey, rootDir: rootDir);
  return findingsCount;
}

void _expectGatingCountNotGreaterThanTotal(_StepExecutionResult result, String totalKey, String gatingKey) {
  final totalCount = _requireFindingsCount(result, totalKey);
  final gatingCount = _requireFindingsCount(result, gatingKey);
  expect(gatingCount, lessThanOrEqualTo(totalCount), reason: 'Artifact: ${result.artifactPath}');
}

class _StepExecutionResult {
  final String stepId;
  final String stepName;
  final String taskId;
  final String sessionId;
  final String prompt;
  final String assistantContent;
  final Map<String, dynamic> outputs;
  final String artifactPath;

  const new({
    required this.stepId,
    required this.stepName,
    required this.taskId,
    required this.sessionId,
    required this.prompt,
    required this.assistantContent,
    required this.outputs,
    required this.artifactPath,
  });
}

void main() {
  late final String fixturesRoot;
  late final String fixtureTemplateDir;
  late final WorkflowDefinition planDefinition;
  late final WorkflowDefinition specDefinition;
  late final bool claudeReady;
  late final Map<String, String> inheritedEnv;
  late final String executorModel;
  late final String permissionMode;
  late final Directory artifactDir;
  late Directory tempDir;
  late String fixtureDir;
  late String runtimeArtifactsDir;
  late TaskService taskService;
  late SqliteAgentExecutionRepository agentExecutions;
  late SqliteWorkflowStepExecutionRepository workflowStepExecutions;
  late SessionService sessionService;
  late MessageService messageService;
  late ContextExtractor extractor;
  late WorkflowOneShotRunner oneShotRunner;
  final templateEngine = WorkflowTemplateEngine();
  final skillPromptBuilder = SkillPromptBuilder(augmenter: const PromptAugmenter(), harnessFactory: HarnessFactory());
  var artifactCounter = 0;

  setUpAll(() async {
    // Each test re-checks and skips itself: `markTestSkipped` here marks only
    // the synthetic setUpAll entry and still runs every test body.
    claudeReady = await claudeAvailable();
    fixturesRoot = workflowFixturesRoot();
    fixtureTemplateDir = _stepIsolationFixtureTemplateDir(fixturesRoot);
    final parser = WorkflowDefinitionParser();
    planDefinition = await parser.parseFile(p.join(workflowDefinitionsDir(), 'plan-and-implement.yaml'));
    specDefinition = await parser.parseFile(p.join(workflowDefinitionsDir(), 'spec-and-implement.yaml'));

    // `SafeProcess.start` runs with `includeParentEnvironment: false`, so the
    // spawned `claude` binary only sees whatever environment the harness config
    // hands through. Propagate PATH + HOME explicitly so tests running outside
    // the server wiring can still locate the binary and its credential store.
    inheritedEnv = <String, String>{
      for (final key in const ['PATH', 'HOME', 'USER', 'LOGNAME', 'TMPDIR', 'LANG', 'LC_ALL', 'CLAUDE_CONFIG_DIR'])
        if (Platform.environment[key] != null) key: Platform.environment[key]!,
    };
    // Pinned to the Claude preset with an empty environment: this suite is the
    // structured-output proof, so it must not pick up a codex model from a
    // workflow-live run driving the sibling Codex canary.
    executorModel = E2EFixture(provider: 'claude', environment: const {}).executorModel;
    // `bypassPermissions` is the Claude analogue of the sibling canary's
    // `approval: never` full access, and these steps declare no allowedTools
    // policy for it to undercut.
    //
    // This used to claim the preset's `dontAsk` would auto-deny every tool call
    // and leave the step answering from an unread worktree. Measured 2026-08-28:
    // it does not — this suite passes unchanged under `dontAsk`, reading the
    // worktree and writing its report. Keep `bypassPermissions` for parity with
    // the Codex sibling, not out of that fear.
    permissionMode = 'bypassPermissions';
    artifactDir = _createPreservedArtifactDir('workflow-step-isolation');
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_workflow_step_isolation_');
    final sessionsDir = p.join(tempDir.path, 'sessions');
    Directory(sessionsDir).createSync(recursive: true);
    fixtureDir = p.join(tempDir.path, 'fixture');
    runtimeArtifactsDir = p.join(tempDir.path, 'workflows', 'runs', 'step-isolation', 'runtime-artifacts');
    Directory(runtimeArtifactsDir).createSync(recursive: true);
    Directory(p.join(runtimeArtifactsDir, 'reviews')).createSync(recursive: true);
    _copyDirectorySync(Directory(fixtureTemplateDir), Directory(fixtureDir));
    Process.runSync('git', ['init', '-q'], workingDirectory: fixtureDir);
    Process.runSync('git', ['config', 'user.name', 'Workflow Test'], workingDirectory: fixtureDir);
    Process.runSync('git', ['config', 'user.email', 'workflow-tests@example.com'], workingDirectory: fixtureDir);
    Process.runSync('git', ['add', '.'], workingDirectory: fixtureDir);
    Process.runSync('git', ['commit', '-qm', 'Initial fixture'], workingDirectory: fixtureDir);

    final database = sqlite3.openInMemory();
    taskService = TaskService(SqliteTaskRepository(database));
    agentExecutions = SqliteAgentExecutionRepository(database);
    workflowStepExecutions = SqliteWorkflowStepExecutionRepository(database);
    sessionService = SessionService(baseDir: sessionsDir);
    messageService = MessageService(baseDir: sessionsDir);
    extractor = ContextExtractor(
      taskService: taskService,
      messageService: messageService,
      dataDir: tempDir.path,
      workflowStepExecutionRepository: workflowStepExecutions,
    );
    oneShotRunner = WorkflowOneShotRunner(
      workflowStepExecutionRepository: workflowStepExecutions,
      messages: messageService,
      tasks: taskService,
      budgetPolicy: TaskBudgetPolicy(
        tasks: taskService,
        kv: null,
        budgetConfig: null,
        eventBus: null,
        dataDir: tempDir.path,
        failTask: (task, {required errorSummary, required kind, required retryable}) async =>
            fail('Unexpected budget failure for ${task.id}: $errorSummary'),
      ),
    );
  });

  tearDown(() async {
    await taskService.dispose();
    await messageService.dispose();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  Future<_StepExecutionResult> executeStep({
    required WorkflowStep step,
    required WorkflowContext context,
    MapContext? mapContext,
    String? artifactLabel,
    Duration stepTimeout = _defaultLiveStepTimeout,
  }) async {
    final stepContext = WorkflowContext(data: context.data, variables: context.variables);
    stepContext.mergeSystemVariables({
      ...context.systemVariables,
      'workflow.runtime_artifacts_dir': runtimeArtifactsDir,
    });
    final resolvedPrompt = mapContext == null
        ? templateEngine.resolve(step.prompt ?? '', stepContext)
        : templateEngine.resolveWithMap(step.prompt ?? '', stepContext, mapContext);

    final prompt = skillPromptBuilder.build(
      skill: step.skill,
      resolvedPrompt: resolvedPrompt,
      contextSummary: step.prompt == null && step.inputs.isNotEmpty
          ? SkillPromptBuilder.formatContextSummary(
              {for (final key in step.inputs) key: context[key] ?? ''},
              outputConfigs: SkillPromptBuilder.collectInputConfigs([
                ...planDefinition.steps,
                ...specDefinition.steps,
              ], step.inputs),
            )
          : null,
      outputs: step.outputs,
      outputKeys: step.outputKeys,
      provider: 'claude',
    );

    final session = await sessionService.createSession(type: SessionType.task);
    final task = await taskService.create(
      id: 'task-${DateTime.now().microsecondsSinceEpoch}',
      title: step.name,
      description: prompt,
      autoStart: true,
      workflowRunId: 'step-isolation',
    );
    // Attach the fixture directory as the task worktree so
    // ContextExtractor._resolveFileSystemOutput can locate artifacts written
    // by the skill (e.g. plan.md) against an actual filesystem root.
    await taskService.updateFields(task.id, sessionId: session.id, worktreeJson: {'path': fixtureDir});

    final stepArtifactsDir = workflowStepArtifactsDir(
      dataDir: tempDir.path,
      runId: 'step-isolation',
      stepId: step.id,
      mapIterationIndex: mapContext?.index,
    );
    Directory(stepArtifactsDir).createSync(recursive: true);

    // Seed the step-execution row the dispatcher writes in production, so the
    // one-shot runner reads its schema and persists its envelope through the
    // same repository the extractor reads back from.
    final envelopeSchema = buildExecutionEnvelopeSchema(step, step.outputs);
    // The task repository already inserts `ae-<taskId>`; only fill in the
    // provider and workspace the step execution row has to point at.
    final agentExecutionId = 'ae-${task.id}';
    final existingExecution = await agentExecutions.get(agentExecutionId);
    final agentExecution = AgentExecution(id: agentExecutionId, provider: 'claude', workspaceDir: fixtureDir);
    if (existingExecution == null) {
      await agentExecutions.create(agentExecution);
    } else {
      await agentExecutions.update(agentExecution);
    }
    await workflowStepExecutions.create(
      WorkflowStepExecution(
        taskId: task.id,
        agentExecutionId: agentExecutionId,
        workflowRunId: 'step-isolation',
        stepIndex: 0,
        stepId: step.id,
        stepType: step.taskType.toJson(),
        structuredSchemaJson: envelopeSchema == null ? null : jsonEncode(envelopeSchema),
        mapIterationIndex: mapContext?.index,
        mapIterationTotal: mapContext?.length,
      ),
    );
    final seededTask = (await taskService.get(task.id))!
        .copyWith(workflowStepExecution: await workflowStepExecutions.getByTaskId(task.id));

    // Pin the model: an unpinned harness falls back to the operator's own
    // configured default, which breaks hermeticity.
    final harness = HarnessFactory().create(
      'claude',
      HarnessFactoryConfig(
        cwd: fixtureDir,
        executable: 'claude',
        turnTimeout: stepTimeout,
        providerOptions: {'permissionMode': permissionMode},
        environment: {...inheritedEnv, stepArtifactsDirEnvVar: stepArtifactsDir},
      ),
    );
    final turnStopwatch = Stopwatch()..start();
    final TurnOutcome outcome;
    try {
      await harness.start();
      outcome = await oneShotRunner.execute(
        seededTask,
        runner: TurnRunner(
          turnLimits: TurnLimitsConfig(stallTimeout: Duration.zero, turnTimeout: stepTimeout),
          harness: harness,
          messages: messageService,
          behavior: BehaviorFileService(workspaceDir: fixtureDir),
          sessions: sessionService,
          providerId: 'claude',
        ),
        sessionId: session.id,
        pendingMessage: prompt,
        provider: 'claude',
        workingDirectory: fixtureDir,
        modelOverride: executorModel,
        effortOverride: null,
        allowedTools: null,
        readOnly: false,
      );
    } finally {
      turnStopwatch.stop();
      await harness.stop();
      await harness.dispose();
    }
    expect(outcome.status, TurnStatus.completed, reason: 'Step turn failed: ${outcome.errorMessage}');

    final assistantContent = (await messageService.getMessages(session.id))
        .where((message) => message.role == 'assistant')
        .map((message) => message.content)
        .join('\n');
    final refreshedTask = (await taskService.get(task.id))!;

    final outputs = await extractor.extract(step, refreshedTask);
    final artifactFile = File(
      p.join(
        artifactDir.path,
        '${(++artifactCounter).toString().padLeft(2, '0')}-'
        '${_sanitizeFileComponent(artifactLabel ?? step.id)}-'
        '${_sanitizeFileComponent(step.id)}-'
        '${task.id}.json',
      ),
    );
    final artifactPayload = <String, dynamic>{
      'stepId': step.id,
      'stepName': step.name,
      'taskId': task.id,
      'sessionId': session.id,
      'artifactLabel': artifactLabel ?? step.id,
      'fixtureDir': fixtureDir,
      'variables': context.variables,
      'systemVariables': stepContext.systemVariables,
      'contextData': context.data,
      'mapContext': mapContext == null
          ? null
          : {'item': mapContext.item, 'index': mapContext.index, 'length': mapContext.length},
      'resolvedPrompt': resolvedPrompt,
      'prompt': prompt,
      'assistantContent': assistantContent,
      'outputs': outputs,
      'promptCharCount': prompt.length,
      'assistantCharCount': assistantContent.length,
      'inputTokens': outcome.inputTokens,
      'outputTokens': outcome.outputTokens,
      'cacheReadTokens': outcome.cacheReadTokens,
      'cacheWriteTokens': outcome.cacheWriteTokens,
      'durationMs': turnStopwatch.elapsedMilliseconds,
    };
    await artifactFile.writeAsString(const JsonEncoder.withIndent('  ').convert(artifactPayload));

    return _StepExecutionResult(
      stepId: step.id,
      stepName: step.name,
      taskId: task.id,
      sessionId: session.id,
      prompt: prompt,
      assistantContent: assistantContent,
      outputs: outputs,
      artifactPath: artifactFile.path,
    );
  }

  // Deliberately not re-introduced: the previous `expectStoryPlanShape` helper
  // asserted on a richer story structured output (acceptance_criteria, type,
  // key_files, effort) that the current workflow does not declare – the plan
  // step only emits the `story_specs` shape. Use `expectStorySpecShape` for
  // every per-story assertion.

  test('discover-plan-state returns required PRD and empty optional plan handoffs', () async {
    if (!claudeReady) {
      markTestSkipped('claude binary not available – run with Claude Code CLI installed');
      return;
    }
    const prdPath = 'docs/specs/workflow-testing/prd.md';
    File(p.join(fixtureDir, prdPath))
      ..createSync(recursive: true)
      ..writeAsStringSync('# PRD\n\nMinimal plan workflow discovery fixture.\n');

    final result = await executeStep(
      step: _stepById(planDefinition, 'discover-plan-state'),
      context: WorkflowContext(
        variables: const {'FEATURE': prdPath, 'PROJECT': 'workflow-testing', 'BRANCH': 'main', 'MAX_PARALLEL': '1'},
      ),
    );

    expect(result.outputs['prd'], prdPath, reason: result.artifactPath);
    expect(result.outputs['plan'], '', reason: result.artifactPath);
    expect(_normalizeStoryList(result.outputs['story_specs']), isEmpty, reason: result.artifactPath);
  }, timeout: _defaultLiveTestTimeout);

  test('discover-plan-state indexes an existing plan for the plan workflow', () async {
    if (!claudeReady) {
      markTestSkipped('claude binary not available – run with Claude Code CLI installed');
      return;
    }
    const prdPath = 'docs/specs/workflow-testing/prd.md';
    const planPath = 'docs/specs/workflow-testing/plan.json';
    const fisPath = 'docs/specs/workflow-testing/fis/s01-existing-story.md';
    File(p.join(fixtureDir, prdPath))
      ..createSync(recursive: true)
      ..writeAsStringSync('# PRD\n\nExisting plan discovery fixture.\n');
    File(p.join(fixtureDir, fisPath))
      ..createSync(recursive: true)
      ..writeAsStringSync('# Existing Story FIS\n\nImplement the existing story.\n');
    File(p.join(fixtureDir, planPath))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        jsonEncode({
          'stories': [
            {
              'id': 'S01',
              'title': 'Existing Story',
              'fis': 'fis/s01-existing-story.md',
              'dependsOn': <String>[],
              'status': 'spec-ready',
            },
          ],
        }),
      );

    final planResult = await executeStep(
      step: _stepById(planDefinition, 'discover-plan-state'),
      context: WorkflowContext(
        variables: const {
          'FEATURE': prdPath,
          'PROJECT': 'workflow-test-todo-app',
          'BRANCH': 'main',
          'MAX_PARALLEL': '2',
        },
      ),
      artifactLabel: 'discover-plan-state-existing-plan',
    );

    expect(planResult.outputs['prd'], prdPath, reason: planResult.artifactPath);
    expect(planResult.outputs['plan'], planPath, reason: planResult.artifactPath);
    final storySpecs = _normalizeStoryList(planResult.outputs['story_specs']);
    expect(storySpecs, hasLength(1), reason: planResult.artifactPath);
    expectStorySpecShape(storySpecs.single);
    expect((storySpecs.single as Map<Object?, Object?>)['spec_path'], fisPath, reason: planResult.artifactPath);
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('plan emits stories and story_specs in a single pass from the reviewed PRD', () async {
    if (!claudeReady) {
      markTestSkipped('claude binary not available – run with Claude Code CLI installed');
      return;
    }
    const prdPath = 'docs/specs/workflow-testing/prd.md';
    File(p.join(fixtureDir, prdPath))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '# Product Requirements Document\n\n'
        '## Executive Summary\n\n'
        'Add a tiny integration-tested note file and keep the implementation minimal.\n\n'
        '## User Stories\n\n'
        '- Author a single markdown note file.\n'
        '- Validate that the note content matches expectations.\n',
      );

    final result = await executeStep(
      step: _stepById(planDefinition, 'plan'),
      context: WorkflowContext(
        variables: const {
          'FEATURE':
              'Create a tiny note-taking improvement: add one markdown note file and a follow-up validation step.',
          'PROJECT': 'workflow-testing',
          'BRANCH': 'main',
          'MAX_PARALLEL': '1',
        },
        data: {
          'project_index': {
            'framework': 'markdown',
            'project_root': fixtureDir,
            'document_locations': {'prd': prdPath, 'readme': 'README.md', 'agent_rules': 'AGENTS.md'},
            'state_protocol': {'state_file': 'STATE.md'},
          },
          'prd': prdPath,
        },
      ),
      stepTimeout: const Duration(minutes: 14),
    );

    // The plan step declares `story_specs` (story_specs schema) and `plan`
    // (format=path). The richer `stories` output was removed when the plan
    // bundle was collapsed onto the one-story-per-FIS invariant; assert on
    // `story_specs` + `plan` instead.
    final storySpecsList = _normalizeStoryList(result.outputs['story_specs']);
    expect(storySpecsList, isNotEmpty);
    final firstStorySpec = storySpecsList.first;
    expectStorySpecShape(firstStorySpec);

    _requireRelativeExistingPlanPath(result, 'plan', rootDir: fixtureDir);
    for (final storySpec in storySpecsList.whereType<Map<Object?, Object?>>()) {
      _requireRelativeExistingMarkdownPath(
        storySpec['spec_path'],
        rootDir: fixtureDir,
        artifactPath: result.artifactPath,
        label: 'story_specs.items[].spec_path',
      );
    }

    final resolvedStorySpec = templateEngine.resolveWithMap(
      '{{map.item}}',
      WorkflowContext(data: result.outputs, variables: const {}),
      MapContext(item: firstStorySpec as Object, index: 0, length: storySpecsList.length),
    );
    expect(resolvedStorySpec.trim(), contains('"id"'));
    expect(resolvedStorySpec.trim(), contains('"spec_path"'));
    // AC is resolved from the FIS body at spec_path, not carried inline.
    expect(resolvedStorySpec.trim(), isNot(contains('"acceptance_criteria"')));
  }, timeout: const Timeout(Duration(minutes: 15)));

  // Live authoring probe for spec-and-implement. The heavy spec-and-implement
  // e2e feeds a pre-authored FIS and skips the `spec` step, so the one live
  // authoring turn that used to run there is relocated here as a single thin
  // probe: run `spec` on a free-text feature and assert it self-classifies as a
  // synthesized spec with a parseable confidence and an on-disk FIS. Downstream
  // branch coverage stays in the stubbed built-in suite; the plan-authoring
  // counterpart is the "plan emits stories and story_specs" test above.
  test('spec authors a synthesized FIS with a self-rated confidence for a free-text feature', () async {
    if (!claudeReady) {
      markTestSkipped('claude binary not available – run with Claude Code CLI installed');
      return;
    }
    final result = await executeStep(
      step: _stepById(specDefinition, 'spec'),
      context: WorkflowContext(
        variables: const {
          'FEATURE':
              'Add exactly one new markdown note file at notes/spec-probe.md with one heading '
              '"Spec Probe" and one bullet "Authored by the spec step".',
          'PROJECT': 'workflow-testing',
          'BRANCH': 'main',
        },
        data: {
          'project_index': {
            'framework': 'markdown',
            'project_root': fixtureDir,
            'document_locations': {'readme': 'README.md', 'agent_rules': 'AGENTS.md'},
            'state_protocol': {'state_file': 'STATE.md'},
          },
        },
      ),
      stepTimeout: const Duration(minutes: 14),
      artifactLabel: 'spec-synthesized-free-text-feature',
    );

    expect(
      result.outputs['spec_source'],
      'synthesized',
      reason:
          'the spec step authors a new FIS from free text, so spec_source is synthesized. '
          'Artifact: ${result.artifactPath}',
    );
    final confidence = switch (result.outputs['spec_confidence']) {
      final int numeric => numeric,
      final value => int.tryParse('$value'),
    };
    expect(
      confidence,
      isNotNull,
      reason: 'spec_confidence must be parseable as an int. Artifact: ${result.artifactPath}',
    );
    expect(
      confidence,
      inInclusiveRange(1, 10),
      reason: 'a synthesized spec self-rates readiness 1-10. Artifact: ${result.artifactPath}',
    );
    _requireRelativeExistingMarkdownPath(
      result.outputs['spec_path'],
      rootDir: fixtureDir,
      artifactPath: result.artifactPath,
      label: 'spec_path',
    );
  }, timeout: const Timeout(Duration(minutes: 15)));

  test('integrated-review returns verdict with findings_count for a trivial markdown change', () async {
    if (!claudeReady) {
      markTestSkipped('claude binary not available – run with Claude Code CLI installed');
      return;
    }
    final result = await executeStep(
      step: _stepById(specDefinition, 'integrated-review'),
      context: WorkflowContext(
        variables: const {
          'FEATURE': 'Create exactly one new markdown file at notes/e2e-test.md with one heading and one bullet.',
          'PROJECT': 'workflow-testing',
          'BRANCH': 'main',
        },
        data: {
          'project_index': {
            'framework': 'markdown',
            'project_root': fixtureDir,
            'document_locations': {'readme': 'README.md', 'agent_rules': 'AGENTS.md'},
            'state_protocol': {'state_file': 'STATE.md'},
          },
          'spec_document': '# Specification\n\nCreate `notes/e2e-test.md` containing one heading "E2E Test" and one bullet "Automated test artifact".',
          'validation_summary':
              'Implementation validated. File notes/e2e-test.md exists with expected content. No issues found.',
          'diff_summary':
              'diff --git a/notes/e2e-test.md b/notes/e2e-test.md\n'
              'new file mode 100644\n'
              '--- /dev/null\n'
              '+++ b/notes/e2e-test.md\n'
              '@@ -0,0 +1,2 @@\n'
              '+# E2E Test\n'
              '+- Automated test artifact\n',
          'acceptance_criteria': '- One markdown file notes/e2e-test.md exists\n- Contains heading "E2E Test"\n- Contains bullet "Automated test artifact"',
        },
      ),
      artifactLabel: 'integrated-review-trivial-markdown-change',
    );

    // integrated-review step declares the scoped output key
    // `integrated-review.findings_count` (so the remediation loop gate
    // `integrated-review.findings_count > 0` disambiguates it from
    // re-review.findings_count). ContextExtractor stores results under the
    // literal declared key – assert on that key directly.
    _expectReviewReportPathOrCleanCounts(
      result,
      'integrated-review.review_report_path',
      'integrated-review.findings_count',
      rootDir: fixtureDir,
      runtimeArtifactsDir: runtimeArtifactsDir,
    );
    _expectGatingCountNotGreaterThanTotal(
      result,
      'integrated-review.findings_count',
      'integrated-review.gating_findings_count',
    );
  }, timeout: _defaultLiveTestTimeout);

  test('plan-review returns zero gating findings for a trivially clean two-story batch', () async {
    if (!claudeReady) {
      markTestSkipped('claude binary not available – run with Claude Code CLI installed');
      return;
    }
    _writeMarkdownNote(fixtureDir, 'notes/alpha.md', 'Alpha Note', 'Validated');
    _writeMarkdownNote(fixtureDir, 'notes/beta.md', 'Beta Note', 'Validated');

    final storySpecs = [
      {
        'id': 'S01',
        'title': 'Create Alpha Note',
        'description': 'Create the alpha note file.',
        'acceptance_criteria': [
          'notes/alpha.md exists',
          'Contains heading "Alpha Note"',
          'Contains bullet "Validated"',
        ],
        'type': 'coding',
        'dependencies': <String>[],
        'key_files': ['notes/alpha.md'],
        'effort': 'small',
        'spec': 'Create notes/alpha.md with heading "Alpha Note" and bullet "Validated".',
      },
      {
        'id': 'S02',
        'title': 'Create Beta Note',
        'description': 'Create the beta note file.',
        'acceptance_criteria': ['notes/beta.md exists', 'Contains heading "Beta Note"', 'Contains bullet "Validated"'],
        'type': 'coding',
        'dependencies': ['S01'],
        'key_files': ['notes/beta.md'],
        'effort': 'small',
        'spec': 'Create notes/beta.md with heading "Beta Note" and bullet "Validated".',
      },
    ];
    // Only the implement step promotes outputs to the per-story aggregate:
    // review-story's review keys stay loop-scoped, so each aggregate carries
    // only the implement payload.
    final storyResults = [
      {
        'implement': {'story_result': 'Created notes/alpha.md with heading "Alpha Note" and bullet "Validated".'},
      },
      {
        'implement': {'story_result': 'Created notes/beta.md with heading "Beta Note" and bullet "Validated".'},
      },
    ];

    final result = await executeStep(
      step: _stepById(planDefinition, 'plan-review'),
      context: WorkflowContext(
        variables: const {
          'FEATURE': 'Create two small markdown notes exactly as specified.',
          'PROJECT': 'workflow-testing',
          'BRANCH': 'main',
          'MAX_PARALLEL': '1',
        },
        data: {
          'project_index': {
            'framework': 'markdown',
            'project_root': fixtureDir,
            'document_locations': {'readme': 'README.md', 'agent_rules': 'AGENTS.md'},
            'state_protocol': {'state_file': 'STATE.md'},
          },
          'story_specs': storySpecs,
          'story_results': storyResults,
        },
      ),
      artifactLabel: 'plan-review-clean-two-story-batch',
    );

    // plan-review only declares `review_report_path` and scoped finding-count
    // outputs. Live reviewer verdicts are provider-judgment dependent; this
    // test asserts extraction shape and count consistency, not a fixed verdict.
    _expectReviewReportPathOrCleanCounts(
      result,
      'plan-review.review_report_path',
      'plan-review.findings_count',
      rootDir: fixtureDir,
      runtimeArtifactsDir: runtimeArtifactsDir,
    );
    _expectGatingCountNotGreaterThanTotal(result, 'plan-review.findings_count', 'plan-review.gating_findings_count');
  }, timeout: _defaultLiveTestTimeout);

  test('re-review returns zero findings after a trivially clean remediation pass', () async {
    if (!claudeReady) {
      markTestSkipped('claude binary not available – run with Claude Code CLI installed');
      return;
    }
    _writeMarkdownNote(fixtureDir, 'notes/alpha.md', 'Alpha Note', 'Validated');
    _writeMarkdownNote(fixtureDir, 'notes/beta.md', 'Beta Note', 'Validated');
    const planPath = 'docs/specs/workflow-testing/plan.md';
    final planFile = File(p.join(fixtureDir, planPath));
    planFile.parent.createSync(recursive: true);
    planFile.writeAsStringSync(
      '# Plan\n\n'
      '1. Create `notes/alpha.md` with heading "Alpha Note" and bullet "Validated".\n'
      '2. Create `notes/beta.md` with heading "Beta Note" and bullet "Validated".\n',
    );

    final storySpecs = [
      {
        'id': 'S01',
        'title': 'Create Alpha Note',
        'description': 'Create the alpha note file.',
        'acceptance_criteria': [
          'notes/alpha.md exists',
          'Contains heading "Alpha Note"',
          'Contains bullet "Validated"',
        ],
        'type': 'coding',
        'dependencies': <String>[],
        'key_files': ['notes/alpha.md'],
        'effort': 'small',
        'spec': 'Create notes/alpha.md with heading "Alpha Note" and bullet "Validated".',
      },
      {
        'id': 'S02',
        'title': 'Create Beta Note',
        'description': 'Create the beta note file.',
        'acceptance_criteria': ['notes/beta.md exists', 'Contains heading "Beta Note"', 'Contains bullet "Validated"'],
        'type': 'coding',
        'dependencies': ['S01'],
        'key_files': ['notes/beta.md'],
        'effort': 'small',
        'spec': 'Create notes/beta.md with heading "Beta Note" and bullet "Validated".',
      },
    ];

    final result = await executeStep(
      step: _stepById(planDefinition, 're-review'),
      context: WorkflowContext(
        variables: const {
          'FEATURE': 'Create two small markdown notes exactly as specified.',
          'PROJECT': 'workflow-testing',
          'BRANCH': 'main',
          'MAX_PARALLEL': '1',
        },
        data: {
          'project_index': {
            'framework': 'markdown',
            'project_root': fixtureDir,
            'document_locations': {'readme': 'README.md', 'agent_rules': 'AGENTS.md'},
            'state_protocol': {'state_file': 'STATE.md'},
          },
          'story_specs': storySpecs,
          'plan': planPath,
          'implementation_summary':
              'Both planned stories were implemented exactly as specified. '
              'Alpha and Beta note files exist with the expected heading and bullet, and the batch is otherwise clean.',
          'validation_summary': 'Post-remediation validation is clean. Both note files still exist with the exact expected content, and no validation findings remain.',
          'remediation_summary': 'Performed a consistency pass over the batch summary and confirmed that no code or content changes were required.',
          'diff_summary': 'No file changes were necessary because the implementation already matched the story specs.',
        },
      ),
      artifactLabel: 're-review-clean-remediation-pass',
    );

    expect(result.prompt, contains(planPath), reason: 'Artifact: ${result.artifactPath}');
    // findings_count tolerated as 0..1: a picky LLM pass occasionally flags the
    // single-line "Validated" bullet as vague. Test invariant is the wiring,
    // not the LLM's verdict on a synthetic fixture.
    final findingsCount = _expectReviewReportPathOrCleanCounts(
      result,
      'review_report_path',
      'findings_count',
      rootDir: fixtureDir,
      runtimeArtifactsDir: runtimeArtifactsDir,
    );
    expect(findingsCount, inInclusiveRange(0, 1), reason: 'Artifact: ${result.artifactPath}');
    final reportPath = result.outputs['review_report_path'] as String;
    expect(
      p.basename(reportPath),
      isNot(startsWith('clean-review-')),
      reason:
          'Expected the provider to write a real report through $stepArtifactsDirEnvVar. Artifact: ${result.artifactPath}',
    );
    expect(
      _requireFindingsCount(result, 'gating_findings_count'),
      lessThanOrEqualTo(findingsCount),
      reason: 'Artifact: ${result.artifactPath}',
    );
  }, timeout: _defaultLiveTestTimeout);
}

void _copyDirectorySync(Directory source, Directory target) {
  target.createSync(recursive: true);
  for (final entity in source.listSync(recursive: true, followLinks: false)) {
    final relativePath = p.relative(entity.path, from: source.path);
    if (entity is File) {
      final outFile = File(p.join(target.path, relativePath));
      outFile.parent.createSync(recursive: true);
      entity.copySync(outFile.path);
    } else if (entity is Directory) {
      Directory(p.join(target.path, relativePath)).createSync(recursive: true);
    }
  }
}
