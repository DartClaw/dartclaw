@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

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

void main() {
  late final String fixturesRoot;
  late final String fixtureTemplateDir;
  late final WorkflowDefinition planDefinition;
  late final WorkflowDefinition specDefinition;
  late final WorkflowCliRunner runner;
  late Directory tempDir;
  late String fixtureDir;
  late TaskService taskService;
  late SessionService sessionService;
  late MessageService messageService;
  late ContextExtractor extractor;
  final templateEngine = WorkflowTemplateEngine();
  final skillPromptBuilder = SkillPromptBuilder(augmenter: const PromptAugmenter());

  setUpAll(() async {
    fixturesRoot = _fixturesRoot();
    fixtureTemplateDir = _stepIsolationFixtureTemplateDir(fixturesRoot);
    final parser = WorkflowDefinitionParser();
    planDefinition = await parser.parseFile(p.join(_definitionsDir(), 'plan-and-implement.yaml'));
    specDefinition = await parser.parseFile(p.join(_definitionsDir(), 'spec-and-implement.yaml'));

    runner = WorkflowCliRunner(
      providers: const {
        'codex': WorkflowCliProviderConfig(executable: 'codex', options: {'sandbox': 'danger-full-access'}),
      },
    );
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

  Future<Map<String, dynamic>> executeStep({
    required WorkflowStep step,
    required WorkflowContext context,
    MapContext? mapContext,
  }) async {
    final resolvedPrompt = mapContext == null
        ? templateEngine.resolve(step.prompt ?? '', context)
        : templateEngine.resolveWithMap(step.prompt ?? '', context, mapContext);

    final prompt = skillPromptBuilder.build(
      skill: step.skill,
      resolvedPrompt: resolvedPrompt,
      contextSummary: step.prompt == null && step.contextInputs.isNotEmpty
          ? SkillPromptBuilder.formatContextSummary({for (final key in step.contextInputs) key: context[key] ?? ''})
          : null,
      outputs: step.outputs,
      contextOutputs: step.contextOutputs,
    );

    final session = await sessionService.createSession(type: SessionType.task);
    final task = await taskService.create(
      id: 'task-${DateTime.now().microsecondsSinceEpoch}',
      title: step.name,
      description: prompt,
      type: TaskType.research,
      autoStart: true,
    );
    await taskService.updateFields(task.id, sessionId: session.id);

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
    outputs['_assistantContent'] = assistantContent;
    return outputs;
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

  void expectStoryPlanShape(List<dynamic> stories) {
    expect(stories, isNotEmpty);
    for (final story in stories) {
      expect(story, isA<Map<Object?, Object?>>());
      final typed = story as Map<Object?, Object?>;
      expect(typed['id'], isA<String>());
      expect((typed['id'] as String).trim(), isNotEmpty);
      expect(typed['title'], isA<String>());
      expect((typed['title'] as String).trim(), isNotEmpty);
      expect(typed['description'], isA<String>());
      expect(typed['acceptance_criteria'], isA<List<Object?>>());
      expect(typed['type'], isA<String>());
      expect(typed['dependencies'], isA<List<Object?>>());
      expect(typed['key_files'], isA<List<Object?>>());
      expect(typed['effort'], isA<String>());
    }
  }

  test('discover-project returns the built-in project index contract', () async {
    if (!await _codexAvailable()) {
      return;
    }

    final outputs = await executeStep(
      step: _stepById(specDefinition, 'discover-project'),
      context: WorkflowContext(
        variables: const {
          'FEATURE': 'No-op feature for discovery contract validation.',
          'PROJECT': 'workflow-testing',
          'BRANCH': 'main',
        },
      ),
    );

    expectProjectIndexShape(outputs['project_index']);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('plan returns a story-plan compatible list of stories', () async {
    if (!await _codexAvailable()) {
      return;
    }

    final outputs = await executeStep(
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
        },
      ),
    );

    final stories = _normalizeStoryList(outputs['stories']);
    expectStoryPlanShape(stories);
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('spec-plan produces indexable story specs for foreach prompts', () async {
    if (!await _codexAvailable()) {
      return;
    }

    final outputs = await executeStep(
      step: _stepById(planDefinition, 'spec-plan'),
      context: WorkflowContext(
        variables: const {
          'REQUIREMENTS': 'Add a tiny integration-tested note file and keep the implementation minimal.',
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
          'stories': [
            {
              'id': 'S01',
              'title': 'Write note',
              'description': 'Create the note file.',
              'acceptance_criteria': ['One markdown note file exists'],
              'type': 'coding',
              'dependencies': <String>[],
              'key_files': ['notes/isolation-test.md'],
              'effort': 'small',
            },
            {
              'id': 'S02',
              'title': 'Verify note',
              'description': 'Check the note content.',
              'acceptance_criteria': ['The note content is verified'],
              'type': 'analysis',
              'dependencies': ['S01'],
              'key_files': ['notes/isolation-test.md'],
              'effort': 'small',
            },
          ],
        },
      ),
    );

    final stories = _normalizeStoryList(outputs['stories']);
    expect(stories, isNotEmpty);
    final firstStory = stories.first;
    expect(firstStory, isA<Map<String, dynamic>>());

    final resolvedStorySpec = templateEngine.resolveWithMap(
      '{{map.item}}',
      WorkflowContext(data: outputs, variables: const {}),
      MapContext(item: firstStory as Object, index: 0, length: stories.length),
    );
    expect(resolvedStorySpec.trim(), contains('"id":"S01"'));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('integrated-review returns verdict with findings_count for a trivial markdown change', () async {
    if (!await _codexAvailable()) {
      return;
    }

    final outputs = await executeStep(
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
          'validation_summary': 'Implementation validated. File notes/e2e-test.md exists with expected content. No issues found.',
          'diff_summary': 'diff --git a/notes/e2e-test.md b/notes/e2e-test.md\n'
              'new file mode 100644\n'
              '--- /dev/null\n'
              '+++ b/notes/e2e-test.md\n'
              '@@ -0,0 +1,2 @@\n'
              '+# E2E Test\n'
              '+- Automated test artifact\n',
          'acceptance_criteria': '- One markdown file notes/e2e-test.md exists\n- Contains heading "E2E Test"\n- Contains bullet "Automated test artifact"',
        },
      ),
    );

    // Diagnostic: dump all extracted outputs before asserting.
    final findingsCount = outputs['findings_count'];
    final reviewFindings = outputs['review_findings'];
    final assistantContent = outputs['_assistantContent'] as String? ?? '';
    final contentPreview = assistantContent.length > 3000 ? assistantContent.substring(0, 3000) : assistantContent;

    // ignore: avoid_print
    print('\n=== INTEGRATED-REVIEW DIAGNOSTIC ===');
    // ignore: avoid_print
    print('findings_count=$findingsCount (${findingsCount.runtimeType})');
    // ignore: avoid_print
    print('review_findings=$reviewFindings');
    // ignore: avoid_print
    print('All output keys: ${outputs.keys.toList()}');
    // ignore: avoid_print
    print('--- assistant content (first 3000 chars) ---');
    // ignore: avoid_print
    print(contentPreview);
    // ignore: avoid_print
    print('=== END DIAGNOSTIC ===\n');

    // The review_findings output should be extracted.
    expect(reviewFindings, isNotNull, reason: 'review_findings should be extracted');

    // findings_count should be present and numeric.
    expect(findingsCount, isNotNull, reason: 'findings_count should be extracted');
    final numericCount = findingsCount is int ? findingsCount : int.tryParse(findingsCount.toString());
    expect(numericCount, isNotNull, reason: 'findings_count should be parseable as int, got: $findingsCount (${findingsCount.runtimeType})');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('quick-review returns a summary and numeric findings count', () async {
    if (!await _codexAvailable()) {
      return;
    }

    final outputs = await executeStep(
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
          'story_specs': [
            {
              'id': 'S01',
              'title': 'Create isolation review note',
              'acceptance_criteria': ['Create the note exactly once'],
              'spec': 'Create notes/isolation-review.md with heading "Isolation Review" and bullet "Validated".',
            },
          ],
          'implement.story_result':
              'Implemented notes/isolation-review.md with heading "Isolation Review" and bullet "Validated".',
          'verify-refine.validation_summary': 'Validation passed with no automated findings.',
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
    );

    expect(outputs['quick_review_summary'], isA<String>());
    expect((outputs['quick_review_summary'] as String).trim(), isNotEmpty);
    expect(outputs['quick_review_findings_count'], isA<int>());
  }, timeout: const Timeout(Duration(minutes: 5)));
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
