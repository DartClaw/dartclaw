@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show HarnessFactory;
import 'package:dartclaw_models/dartclaw_models.dart' show SessionType;
import 'package:dartclaw_server/dartclaw_server.dart' show TaskService, WorkflowCliProviderConfig, WorkflowCliRunner;
import 'package:dartclaw_storage/dartclaw_storage.dart' show SqliteTaskRepository;
import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        ContextExtractor,
        MapContext,
        MessageService,
        PromptAugmenter,
        SessionService,
        SkillPromptBuilder,
        Task,
        TaskType,
        WorkflowDefinition,
        WorkflowDefinitionParser,
        WorkflowContext,
        WorkflowStep,
        WorkflowTemplateEngine;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

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

String _stepIsolationFixtureTemplateDir(String fixturesRoot) => p.join(fixturesRoot, 'workflow-step-isolation');

String _definitionsDir() {
  var current = Directory.current;
  while (true) {
    final candidates = [
      p.join(current.path, 'lib', 'src', 'workflow', 'definitions'),
      p.join(current.path, 'packages', 'dartclaw_workflow', 'lib', 'src', 'workflow', 'definitions'),
    ];
    for (final candidate in candidates) {
      if (Directory(candidate).existsSync()) {
        return candidate;
      }
    }

    final parent = current.parent;
    if (parent.path == current.path) {
      throw StateError('Could not locate workflow definitions dir');
    }
    current = parent;
  }
}

Future<bool> _codexAvailable() async {
  try {
    final result = await Process.run('codex', ['--version']);
    return result.exitCode == 0;
  } catch (_) {
    return false;
  }
}

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
  // Matches the `story-specs` preset schema: items require id, title,
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

String _asTrimmedString(Object? value) => value is String ? value.trim() : '';

const _workflowTestTodoAppRepository = 'https://github.com/DartClaw/workflow-test-todo-app.git';
const _workflowTestTodoAppRevision = '5cc022878c28af49d723f55ca70343f0b979ec0d';

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
  expect(value, isA<String>(), reason: 'Expected $label to be a path string. Artifact: $artifactPath');
  final relativePath = (value as String).trim();
  expect(relativePath, isNotEmpty, reason: 'Expected $label to be non-empty. Artifact: $artifactPath');
  expect(
    p.isAbsolute(relativePath),
    isFalse,
    reason: 'Expected $label to be workspace-relative, got $relativePath. Artifact: $artifactPath',
  );
  expect(p.extension(relativePath), '.md', reason: 'Expected $label to be markdown. Artifact: $artifactPath');
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

Map<Object?, Object?> _expectProjectIndexShape(Object? raw, {required String artifactPath}) {
  expect(raw, isA<Map<Object?, Object?>>(), reason: 'Artifact: $artifactPath');
  final projectIndex = raw! as Map<Object?, Object?>;
  expect(projectIndex['framework'], isA<String>(), reason: 'Artifact: $artifactPath');
  expect((projectIndex['framework'] as String).trim(), isNotEmpty, reason: 'Artifact: $artifactPath');
  expect(projectIndex['project_root'], isA<String>(), reason: 'Artifact: $artifactPath');
  expect((projectIndex['project_root'] as String).trim(), isNotEmpty, reason: 'Artifact: $artifactPath');

  final documentLocations = projectIndex['document_locations'];
  expect(documentLocations, isA<Map<Object?, Object?>>(), reason: 'Artifact: $artifactPath');
  expect(
    (documentLocations! as Map<Object?, Object?>).keys.map((key) => '$key').toSet(),
    containsAll(const {
      'product',
      'backlog',
      'roadmap',
      'prd',
      'plan',
      'spec',
      'state',
      'readme',
      'agent_rules',
      'architecture',
      'guide',
    }),
    reason: 'Artifact: $artifactPath',
  );

  final stateProtocol = projectIndex['state_protocol'];
  expect(stateProtocol, isA<Map<Object?, Object?>>(), reason: 'Artifact: $artifactPath');
  expect(
    (stateProtocol! as Map<Object?, Object?>).keys.map((key) => '$key').toSet(),
    containsAll(const {'type', 'state_file', 'format'}),
    reason: 'Artifact: $artifactPath',
  );
  return projectIndex;
}

