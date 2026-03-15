import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String sessionsDir;
  late String workspaceDir;
  late SessionService sessions;
  late MessageService messages;
  late TaskService tasks;
  late ArtifactCollector collector;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_artifact_collector_test_');
    sessionsDir = p.join(tempDir.path, 'sessions');
    workspaceDir = Directory.systemTemp.createTempSync('dartclaw_artifact_workspace_').path;
    Directory(sessionsDir).createSync(recursive: true);
    sessions = SessionService(baseDir: sessionsDir);
    messages = MessageService(baseDir: sessionsDir);
    tasks = TaskService(SqliteTaskRepository(sqlite3.openInMemory()));
    collector = ArtifactCollector(
      tasks: tasks,
      messages: messages,
      sessionsDir: sessionsDir,
      dataDir: tempDir.path,
      workspaceDir: workspaceDir,
    );
  });

  tearDown(() async {
    await tasks.dispose();
    await messages.dispose();
    final wsDir = Directory(workspaceDir);
    if (wsDir.existsSync()) wsDir.deleteSync(recursive: true);
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('collects markdown artifacts for research tasks', () async {
    final startedAt = DateTime.parse('2026-03-10T10:00:00Z');
    final session = await sessions.createSession(type: SessionType.task);
    final task = await _createTask(
      tasks,
      id: 'task-1',
      type: TaskType.research,
      sessionId: session.id,
      startedAt: startedAt,
    );

    final reportFile = File(p.join(workspaceDir, 'notes', 'report.md'));
    await reportFile.parent.create(recursive: true);
    await reportFile.writeAsString('# Findings');
    await reportFile.setLastModified(startedAt.add(const Duration(seconds: 1)));

    final oldFile = File(p.join(workspaceDir, 'README.md'));
    await oldFile.writeAsString('# Existing');
    await oldFile.setLastModified(startedAt.subtract(const Duration(days: 1)));

    await File(p.join(sessionsDir, session.id, 'meta.json')).writeAsString('{}');
    await File(p.join(sessionsDir, session.id, 'messages.ndjson')).writeAsString('');

    final artifacts = await collector.collect(task);

    expect(artifacts, hasLength(1));
    expect(artifacts.single.name, 'notes/report.md');
    expect(artifacts.single.kind, ArtifactKind.document);
    expect(File(artifacts.single.path).readAsStringSync(), '# Findings');
  });

  test('collects data artifacts for analysis tasks', () async {
    final startedAt = DateTime.parse('2026-03-10T10:00:00Z');
    final session = await sessions.createSession(type: SessionType.task);
    final task = await _createTask(
      tasks,
      id: 'task-2',
      type: TaskType.analysis,
      sessionId: session.id,
      startedAt: startedAt,
    );

    final resultFile = File(p.join(workspaceDir, 'result.json'))..writeAsStringSync('{"ok":true}');
    await resultFile.setLastModified(startedAt.add(const Duration(seconds: 1)));
    final tableFile = File(p.join(workspaceDir, 'table.csv'))..writeAsStringSync('a,b');
    await tableFile.setLastModified(startedAt.add(const Duration(seconds: 1)));
    final markdownFile = File(p.join(workspaceDir, 'notes.md'))..writeAsStringSync('# Ignore');
    await markdownFile.setLastModified(startedAt.add(const Duration(seconds: 1)));

    final artifacts = await collector.collect(task);

    expect(artifacts.map((artifact) => artifact.name), unorderedEquals(['result.json', 'table.csv']));
    expect(artifacts.every((artifact) => artifact.kind == ArtifactKind.data), isTrue);
  });

  test('writes transcript artifact for automation tasks', () async {
    final startedAt = DateTime.parse('2026-03-10T10:00:00Z');
    final session = await sessions.createSession(type: SessionType.task);
    final userContent =
        'Run the workflow and verify every generated report is attached before the task is marked complete.';
    final assistantContent =
        'Workflow completed successfully. Reports were generated, attached, and validated for the review step.';
    await messages.insertMessage(sessionId: session.id, role: 'user', content: userContent);
    await messages.insertMessage(sessionId: session.id, role: 'assistant', content: assistantContent);

    final task = await _createTask(
      tasks,
      id: 'task-3',
      type: TaskType.automation,
      sessionId: session.id,
      startedAt: startedAt,
    );

    final artifacts = await collector.collect(task);

    expect(artifacts, hasLength(1));
    expect(artifacts.single.name, 'transcript.md');
    final transcript = File(artifacts.single.path).readAsStringSync();
    expect(transcript, contains('Task Transcript Summary'));
    expect(transcript, contains('Total messages: 2'));
    expect(transcript, contains('Initial request: $userContent'));
    expect(transcript, contains('Latest assistant output: $assistantContent'));
    expect(transcript, isNot(contains('### User')));
    expect(transcript, isNot(contains('### Assistant')));
  });

  test('collects all non-internal files for custom tasks', () async {
    final startedAt = DateTime.parse('2026-03-10T10:00:00Z');
    final session = await sessions.createSession(type: SessionType.task);
    final task = await _createTask(
      tasks,
      id: 'task-4',
      type: TaskType.custom,
      sessionId: session.id,
      startedAt: startedAt,
    );

    final notesFile = File(p.join(workspaceDir, 'notes.md'))..writeAsStringSync('# Notes');
    await notesFile.setLastModified(startedAt.add(const Duration(seconds: 1)));
    final resultFile = File(p.join(workspaceDir, 'result.json'))..writeAsStringSync('{"score":1}');
    await resultFile.setLastModified(startedAt.add(const Duration(seconds: 1)));
    final diffFile = File(p.join(workspaceDir, 'changes.diff'))..writeAsStringSync('diff --git');
    await diffFile.setLastModified(startedAt.add(const Duration(seconds: 1)));
    final existingFile = File(p.join(workspaceDir, 'preexisting.txt'))..writeAsStringSync('existing');
    await existingFile.setLastModified(startedAt.subtract(const Duration(days: 1)));
    File(p.join(sessionsDir, session.id, 'messages.ndjson')).writeAsStringSync('internal');

    final artifacts = await collector.collect(task);

    expect(
      artifacts.map((artifact) => artifact.name),
      unorderedEquals(['notes.md', 'result.json', 'changes.diff', 'preexisting.txt']),
    );
    expect(
      {for (final artifact in artifacts) artifact.name: artifact.kind},
      {
        'notes.md': ArtifactKind.document,
        'result.json': ArtifactKind.data,
        'changes.diff': ArtifactKind.diff,
        'preexisting.txt': ArtifactKind.data,
      },
    );
  });

  test('coding task without DiffGenerator returns empty', () async {
    final startedAt = DateTime.parse('2026-03-10T10:00:00Z');
    final session = await sessions.createSession(type: SessionType.task);

    final task = await _createTask(
      tasks,
      id: 'task-5',
      type: TaskType.coding,
      sessionId: session.id,
      startedAt: startedAt,
    );

    final artifacts = await collector.collect(task);

    expect(artifacts, isEmpty);
    expect(await tasks.listArtifacts(task.id), isEmpty);
  });

  test('coding task without worktreeJson returns empty', () async {
    final startedAt = DateTime.parse('2026-03-10T10:00:00Z');
    final session = await sessions.createSession(type: SessionType.task);

    final mockDiffGen = _MockDiffGenerator();
    final collectorWithDiff = ArtifactCollector(
      tasks: tasks,
      messages: messages,
      sessionsDir: sessionsDir,
      dataDir: tempDir.path,
      workspaceDir: workspaceDir,
      diffGenerator: mockDiffGen,
      baseRef: 'main',
    );

    final task = await _createTask(
      tasks,
      id: 'task-6',
      type: TaskType.coding,
      sessionId: session.id,
      startedAt: startedAt,
    );
    // No worktreeJson set on this task

    final artifacts = await collectorWithDiff.collect(task);

    expect(artifacts, isEmpty);
  });

  test('coding task with DiffGenerator and worktreeJson produces diff artifact', () async {
    final startedAt = DateTime.parse('2026-03-10T10:00:00Z');
    final session = await sessions.createSession(type: SessionType.task);

    final mockDiffGen = _MockDiffGenerator(
      result: DiffResult(
        files: [
          DiffFileEntry(
            path: 'lib/main.dart',
            status: DiffFileStatus.modified,
            additions: 5,
            deletions: 2,
            hunks: const [],
          ),
        ],
        totalAdditions: 5,
        totalDeletions: 2,
        filesChanged: 1,
      ),
    );

    final collectorWithDiff = ArtifactCollector(
      tasks: tasks,
      messages: messages,
      sessionsDir: sessionsDir,
      dataDir: tempDir.path,
      workspaceDir: workspaceDir,
      diffGenerator: mockDiffGen,
      baseRef: 'main',
    );

    var task = await _createTask(
      tasks,
      id: 'task-7',
      type: TaskType.coding,
      sessionId: session.id,
      startedAt: startedAt,
    );
    task = await tasks.updateFields(
      task.id,
      worktreeJson: const {
        'path': '/tmp/worktree',
        'branch': 'dartclaw/task-7',
        'createdAt': '2026-03-10T10:00:00.000Z',
      },
    );

    final artifacts = await collectorWithDiff.collect(task);

    expect(artifacts, hasLength(1));
    expect(artifacts.single.name, 'diff.json');
    expect(artifacts.single.kind, ArtifactKind.diff);

    // Verify the diff.json file was written with correct content
    final diffContent = File(artifacts.single.path).readAsStringSync();
    final diffJson = jsonDecode(diffContent) as Map<String, dynamic>;
    expect(diffJson['filesChanged'], 1);
    expect(diffJson['totalAdditions'], 5);
    expect(diffJson['totalDeletions'], 2);

    // Verify DiffGenerator was called with correct args
    expect(mockDiffGen.lastBaseRef, 'main');
    expect(mockDiffGen.lastBranch, 'dartclaw/task-7');
  });

  test('coding task with DiffGenerator failure returns empty gracefully', () async {
    final startedAt = DateTime.parse('2026-03-10T10:00:00Z');
    final session = await sessions.createSession(type: SessionType.task);

    final mockDiffGen = _MockDiffGenerator(shouldThrow: true);

    final collectorWithDiff = ArtifactCollector(
      tasks: tasks,
      messages: messages,
      sessionsDir: sessionsDir,
      dataDir: tempDir.path,
      workspaceDir: workspaceDir,
      diffGenerator: mockDiffGen,
      baseRef: 'main',
    );

    var task = await _createTask(
      tasks,
      id: 'task-8',
      type: TaskType.coding,
      sessionId: session.id,
      startedAt: startedAt,
    );
    task = await tasks.updateFields(
      task.id,
      worktreeJson: const {
        'path': '/tmp/worktree',
        'branch': 'dartclaw/task-8',
        'createdAt': '2026-03-10T10:00:00.000Z',
      },
    );

    final artifacts = await collectorWithDiff.collect(task);

    expect(artifacts, isEmpty);
  });
}

Future<Task> _createTask(
  TaskService tasks, {
  required String id,
  required TaskType type,
  required String sessionId,
  required DateTime startedAt,
}) async {
  await tasks.create(
    id: id,
    title: 'Task $id',
    description: 'Description',
    type: type,
    autoStart: true,
    now: startedAt,
  );
  await tasks.transition(id, TaskStatus.running, now: startedAt);
  return tasks.updateFields(id, sessionId: sessionId);
}

class _MockDiffGenerator extends DiffGenerator {
  final DiffResult? result;
  final bool shouldThrow;
  String? lastBaseRef;
  String? lastBranch;

  _MockDiffGenerator({this.result, this.shouldThrow = false}) : super(projectDir: '/mock');

  @override
  Future<DiffResult> generate({required String baseRef, required String branch}) async {
    lastBaseRef = baseRef;
    lastBranch = branch;
    if (shouldThrow) {
      throw Exception('Mock diff generation failure');
    }
    return result ?? DiffResult(files: const [], totalAdditions: 0, totalDeletions: 0, filesChanged: 0);
  }
}
