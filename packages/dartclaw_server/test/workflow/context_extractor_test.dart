import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart'
    show
        ArtifactKind,
        ExtractionConfig,
        ExtractionType,
        MessageService,
        OutputConfig,
        OutputFormat,
        SessionService,
        Task,
        TaskType,
        WorkflowStep;
import 'package:dartclaw_server/dartclaw_server.dart' show ContextExtractor, TaskService;
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String sessionsDir;
  late TaskService taskService;
  late MessageService messageService;
  late SessionService sessionService;
  late ContextExtractor extractor;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_ctx_extractor_test_');
    sessionsDir = p.join(tempDir.path, 'sessions');
    Directory(sessionsDir).createSync(recursive: true);

    taskService = TaskService(SqliteTaskRepository(sqlite3.openInMemory()));
    sessionService = SessionService(baseDir: sessionsDir);
    messageService = MessageService(baseDir: sessionsDir);
    extractor = ContextExtractor(taskService: taskService, messageService: messageService, dataDir: tempDir.path);
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

  test('extracts from agent ## Context Output convention (key: value)', () async {
    final session = await sessionService.getOrCreateMain();
    await messageService.insertMessage(sessionId: session.id, role: 'user', content: 'Do some research');
    await messageService.insertMessage(
      sessionId: session.id,
      role: 'assistant',
      content:
          'Here is my response.\n\n## Context Output\nresearch_notes: Found important findings about X.\nsummary: Brief summary here.',
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

  test('extracts from ## Context Output JSON fenced code block', () async {
    final session = await sessionService.getOrCreateMain();
    await messageService.insertMessage(
      sessionId: session.id,
      role: 'assistant',
      content:
          'Done.\n\n## Context Output\n```json\n{"research_notes": "JSON extracted value", "summary": "JSON summary"}\n```',
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
}