void _expectProjectRootResolvesTo(
  Map<Object?, Object?> projectIndex,
  String expectedRoot, {
  required String artifactPath,
}) {
  final rawRoot = _asTrimmedString(projectIndex['project_root']);
  final resolvedRoot = p.isAbsolute(rawRoot) ? p.normalize(rawRoot) : p.normalize(p.join(expectedRoot, rawRoot));
  expect(
    _canonicalExistingDirectoryPath(resolvedRoot),
    _canonicalExistingDirectoryPath(expectedRoot),
    reason: 'Artifact: $artifactPath',
  );
}

void _expectDocumentLocation(
  Map<Object?, Object?> projectIndex,
  String key,
  String expectedPath, {
  required String artifactPath,
}) {
  final documentLocations = projectIndex['document_locations'] as Map<Object?, Object?>;
  expect(documentLocations[key], expectedPath, reason: 'document_locations.$key mismatch. Artifact: $artifactPath');
}

void _expectDocumentLocationFileExists(
  Map<Object?, Object?> projectIndex,
  String key,
  String rootDir, {
  required String artifactPath,
}) {
  final documentLocations = projectIndex['document_locations'] as Map<Object?, Object?>;
  final relativePath = _asTrimmedString(documentLocations[key]);
  expect(relativePath, isNotEmpty, reason: 'document_locations.$key is empty. Artifact: $artifactPath');
  expect(
    p.isAbsolute(relativePath),
    isFalse,
    reason: 'document_locations.$key must be relative. Artifact: $artifactPath',
  );
  expect(
    File(p.join(rootDir, relativePath)).existsSync(),
    isTrue,
    reason: 'document_locations.$key does not exist at $relativePath. Artifact: $artifactPath',
  );
}

void _expectStateProtocolPath(Map<Object?, Object?> projectIndex, String expectedPath, {required String artifactPath}) {
  final stateProtocol = projectIndex['state_protocol'] as Map<Object?, Object?>;
  expect(
    stateProtocol['state_file'],
    expectedPath,
    reason: 'state_protocol.state_file mismatch. Artifact: $artifactPath',
  );
}

void _expectProjectIndexPathsStayInside(
  Map<Object?, Object?> projectIndex,
  String rootDir, {
  required String artifactPath,
}) {
  for (final path in _projectIndexPathFields(projectIndex)) {
    final value = _asTrimmedString(path.value);
    if (value.isEmpty || value == 'null' || value == 'not found') continue;
    expect(p.isAbsolute(value), isFalse, reason: '${path.label} must be workspace-relative. Artifact: $artifactPath');
    expect(
      p.split(value),
      isNot(contains('..')),
      reason: '${path.label} must not contain parent traversal. Artifact: $artifactPath',
    );
    final resolved = p.normalize(p.join(rootDir, value));
    expect(
      resolved == p.normalize(rootDir) || p.isWithin(p.normalize(rootDir), resolved),
      isTrue,
      reason: '${path.label} escapes project root: $value. Artifact: $artifactPath',
    );
  }
}

