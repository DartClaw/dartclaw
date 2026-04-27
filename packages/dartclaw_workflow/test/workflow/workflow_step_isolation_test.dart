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

int _requireFindingsCount(_StepExecutionResult result, String outputKey) {
  final value = result.outputs[outputKey];
  final count = switch (value) {
    final int numeric => numeric,
    _ => int.tryParse('$value'),
  };
  expect(count, isNotNull, reason: 'Expected $outputKey to be parseable as int. Artifact: ${result.artifactPath}');
  return count!;
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
    // Optional opt-in to the isolated Codex profile for this test run.
    // Exercise the managed CODEX_HOME/HOME path by exporting
    // `DARTCLAW_CODEX_ISOLATED_PROFILE=1`. Defaults off so day-to-day runs
    // keep using the user's personal profile.
    final useIsolatedProfile = Platform.environment['DARTCLAW_CODEX_ISOLATED_PROFILE']?.trim() == '1';
    final profileDataDir = useIsolatedProfile
        ? Directory.systemTemp.createTempSync('dartclaw_codex_profile_').path
        : null;
    runner = WorkflowCliRunner(
      providers: {
        'codex': WorkflowCliProviderConfig(
          executable: 'codex',
          options: {'sandbox': 'danger-full-access', if (useIsolatedProfile) 'isolated_profile': true},
          environment: inheritedEnv,
        ),
      },
      dataDir: profileDataDir,
    );
    artifactDir = _createPreservedArtifactDir('workflow-step-isolation');
  });

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_workflow_step_isolation_');
    final sessionsDir = p.join(tempDir.path, 'sessions');
    Directory(sessionsDir).createSync(recursive: true);
    fixtureDir = p.join(tempDir.path, 'fixture');
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
    final resolvedPrompt = mapContext == null
        ? templateEngine.resolve(step.prompt ?? '', context)
        : templateEngine.resolveWithMap(step.prompt ?? '', context, mapContext);

    final prompt = skillPromptBuilder.build(
      skill: step.skill,
      resolvedPrompt: resolvedPrompt,
      contextSummary: step.prompt == null && step.contextInputs.isNotEmpty
          ? SkillPromptBuilder.formatContextSummary(
              {for (final key in step.contextInputs) key: context[key] ?? ''},
              outputConfigs: SkillPromptBuilder.collectInputConfigs([
                ...planDefinition.steps,
                ...specDefinition.steps,
              ], step.contextInputs),
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

  void expectProjectIndexShape(Object? raw) {
    expect(raw, isA<Map<Object?, Object?>>());
    final projectIndex = raw! as Map<Object?, Object?>;
    expect(projectIndex['framework'], isA<String>());
    expect((projectIndex['framework'] as String).trim(), isNotEmpty);
    expect(projectIndex['project_root'], isA<String>());
    expect((projectIndex['project_root'] as String).trim(), isNotEmpty);
    expect(projectIndex['document_locations'], isA<Map<Object?, Object?>>());
    expect(projectIndex['state_protocol'], isA<Map<Object?, Object?>>());
  }

  // Deliberately not re-introduced: the previous `expectStoryPlanShape` helper
  // asserted on a richer story-plan preset (acceptance_criteria, type,
  // key_files, effort) that the current workflow does not declare — the plan
  // step only emits the `story-specs` shape. Use `expectStorySpecShape` for
  // every per-story assertion.

  test('discover-project returns the built-in project index contract', () async {
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

    expectProjectIndexShape(result.outputs['project_index']);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test(
    'plan emits story-plan stories and story-specs in a single pass from the reviewed PRD',
    () async {
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
              'document_locations': {'readme': 'README.md', 'agent_rules': 'AGENTS.md'},
              'state_protocol': {'state_file': 'STATE.md'},
            },
            'prd':
                '# Product Requirements Document\n\n'
                '## Executive Summary\n\n'
                'Add a tiny integration-tested note file and keep the implementation minimal.\n\n'
                '## User Stories\n\n'
                '- Author a single markdown note file.\n'
                '- Validate that the note content matches expectations.\n',
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

      expect(
        result.outputs['plan'],
        isA<String>(),
        reason: 'plan output should be a workspace-relative path. Artifact: ${result.artifactPath}',
      );
      expect((result.outputs['plan'] as String).trim(), isNotEmpty);

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
      final findingsCount = result.outputs['integrated-review.findings_count'];
      final reviewFindings = result.outputs['review_findings'];

      expect(
        reviewFindings,
        isNotNull,
        reason: 'review_findings should be extracted. Artifact: ${result.artifactPath}',
      );

      final numericCount = findingsCount is int ? findingsCount : int.tryParse(findingsCount.toString());
      expect(
        numericCount,
        isNotNull,
        reason:
            'integrated-review.findings_count should be parseable as int, got: $findingsCount '
            '(${findingsCount.runtimeType}). Artifact: ${result.artifactPath}',
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
    expect(result.outputs['review_findings'], isA<String>());
    expect((result.outputs['review_findings'] as String).trim(), isNotEmpty);
    expect(
      _requireFindingsCount(result, 'plan-review.findings_count'),
      0,
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
      expect(result.outputs['review_findings'], isA<String>());
      expect((result.outputs['review_findings'] as String).trim(), isNotEmpty);
      expect(
        _requireFindingsCount(result, 're-review.findings_count'),
        inInclusiveRange(0, 1),
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
