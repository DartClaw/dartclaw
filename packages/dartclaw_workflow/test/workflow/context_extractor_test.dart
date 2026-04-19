import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart'
    show
        ArtifactKind,
        ExtractionConfig,
        ExtractionType,
        MessageService,
        OutputConfig,
        OutputFormat,
        OutputMode,
        SessionService,
        Task,
        TaskType,
        WorkflowStep;
import 'package:dartclaw_workflow/dartclaw_workflow.dart' show ContextExtractor;
import 'package:dartclaw_server/dartclaw_server.dart' show TaskService;
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show InMemoryWorkflowStepExecutionRepository;
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:dartclaw_core/dartclaw_core.dart' show AgentExecution, WorkflowStepExecution;

void main() {
  late Directory tempDir;
  late String sessionsDir;
  late TaskService taskService;
  late SqliteAgentExecutionRepository agentExecutions;
  late InMemoryWorkflowStepExecutionRepository workflowStepExecutions;
  late MessageService messageService;
  late SessionService sessionService;
  late ContextExtractor extractor;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_ctx_extractor_test_');
    sessionsDir = p.join(tempDir.path, 'sessions');
    Directory(sessionsDir).createSync(recursive: true);

    final db = sqlite3.openInMemory();
    agentExecutions = SqliteAgentExecutionRepository(db);
    taskService = TaskService(
      SqliteTaskRepository(db),
      agentExecutionRepository: agentExecutions,
      executionTransactor: SqliteExecutionRepositoryTransactor(db),
    );
    workflowStepExecutions = InMemoryWorkflowStepExecutionRepository();
    sessionService = SessionService(baseDir: sessionsDir);
    messageService = MessageService(baseDir: sessionsDir);
    extractor = ContextExtractor(
      taskService: taskService,
      messageService: messageService,
      dataDir: tempDir.path,
      workflowStepExecutionRepository: workflowStepExecutions,
    );
  });

  tearDown(() async {
    await taskService.dispose();
    await messageService.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<Task> createTask({String? sessionId}) async {
    return taskService.create(
      id: 'task-1',
      title: 'Test task',
      description: 'Test',
      type: TaskType.research,
      autoStart: true,
    );
  }

  WorkflowStep makeStep({
    List<String> contextOutputs = const [],
    ExtractionConfig? extraction,
    Map<String, OutputConfig>? outputs,
  }) {
    return WorkflowStep(
      id: 'step1',
      name: 'Step 1',
      prompts: ['Do something'],
      contextOutputs: contextOutputs,
      extraction: extraction,
      outputs: outputs,
    );
  }

  test('returns empty map when step has no contextOutputs', () async {
    final task = await createTask();
    final step = makeStep(contextOutputs: []);
    final outputs = await extractor.extract(step, task);
    expect(outputs, isEmpty);
  });

  test('falls back to empty string with no artifacts or session', () async {
    final task = await createTask();
    final step = makeStep(contextOutputs: ['research_notes']);
    final outputs = await extractor.extract(step, task);
    expect(outputs['research_notes'], equals(''));
  });

  test('extracts first .md artifact content', () async {
    final task = await createTask();
    final artifactsDir = Directory(p.join(tempDir.path, 'tasks', 'task-1', 'artifacts'));
    artifactsDir.createSync(recursive: true);
    final mdFile = File(p.join(artifactsDir.path, 'output.md'));
    mdFile.writeAsStringSync('# Research Notes\nThis is the research output.');

    await taskService.addArtifact(
      id: 'artifact-1',
      taskId: 'task-1',
      name: 'output.md',
      kind: ArtifactKind.document,
      path: p.join(artifactsDir.path, 'output.md'),
    );

    final step = makeStep(contextOutputs: ['research_notes']);
    final outputs = await extractor.extract(step, task);
    expect(outputs['research_notes'], contains('Research Notes'));
  });

  test('extracts from workflow-context XML tag', () async {
    final session = await sessionService.getOrCreateMain();
    await messageService.insertMessage(sessionId: session.id, role: 'user', content: 'Do some research');
    await messageService.insertMessage(
      sessionId: session.id,
      role: 'assistant',
      content:
          'Here is my response.\n\n<workflow-context>{"research_notes":"Found important findings about X.","summary":"Brief summary here."}</workflow-context>',
    );

    // Task needs a sessionId — create it via updateFields after autoStart.
    await taskService.create(
      id: 'task-session-1',
      title: 'Test',
      description: 'Test',
      type: TaskType.research,
      autoStart: true,
    );
    await taskService.updateFields('task-session-1', sessionId: session.id);
    final taskWithSession = (await taskService.get('task-session-1'))!;

    final step = makeStep(contextOutputs: ['research_notes']);
    final outputs = await extractor.extract(step, taskWithSession);
    expect(outputs['research_notes'], equals('Found important findings about X.'));
  });

  test('extracts structured JSON values from workflow-context XML tag', () async {
    final session = await sessionService.getOrCreateMain();
    await messageService.insertMessage(
      sessionId: session.id,
      role: 'assistant',
      content:
          'Done.\n\n<workflow-context>{"research_notes":"JSON extracted value","summary":"JSON summary"}</workflow-context>',
    );

    await taskService.create(
      id: 'task-json-1',
      title: 'Test',
      description: 'Test',
      type: TaskType.research,
      autoStart: true,
    );
    await taskService.updateFields('task-json-1', sessionId: session.id);
    final taskWithSession = (await taskService.get('task-json-1'))!;

    final step = makeStep(contextOutputs: ['research_notes']);
    final outputs = await extractor.extract(step, taskWithSession);
    expect(outputs['research_notes'], equals('JSON extracted value'));
  });

  test('uses the most recent assistant message containing workflow-context, not only the last assistant message', () async {
    final session = await sessionService.getOrCreateMain();
    await messageService.insertMessage(
      sessionId: session.id,
      role: 'assistant',
      content:
          'Done.\n\n<workflow-context>{"prd":"PRD text","stories":{"items":[{"id":"S01"}]}}</workflow-context>',
    );
    await messageService.insertMessage(
      sessionId: session.id,
      role: 'assistant',
      content: '{"stories":{"items":[{"id":"S01"}]}}',
    );

    await taskService.create(
      id: 'task-workflow-context-history',
      title: 'Test',
      description: 'Test',
      type: TaskType.research,
      autoStart: true,
    );
    await taskService.updateFields('task-workflow-context-history', sessionId: session.id);
    final taskWithSession = (await taskService.get('task-workflow-context-history'))!;

    final step = makeStep(
      contextOutputs: ['prd', 'stories'],
      outputs: const {
        'stories': OutputConfig(format: OutputFormat.json, schema: 'story-plan'),
      },
    );
    final outputs = await extractor.extract(step, taskWithSession);

    expect(outputs['prd'], equals('PRD text'));
    expect(outputs['stories'], isA<Map<Object?, Object?>>());
    expect(((outputs['stories'] as Map<Object?, Object?>)['items'] as List<Object?>), hasLength(1));
  });

  test('format-aware json output stores parsed list from last assistant message', () async {
    final session = await sessionService.getOrCreateMain();
    await messageService.insertMessage(
      sessionId: session.id,
      role: 'assistant',
      content: '[{"id":"s01"},{"id":"s02"}]',
    );

    await taskService.create(
      id: 'task-json-list-1',
      title: 'Test',
      description: 'Test',
      type: TaskType.research,
      autoStart: true,
    );
    await taskService.updateFields('task-json-list-1', sessionId: session.id);
    final taskWithSession = (await taskService.get('task-json-list-1'))!;

    final step = makeStep(
      contextOutputs: ['result'],
      outputs: {'result': const OutputConfig(format: OutputFormat.json)},
    );

    final outputs = await extractor.extract(step, taskWithSession);
    final result = outputs['result'] as List<Object?>;

    expect(result, hasLength(2));
    expect((result.first as Map<String, dynamic>)['id'], equals('s01'));
    expect((result.last as Map<String, dynamic>)['id'], equals('s02'));
  });

  test('format-aware lines output stores trimmed non-empty lines', () async {
    final session = await sessionService.getOrCreateMain();
    await messageService.insertMessage(sessionId: session.id, role: 'assistant', content: 'alpha\n  beta  \n\n gamma ');

    await taskService.create(
      id: 'task-lines-1',
      title: 'Test',
      description: 'Test',
      type: TaskType.research,
      autoStart: true,
    );
    await taskService.updateFields('task-lines-1', sessionId: session.id);
    final taskWithSession = (await taskService.get('task-lines-1'))!;

    final step = makeStep(
      contextOutputs: ['result'],
      outputs: {'result': const OutputConfig(format: OutputFormat.lines)},
    );

    final outputs = await extractor.extract(step, taskWithSession);
    expect(outputs['result'], equals(['alpha', 'beta', 'gamma']));
  });

  test('schema preset warnings stay soft for format-aware json extraction', () async {
    final previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final records = <LogRecord>[];
    final sub = Logger('ContextExtractor').onRecord.listen(records.add);
    addTearDown(() async {
      Logger.root.level = previousLevel;
      await sub.cancel();
    });

    final session = await sessionService.getOrCreateMain();
    await messageService.insertMessage(sessionId: session.id, role: 'assistant', content: '{"summary":"Only summary"}');

    await taskService.create(
      id: 'task-schema-1',
      title: 'Test',
      description: 'Test',
      type: TaskType.research,
      autoStart: true,
    );
    await taskService.updateFields('task-schema-1', sessionId: session.id);
    final taskWithSession = (await taskService.get('task-schema-1'))!;

    final step = makeStep(
      contextOutputs: ['result'],
      outputs: {'result': const OutputConfig(format: OutputFormat.json, schema: 'verdict')},
    );

    final outputs = await extractor.extract(step, taskWithSession);
    final result = outputs['result'] as Map<String, dynamic>;

    expect(result['summary'], equals('Only summary'));
    expect(
      records.any(
        (record) =>
            record.level == Level.WARNING &&
            record.message.contains('Schema validation for "result"') &&
            record.message.contains('"pass"'),
      ),
      isTrue,
    );
  });

  test('extracts diff.json artifact for diff-related key', () async {
    final task = await createTask();
    final artifactsDir = Directory(p.join(tempDir.path, 'tasks', 'task-1', 'artifacts'));
    artifactsDir.createSync(recursive: true);
    final diffFile = File(p.join(artifactsDir.path, 'diff.json'));
    diffFile.writeAsStringSync(jsonEncode({'files': 3, 'additions': 45, 'deletions': 12}));

    await taskService.addArtifact(
      id: 'diff-artifact-1',
      taskId: 'task-1',
      name: 'diff.json',
      kind: ArtifactKind.data,
      path: p.join(artifactsDir.path, 'diff.json'),
    );

    final step = makeStep(contextOutputs: ['diff_summary']);
    final outputs = await extractor.extract(step, task);
    expect(outputs['diff_summary'], contains('3 files changed'));
    expect(outputs['diff_summary'], contains('+45'));
    expect(outputs['diff_summary'], contains('-12'));
  });

  test('ExtractionConfig with artifact type finds named artifact', () async {
    final task = await createTask();
    final artifactsDir = Directory(p.join(tempDir.path, 'tasks', 'task-1', 'artifacts'));
    artifactsDir.createSync(recursive: true);
    final reportFile = File(p.join(artifactsDir.path, 'special-report.md'));
    reportFile.writeAsStringSync('Special report content here.');

    await taskService.addArtifact(
      id: 'special-artifact-1',
      taskId: 'task-1',
      name: 'special-report.md',
      kind: ArtifactKind.document,
      path: p.join(artifactsDir.path, 'special-report.md'),
    );

    final step = makeStep(
      contextOutputs: ['report'],
      extraction: const ExtractionConfig(type: ExtractionType.artifact, pattern: 'special-report'),
    );
    final outputs = await extractor.extract(step, task);
    expect(outputs['report'], equals('Special report content here.'));
  });

  test('ExtractionConfig with regex type logs warning and falls back', () async {
    final task = await createTask();
    final step = makeStep(
      contextOutputs: ['result'],
      extraction: const ExtractionConfig(type: ExtractionType.regex, pattern: r'\d+'),
    );
    // Should not throw — falls back to empty string.
    final outputs = await extractor.extract(step, task);
    expect(outputs['result'], equals(''));
  });

  test('large content value (>10K chars) is returned without truncation', () async {
    final task = await createTask();
    final artifactsDir = Directory(p.join(tempDir.path, 'tasks', 'task-1', 'artifacts'));
    artifactsDir.createSync(recursive: true);
    final largeContent = 'x' * 15000;
    final mdFile = File(p.join(artifactsDir.path, 'large.md'));
    mdFile.writeAsStringSync(largeContent);

    await taskService.addArtifact(
      id: 'large-artifact-1',
      taskId: 'task-1',
      name: 'large.md',
      kind: ArtifactKind.document,
      path: mdFile.path,
    );

    final step = makeStep(contextOutputs: ['large_output']);
    final outputs = await extractor.extract(step, task);
    // Content should not be truncated — only a warning is logged.
    expect(outputs['large_output'], equals(largeContent));
  });

  test('multiple output keys: diff key extracts diff.json, plain key falls back to empty', () async {
    final task = await createTask();
    final artifactsDir = Directory(p.join(tempDir.path, 'tasks', 'task-1', 'artifacts'));
    artifactsDir.createSync(recursive: true);
    // Only diff.json — diff_changes key uses it; notes has no match.
    final diffFile = File(p.join(artifactsDir.path, 'diff.json'));
    diffFile.writeAsStringSync(jsonEncode({'files': 1, 'additions': 5, 'deletions': 2}));

    await taskService.addArtifact(
      id: 'a2',
      taskId: 'task-1',
      name: 'diff.json',
      kind: ArtifactKind.data,
      path: diffFile.path,
    );

    final step = makeStep(contextOutputs: ['notes', 'diff_changes']);
    final outputs = await extractor.extract(step, task);
    expect(outputs['notes'], equals(''));
    expect(outputs['diff_changes'], contains('1 files changed'));
  });

  test('structured output mode reads provider payload from task config', () async {
    await agentExecutions.create(const AgentExecution(id: 'ae-task-structured-config'));
    await taskService.create(
      id: 'task-structured-config',
      title: 'Test',
      description: 'Test',
      type: TaskType.research,
      autoStart: true,
      agentExecutionId: 'ae-task-structured-config',
      workflowRunId: 'wf-structured-config',
    );
    await workflowStepExecutions.create(
      const WorkflowStepExecution(
        taskId: 'task-structured-config',
        agentExecutionId: 'ae-task-structured-config',
        workflowRunId: 'wf-structured-config',
        stepIndex: 0,
        stepId: 'step1',
        structuredOutputJson:
            '{"verdict":{"pass":true,"findings_count":0,"findings":[],"summary":"Clean"}}',
      ),
    );
    final task = (await taskService.get('task-structured-config'))!;

    final step = makeStep(
      contextOutputs: ['verdict'],
      outputs: const {
        'verdict': OutputConfig(format: OutputFormat.json, outputMode: OutputMode.structured, schema: 'verdict'),
      },
    );
    final outputs = await extractor.extract(step, task);

    expect(outputs['verdict'], isA<Map<Object?, Object?>>());
    expect((outputs['verdict'] as Map<Object?, Object?>)['pass'], isTrue);
  });

  test('structured output mode records fallback and uses heuristic json when payload is missing', () async {
    final session = await sessionService.getOrCreateMain();
    await messageService.insertMessage(
      sessionId: session.id,
      role: 'assistant',
      content: '{"verdict":{"pass":true,"findings_count":0,"findings":[],"summary":"Clean"}}',
    );

    await taskService.create(
      id: 'task-structured-fallback',
      title: 'Test',
      description: 'Test',
      type: TaskType.research,
      autoStart: true,
    );
    await taskService.updateFields('task-structured-fallback', sessionId: session.id);
    final task = (await taskService.get('task-structured-fallback'))!;

    final fallbackCalls = <Map<String, Object?>>[];
    final localExtractor = ContextExtractor(
      taskService: taskService,
      messageService: messageService,
      dataDir: tempDir.path,
      structuredOutputFallbackRecorder:
          (taskId, {required stepId, required outputKey, required failureReason, String? providerSubtype}) {
            fallbackCalls.add({
              'taskId': taskId,
              'stepId': stepId,
              'outputKey': outputKey,
              'failureReason': failureReason,
              'providerSubtype': providerSubtype,
            });
          },
    );

    final step = makeStep(
      contextOutputs: ['verdict'],
      outputs: const {
        'verdict': OutputConfig(format: OutputFormat.json, outputMode: OutputMode.structured, schema: 'verdict'),
      },
    );
    final outputs = await localExtractor.extract(step, task);

    expect(outputs['verdict'], isA<Map<Object?, Object?>>());
    expect((outputs['verdict'] as Map<Object?, Object?>)['pass'], isTrue);
    expect(fallbackCalls, [
      {
        'taskId': 'task-structured-fallback',
        'stepId': 'step1',
        'outputKey': 'verdict',
        'failureReason': 'missing_payload',
        'providerSubtype': null,
      },
    ]);
  });

  test('derived outputs reuse fields from an earlier parsed JSON output', () async {
    final session = await sessionService.getOrCreateMain();
    await taskService.create(
      id: 'task-session-json',
      title: 'Test',
      description: 'Test',
      type: TaskType.research,
      autoStart: true,
    );
    await taskService.updateFields('task-session-json', sessionId: session.id);
    final task = (await taskService.get('task-session-json'))!;
    await messageService.insertMessage(
      sessionId: session.id,
      role: 'assistant',
      content: jsonEncode({
        'pass': false,
        'findings_count': 2,
        'findings': [
          {'severity': 'high', 'location': 'lib/a.dart:10', 'description': 'Issue A'},
          {'severity': 'low', 'location': 'lib/b.dart:12', 'description': 'Issue B'},
        ],
        'summary': 'Two findings remain.',
      }),
    );

    final step = makeStep(
      contextOutputs: ['review_summary', 'findings_count'],
      outputs: const {'review_summary': OutputConfig(format: OutputFormat.json, schema: 'verdict')},
    );

    final outputs = await extractor.extract(step, task);
    expect(outputs['review_summary'], isA<Map<String, dynamic>>());
    expect((outputs['review_summary'] as Map<String, dynamic>)['findings_count'], 2);
    expect(outputs['findings_count'], 2);
  });

  group('S04 (0.16.1): worktree source outputs', () {
    test('source: worktree.branch extracts branch from task.worktreeJson', () async {
      final task = await taskService.create(
        id: 'task-wt1',
        title: 'Coding task',
        description: 'Fix bug',
        type: TaskType.coding,
        autoStart: true,
      );
      await taskService.updateFields(
        task.id,
        worktreeJson: {
          'branch': 'feat/fix-bug-123',
          'path': '/worktrees/fix-bug-123',
          'createdAt': '2026-01-01T00:00:00.000Z',
        },
      );
      final updatedTask = await taskService.get(task.id);

      final step = WorkflowStep(
        id: 'coding-step',
        name: 'Fix',
        type: 'coding',
        prompts: const ['Fix the bug'],
        contextOutputs: const ['branch'],
        outputs: const {'branch': OutputConfig(source: 'worktree.branch')},
      );

      final outputs = await extractor.extract(step, updatedTask!);
      expect(outputs['branch'], equals('feat/fix-bug-123'));
    });

    test('source: worktree.path extracts path from task.worktreeJson', () async {
      final task = await taskService.create(
        id: 'task-wt2',
        title: 'Coding task',
        description: 'Fix bug',
        type: TaskType.coding,
        autoStart: true,
      );
      await taskService.updateFields(
        task.id,
        worktreeJson: {
          'branch': 'feat/fix-bug',
          'path': '/opt/worktrees/fix-bug',
          'createdAt': '2026-01-01T00:00:00.000Z',
        },
      );
      final updatedTask = await taskService.get(task.id);

      final step = WorkflowStep(
        id: 'coding-step',
        name: 'Fix',
        type: 'coding',
        prompts: const ['Fix the bug'],
        contextOutputs: const ['worktree_path'],
        outputs: const {'worktree_path': OutputConfig(source: 'worktree.path')},
      );

      final outputs = await extractor.extract(step, updatedTask!);
      expect(outputs['worktree_path'], equals('/opt/worktrees/fix-bug'));
    });

    test('source: worktree.branch returns empty string when task has no worktreeJson', () async {
      final task = await taskService.create(
        id: 'task-wt3',
        title: 'Coding task',
        description: 'Fix bug',
        type: TaskType.coding,
        autoStart: true,
      );

      final step = WorkflowStep(
        id: 'coding-step',
        name: 'Fix',
        type: 'coding',
        prompts: const ['Fix the bug'],
        contextOutputs: const ['branch'],
        outputs: const {'branch': OutputConfig(source: 'worktree.branch')},
      );

      final outputs = await extractor.extract(step, task);
      expect(outputs['branch'], equals(''));
    });
  });
}