List<({String label, Object? value})> _projectIndexPathFields(Map<Object?, Object?> projectIndex) {
  final paths = <({String label, Object? value})>[];
  void collectMap(String prefix, Object? raw) {
    if (raw is! Map) return;
    for (final entry in raw.entries) {
      paths.add((label: '$prefix.${entry.key}', value: entry.value));
    }
  }

  collectMap('document_locations', projectIndex['document_locations']);
  collectMap('artifact_locations', projectIndex['artifact_locations']);
  final stateProtocol = projectIndex['state_protocol'];
  if (stateProtocol is Map) {
    paths.add((label: 'state_protocol.state_file', value: stateProtocol['state_file']));
  }
  paths.add((label: 'active_prd', value: projectIndex['active_prd']));
  paths.add((label: 'active_plan', value: projectIndex['active_plan']));

  final activeStorySpecs = projectIndex['active_story_specs'];
  final items = activeStorySpecs is Map ? activeStorySpecs['items'] : null;
  if (items is Iterable) {
    var index = 0;
    for (final item in items) {
      if (item is Map) {
        paths.add((label: 'active_story_specs.items[$index].spec_path', value: item['spec_path']));
      }
      index++;
    }
  }
  return paths;
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

  const _StepExecutionResult({
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
  late final WorkflowCliRunner runner;
  late final Directory artifactDir;
  late Directory tempDir;
  late String fixtureDir;
  late String runtimeArtifactsDir;
  late TaskService taskService;
  late SessionService sessionService;
  late MessageService messageService;
  late ContextExtractor extractor;
  final templateEngine = WorkflowTemplateEngine();
  final skillPromptBuilder = SkillPromptBuilder(augmenter: const PromptAugmenter(), harnessFactory: HarnessFactory());
  var artifactCounter = 0;

  setUpAll(() async {
    if (!await _codexAvailable()) {
      markTestSkipped('codex binary not available — run with Codex CLI installed');
    }
    fixturesRoot = _fixturesRoot();
    fixtureTemplateDir = _stepIsolationFixtureTemplateDir(fixturesRoot);
    final parser = WorkflowDefinitionParser();
    planDefinition = await parser.parseFile(p.join(_definitionsDir(), 'plan-and-implement.yaml'));
    specDefinition = await parser.parseFile(p.join(_definitionsDir(), 'spec-and-implement.yaml'));

    // `SafeProcess.start` runs with `includeParentEnvironment: false`, so the
    // spawned `codex` binary only sees whatever environment the provider
    // config hands through. Propagate PATH + HOME explicitly so tests running
    // outside the server wiring can still locate the binary.
    final inheritedEnv = <String, String>{
      for (final key in const ['PATH', 'HOME', 'USER', 'LOGNAME', 'TMPDIR', 'LANG', 'LC_ALL'])
        if (Platform.environment[key] != null) key: Platform.environment[key]!,
    };
    runner = WorkflowCliRunner(
      providers: {
        'codex': WorkflowCliProviderConfig(
          executable: 'codex',
          options: const {'sandbox': 'danger-full-access'},
          environment: inheritedEnv,
        ),
      },
    );
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

    taskService = TaskService(SqliteTaskRepository(sqlite3.openInMemory()));
    sessionService = SessionService(baseDir: sessionsDir);
    messageService = MessageService(baseDir: sessionsDir);
    extractor = ContextExtractor(taskService: taskService, messageService: messageService, dataDir: tempDir.path);
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
      provider: 'codex',
    );

    final session = await sessionService.createSession(type: SessionType.task);
    final task = await taskService.create(
      id: 'task-${DateTime.now().microsecondsSinceEpoch}',
      title: step.name,
      description: prompt,
      type: TaskType.research,
      autoStart: true,
      workflowRunId: 'step-isolation',
    );
    // Attach the fixture directory as the task worktree so
    // ContextExtractor._resolveFileSystemOutput can locate artifacts written
    // by the skill (e.g. plan.md) against an actual filesystem root.
    await taskService.updateFields(task.id, sessionId: session.id, worktreeJson: {'path': fixtureDir});

    final turnResult = await runner.executeTurn(
      provider: 'codex',
      prompt: prompt,
      workingDirectory: fixtureDir,
      profileId: 'default',
    );

    final assistantContent = turnResult.structuredOutput != null
        ? jsonEncode(turnResult.structuredOutput)
        : turnResult.responseText;
    await messageService.insertMessage(sessionId: session.id, role: 'assistant', content: assistantContent);

    Task refreshedTask = (await taskService.get(task.id))!;
    if (turnResult.structuredOutput != null) {
      refreshedTask = await taskService.updateFields(
        task.id,
        configJson: {'_workflowStructuredOutputPayload': turnResult.structuredOutput},
      );
    }

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
      'inputTokens': turnResult.inputTokens,
      'outputTokens': turnResult.outputTokens,
      'cacheReadTokens': turnResult.cacheReadTokens,
      'cacheWriteTokens': turnResult.cacheWriteTokens,
      'durationMs': turnResult.duration.inMilliseconds,
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

  Future<void> replaceFixtureWithWorkflowTestTodoApp() async {
    if (Directory(fixtureDir).existsSync()) {
      Directory(fixtureDir).deleteSync(recursive: true);
    }
    Directory(fixtureDir).createSync(recursive: true);
    final initResult = await Process.run('git', ['init', '-q'], workingDirectory: fixtureDir);
    if (initResult.exitCode != 0) {
      throw StateError('Failed to initialize workflow-test-todo-app fixture repo: ${initResult.stderr}');
    }
    final remoteResult = await Process.run('git', [
      'remote',
      'add',
      'origin',
      _workflowTestTodoAppRepository,
    ], workingDirectory: fixtureDir);
    if (remoteResult.exitCode != 0) {
      throw StateError('Failed to add workflow-test-todo-app origin: ${remoteResult.stderr}');
    }
    final fetchResult = await Process.run(
      'git',
      ['fetch', '--depth', '1', 'origin', _workflowTestTodoAppRevision],
      workingDirectory: fixtureDir,
      environment: const {'GIT_TERMINAL_PROMPT': '0'},
    );
    if (fetchResult.exitCode != 0) {
      throw StateError('Failed to fetch workflow-test-todo-app fixture revision: ${fetchResult.stderr}');
    }
    final checkoutResult = await Process.run('git', [
      'checkout',
      '--detach',
      '-q',
      'FETCH_HEAD',
    ], workingDirectory: fixtureDir);
    if (checkoutResult.exitCode != 0) {
      throw StateError('Failed to check out workflow-test-todo-app fixture revision: ${checkoutResult.stderr}');
    }
    Process.runSync('git', ['config', 'user.name', 'Workflow Test'], workingDirectory: fixtureDir);
    Process.runSync('git', ['config', 'user.email', 'workflow-tests@example.com'], workingDirectory: fixtureDir);

    final backlog = File(p.join(fixtureDir, 'docs', 'PRODUCT-BACKLOG.md'));
    if (!backlog.existsSync()) {
      throw StateError('workflow-test-todo-app fixture is missing docs/PRODUCT-BACKLOG.md');
    }
    final backlogText = backlog.readAsStringSync();
    for (final bugId in const ['BUG-001', 'BUG-002', 'BUG-003']) {
      expect(backlogText, contains(bugId), reason: 'workflow-test-todo-app fixture is missing $bugId');
    }
  }

  // Deliberately not re-introduced: the previous `expectStoryPlanShape` helper
  // asserted on a richer story-plan preset (acceptance_criteria, type,
  // key_files, effort) that the current workflow does not declare — the plan
  // step only emits the `story-specs` shape. Use `expectStorySpecShape` for
  // every per-story assertion.

  test(
    'discover-project returns a confined minimal-project index for the spec workflow',
    () async {
      final result = await executeStep(
        step: _stepById(specDefinition, 'discover-project'),
        context: WorkflowContext(
          variables: const {
            'FEATURE': 'No-op feature for discovery contract validation.',
            'PROJECT': 'workflow-testing',
            'BRANCH': 'main',
          },
        ),
      );

      final projectIndex = _expectProjectIndexShape(result.outputs['project_index'], artifactPath: result.artifactPath);
      _expectProjectRootResolvesTo(projectIndex, fixtureDir, artifactPath: result.artifactPath);
      _expectProjectIndexPathsStayInside(projectIndex, fixtureDir, artifactPath: result.artifactPath);
      expect(_asTrimmedString(projectIndex['framework']).toLowerCase(), 'none', reason: result.artifactPath);
      _expectDocumentLocation(projectIndex, 'readme', 'README.md', artifactPath: result.artifactPath);
      expect(result.outputs['spec_path'], '', reason: result.artifactPath);
      expect(result.outputs['spec_source'], 'synthesized', reason: result.artifactPath);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'discover-project returns empty active plan handoffs for the minimal plan workflow',
    () async {
      final result = await executeStep(
        step: _stepById(planDefinition, 'discover-project'),
        context: WorkflowContext(
          variables: const {
            'REQUIREMENTS': 'No-op requirements for discovery contract validation.',
            'PROJECT': 'workflow-testing',
            'BRANCH': 'main',
            'MAX_PARALLEL': '1',
          },
        ),
      );

      final projectIndex = _expectProjectIndexShape(result.outputs['project_index'], artifactPath: result.artifactPath);
      _expectProjectRootResolvesTo(projectIndex, fixtureDir, artifactPath: result.artifactPath);
      _expectProjectIndexPathsStayInside(projectIndex, fixtureDir, artifactPath: result.artifactPath);
      expect(_asTrimmedString(projectIndex['framework']).toLowerCase(), 'none', reason: result.artifactPath);
      expect(result.outputs['prd'], '', reason: result.artifactPath);
      expect(result.outputs['plan'], '', reason: result.artifactPath);
      expect(_normalizeStoryList(result.outputs['story_specs']), isEmpty, reason: result.artifactPath);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'discover-project indexes workflow-test-todo-app for both built-in workflows',
    () async {
      await replaceFixtureWithWorkflowTestTodoApp();

      final specResult = await executeStep(
        step: _stepById(specDefinition, 'discover-project'),
        context: WorkflowContext(
          variables: const {
            'FEATURE':
                'Fix BUG-001 from docs/PRODUCT-BACKLOG.md: the sidebar incomplete-count is stale after deletion.',
            'PROJECT': 'workflow-test-todo-app',
            'BRANCH': 'main',
          },
        ),
        artifactLabel: 'discover-project-todo-app-spec-workflow',
      );
      final planResult = await executeStep(
        step: _stepById(planDefinition, 'discover-project'),
        context: WorkflowContext(
          variables: const {
            'REQUIREMENTS': 'Fix BUG-002 and BUG-003 from docs/PRODUCT-BACKLOG.md as two independent stories.',
            'PROJECT': 'workflow-test-todo-app',
            'BRANCH': 'main',
            'MAX_PARALLEL': '2',
          },
        ),
        artifactLabel: 'discover-project-todo-app-plan-workflow',
      );

      _expectProjectIndexShape(specResult.outputs['project_index'], artifactPath: specResult.artifactPath);
      _expectProjectIndexShape(planResult.outputs['project_index'], artifactPath: planResult.artifactPath);
      for (final result in [specResult, planResult]) {
        final projectIndex = result.outputs['project_index'] as Map<Object?, Object?>;
        _expectProjectRootResolvesTo(projectIndex, fixtureDir, artifactPath: result.artifactPath);
        _expectProjectIndexPathsStayInside(projectIndex, fixtureDir, artifactPath: result.artifactPath);
        expect(_asTrimmedString(projectIndex['framework']).toLowerCase(), 'andthen', reason: result.artifactPath);
        _expectDocumentLocation(projectIndex, 'backlog', 'docs/PRODUCT-BACKLOG.md', artifactPath: result.artifactPath);
        _expectDocumentLocation(projectIndex, 'roadmap', 'docs/ROADMAP.md', artifactPath: result.artifactPath);
        _expectDocumentLocation(projectIndex, 'state', 'docs/STATE.md', artifactPath: result.artifactPath);
        _expectDocumentLocation(projectIndex, 'readme', 'README.md', artifactPath: result.artifactPath);
        _expectDocumentLocationFileExists(projectIndex, 'agent_rules', fixtureDir, artifactPath: result.artifactPath);
        _expectStateProtocolPath(projectIndex, 'docs/STATE.md', artifactPath: result.artifactPath);
        expect(projectIndex['active_prd'], isNull, reason: result.artifactPath);
        expect(projectIndex['active_plan'], isNull, reason: result.artifactPath);
        expect(projectIndex['active_story_specs'], isNull, reason: result.artifactPath);
      }
      expect(specResult.outputs['spec_path'], '', reason: specResult.artifactPath);
      expect(specResult.outputs['spec_source'], 'synthesized', reason: specResult.artifactPath);
      expect(planResult.outputs['prd'], '', reason: planResult.artifactPath);
      expect(planResult.outputs['plan'], '', reason: planResult.artifactPath);
      expect(_normalizeStoryList(planResult.outputs['story_specs']), isEmpty, reason: planResult.artifactPath);
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test(
    'plan emits story-plan stories and story-specs in a single pass from the reviewed PRD',
    () async {
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
            'REQUIREMENTS':
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
      );

      // The plan step declares `story_specs` (story-specs schema) and `plan`
      // (format=path). The richer `stories` output was removed when the plan
      // bundle was collapsed onto the one-story-per-FIS invariant; assert on
      // `story_specs` + `plan` instead.
      final storySpecsList = _normalizeStoryList(result.outputs['story_specs']);
      expect(storySpecsList, isNotEmpty);
      final firstStorySpec = storySpecsList.first;
      expectStorySpecShape(firstStorySpec);

      _requireRelativeMarkdownArtifactPath(result, 'plan', rootDir: fixtureDir);
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
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'integrated-review returns verdict with findings_count for a trivial markdown change',
    () async {
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
            'spec_document':
                '# Specification\n\nCreate `notes/e2e-test.md` containing one heading "E2E Test" and one bullet "Automated test artifact".',
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
            'acceptance_criteria':
                '- One markdown file notes/e2e-test.md exists\n- Contains heading "E2E Test"\n- Contains bullet "Automated test artifact"',
          },
        ),
        artifactLabel: 'integrated-review-trivial-markdown-change',
      );

      // integrated-review step declares the scoped output key
      // `integrated-review.findings_count` (so the remediation loop gate
      // `integrated-review.findings_count > 0` disambiguates it from
      // re-review.findings_count). ContextExtractor stores results under the
      // literal declared key — assert on that key directly.
      _expectReviewReportPathOrCleanCounts(
        result,
        'review_findings',
        'integrated-review.findings_count',
        rootDir: fixtureDir,
        runtimeArtifactsDir: runtimeArtifactsDir,
      );
      _expectGatingCountNotGreaterThanTotal(
        result,
        'integrated-review.findings_count',
        'integrated-review.gating_findings_count',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test('quick-review returns a summary and numeric findings count', () async {
    final result = await executeStep(
      step: _stepById(planDefinition, 'quick-review'),
      context: WorkflowContext(
        variables: const {
          'REQUIREMENTS': 'Add exactly one markdown note file with one heading and one bullet.',
          'PROJECT': 'workflow-testing',
          'BRANCH': 'main',
          'MAX_PARALLEL': '1',
        },
        data: {
          'project_index': {'framework': 'markdown', 'project_root': fixtureDir},
          'story_specs': {
            'items': [
              {
                'id': 'S01',
                'title': 'Create isolation review note',
                'acceptance_criteria': ['Create the note exactly once'],
                'spec': 'Create notes/isolation-review.md with heading "Isolation Review" and bullet "Validated".',
              },
            ],
          },
          'story_result':
              'Implemented notes/isolation-review.md with heading "Isolation Review" and bullet "Validated".',
        },
      ),
      mapContext: MapContext(
        item: const {
          'id': 'S01',
          'title': 'Create isolation review note',
          'acceptance_criteria': ['Create the note exactly once'],
          'spec': 'Create notes/isolation-review.md with heading "Isolation Review" and bullet "Validated".',
        },
        index: 0,
        length: 1,
      ),
      artifactLabel: 'quick-review-single-story-clean',
    );

    expect(result.outputs['quick_review_summary'], isA<String>());
    expect((result.outputs['quick_review_summary'] as String).trim(), isNotEmpty);
    expect(result.outputs['quick_review_findings_count'], isA<int>());
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('plan-review returns zero findings for a trivially clean two-story batch', () async {
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
    final storyResults = [
      {
        'implement': {'story_result': 'Created notes/alpha.md with heading "Alpha Note" and bullet "Validated".'},
        'quick-review': {
          'quick_review_summary': 'Story S01 matches its spec and acceptance criteria. No findings.',
          'quick_review_findings_count': 0,
        },
      },
      {
        'implement': {'story_result': 'Created notes/beta.md with heading "Beta Note" and bullet "Validated".'},
        'quick-review': {
          'quick_review_summary': 'Story S02 matches its spec and acceptance criteria. No findings.',
          'quick_review_findings_count': 0,
        },
      },
    ];

    final result = await executeStep(
      step: _stepById(planDefinition, 'plan-review'),
      context: WorkflowContext(
        variables: const {
          'REQUIREMENTS': 'Create two small markdown notes exactly as specified.',
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

    // plan-review only declares `review_findings` and the scoped
    // `plan-review.findings_count` output. Assert on those — the batch-level
    // `implementation_summary` key used by e2e overrides is not a real
    // extractor output.
    expect(
      _expectReviewReportPathOrCleanCounts(
        result,
        'review_findings',
        'plan-review.findings_count',
        rootDir: fixtureDir,
        runtimeArtifactsDir: runtimeArtifactsDir,
      ),
      0,
      reason: 'Artifact: ${result.artifactPath}',
    );
    expect(
      _requireFindingsCount(result, 'plan-review.gating_findings_count'),
      0,
      reason: 'Artifact: ${result.artifactPath}',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('architecture-review returns a workspace-relative findings report path', () async {
    _writeMarkdownNote(fixtureDir, 'notes/alpha.md', 'Alpha Note', 'Validated');
    _writeMarkdownNote(fixtureDir, 'notes/beta.md', 'Beta Note', 'Validated');
    _writeMarkdownNote(
      fixtureDir,
      'docs/specs/demo/plan.md',
      'Plan',
      'Create two independent markdown notes with no production architecture changes.',
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
    final storyResults = [
      {
        'implement': {'story_result': 'Created notes/alpha.md with heading "Alpha Note" and bullet "Validated".'},
        'quick-review': {
          'quick_review_summary': 'Story S01 matches its spec and acceptance criteria. No findings.',
          'quick_review_findings_count': 0,
        },
      },
      {
        'implement': {'story_result': 'Created notes/beta.md with heading "Beta Note" and bullet "Validated".'},
        'quick-review': {
          'quick_review_summary': 'Story S02 matches its spec and acceptance criteria. No findings.',
          'quick_review_findings_count': 0,
        },
      },
    ];

    final result = await executeStep(
      step: _stepById(planDefinition, 'architecture-review'),
      context: WorkflowContext(
        variables: const {
          'REQUIREMENTS': 'Create two small markdown notes exactly as specified.',
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
          'plan': 'docs/specs/demo/plan.md',
        },
      ),
      artifactLabel: 'architecture-review-clean-two-story-batch',
    );

    _requireRelativeMarkdownArtifactPath(result, 'architecture_review_findings', rootDir: fixtureDir);
    final findingsCount = _requireFindingsCount(result, 'architecture-review.findings_count');
    expect(findingsCount, inInclusiveRange(0, 1), reason: 'Artifact: ${result.artifactPath}');
    expect(
      _requireFindingsCount(result, 'architecture-review.gating_findings_count'),
      lessThanOrEqualTo(findingsCount),
      reason: 'Artifact: ${result.artifactPath}',
    );
  }, timeout: const Timeout(Duration(minutes: 5)));

  test(
    're-review returns zero findings after a trivially clean remediation pass',
    () async {
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
          'acceptance_criteria': [
            'notes/beta.md exists',
            'Contains heading "Beta Note"',
            'Contains bullet "Validated"',
          ],
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
            'REQUIREMENTS': 'Create two small markdown notes exactly as specified.',
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
            'implementation_summary':
                'Both planned stories were implemented exactly as specified. '
                'Alpha and Beta note files exist with the expected heading and bullet, and the batch is otherwise clean.',
            'validation_summary':
                'Post-remediation validation is clean. Both note files still exist with the exact expected content, and no validation findings remain.',
            'remediation_summary':
                'Performed a consistency pass over the batch summary and confirmed that no code or content changes were required.',
            'diff_summary':
                'No file changes were necessary because the implementation already matched the story specs.',
          },
        ),
        artifactLabel: 're-review-clean-remediation-pass',
      );

      // findings_count tolerated as 0..1: a picky LLM pass occasionally flags the
      // single-line "Validated" bullet as vague. Test invariant is the wiring,
      // not the LLM's verdict on a synthetic fixture.
      final findingsCount = _expectReviewReportPathOrCleanCounts(
        result,
        'review_findings',
        're-review.findings_count',
        rootDir: fixtureDir,
        runtimeArtifactsDir: runtimeArtifactsDir,
      );
      expect(findingsCount, inInclusiveRange(0, 1), reason: 'Artifact: ${result.artifactPath}');
      expect(
        _requireFindingsCount(result, 're-review.gating_findings_count'),
        lessThanOrEqualTo(findingsCount),
        reason: 'Artifact: ${result.artifactPath}',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
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
