import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' hide TurnManager, TurnRunner;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String sessionsDir;
  late String workspaceDir;
  late SessionService sessions;
  late TaskService tasks;
  late ArtifactCollector collector;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_artifact_collector_test_');
    sessionsDir = p.join(tempDir.path, 'sessions');
    workspaceDir = Directory.systemTemp.createTempSync('dartclaw_artifact_workspace_').path;
    Directory(sessionsDir).createSync(recursive: true);
    sessions = SessionService(baseDir: sessionsDir);
    tasks = TaskService(SqliteTaskRepository(sqlite3.openInMemory()));
    collector = ArtifactCollector(tasks: tasks, sessionsDir: sessionsDir, dataDir: tempDir.path);
  });

  tearDown(() async {
    await tasks.dispose();
    final wsDir = Directory(workspaceDir);
    if (wsDir.existsSync()) wsDir.deleteSync(recursive: true);
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('collects every file modified after task start with inferred kinds', () async {
    final startedAt = DateTime.parse('2026-03-10T10:00:00Z');
    final session = await sessions.createSession(type: SessionType.task);
    final task = await _createTask(tasks, id: 'task-1', sessionId: session.id, startedAt: startedAt);

    final reportFile = File(p.join(workspaceDir, 'notes', 'report.md'))..createSync(recursive: true);
    await reportFile.writeAsString('# Findings');
    await reportFile.setLastModified(startedAt.add(const Duration(seconds: 1)));
    final dataFile = File(p.join(workspaceDir, 'result.csv'))..writeAsStringSync('a,b');
    await dataFile.setLastModified(startedAt.add(const Duration(seconds: 1)));

    final oldFile = File(p.join(workspaceDir, 'README.md'));
    await oldFile.writeAsString('# Existing');
    await oldFile.setLastModified(startedAt.subtract(const Duration(days: 1)));

    await File(p.join(sessionsDir, session.id, 'meta.json')).writeAsString('{}');
    await File(p.join(sessionsDir, session.id, 'messages.ndjson')).writeAsString('');

    final artifacts = await collector.collect(task, executionDirectory: workspaceDir);

    expect(artifacts.map((artifact) => artifact.name), unorderedEquals(['notes/report.md', 'result.csv']));
    expect(
      {for (final artifact in artifacts) artifact.name: artifact.kind},
      {'notes/report.md': ArtifactKind.document, 'result.csv': ArtifactKind.data},
    );
  });

  test('artifactExtensions narrows non-worktree collection', () async {
    final startedAt = DateTime.parse('2026-03-10T10:00:00Z');
    final session = await sessions.createSession(type: SessionType.task);
    final task = await _createTask(
      tasks,
      id: 'task-2',
      sessionId: session.id,
      startedAt: startedAt,
      configJson: const {
        'artifactExtensions': ['.md'],
      },
    );

    final resultFile = File(p.join(workspaceDir, 'result.json'))..writeAsStringSync('{"ok":true}');
    await resultFile.setLastModified(startedAt.add(const Duration(seconds: 1)));
    final tableFile = File(p.join(workspaceDir, 'table.csv'))..writeAsStringSync('a,b');
    await tableFile.setLastModified(startedAt.add(const Duration(seconds: 1)));
    final markdownFile = File(p.join(workspaceDir, 'notes.md'))..writeAsStringSync('# Ignore');
    await markdownFile.setLastModified(startedAt.add(const Duration(seconds: 1)));

    final artifacts = await collector.collect(task, executionDirectory: workspaceDir);

    expect(artifacts.map((artifact) => artifact.name), ['notes.md']);
    expect(artifacts.single.kind, ArtifactKind.document);
  });

  test('non-worktree tasks collect produced files rather than a transcript summary', () async {
    final startedAt = DateTime.parse('2026-03-10T10:00:00Z');
    final session = await sessions.createSession(type: SessionType.task);
    final task = await _createTask(tasks, id: 'task-3', sessionId: session.id, startedAt: startedAt);
    final output = File(p.join(workspaceDir, 'automation.json'))..writeAsStringSync('{"ok":true}');
    await output.setLastModified(startedAt.add(const Duration(seconds: 1)));

    final artifacts = await collector.collect(task, executionDirectory: workspaceDir);

    expect(artifacts, hasLength(1));
    expect(artifacts.single.name, 'automation.json');
    expect(artifacts.single.kind, ArtifactKind.data);
    expect(File(p.join(tempDir.path, 'tasks', task.id, 'artifacts', 'transcript.md')).existsSync(), isFalse);
  });

  test('non-worktree collection excludes files older than task start', () async {
    final startedAt = DateTime.parse('2026-03-10T10:00:00Z');
    final session = await sessions.createSession(type: SessionType.task);
    final task = await _createTask(tasks, id: 'task-4', sessionId: session.id, startedAt: startedAt);

    final notesFile = File(p.join(workspaceDir, 'notes.md'))..writeAsStringSync('# Notes');
    await notesFile.setLastModified(startedAt.add(const Duration(seconds: 1)));
    final resultFile = File(p.join(workspaceDir, 'result.json'))..writeAsStringSync('{"score":1}');
    await resultFile.setLastModified(startedAt.add(const Duration(seconds: 1)));
    final diffFile = File(p.join(workspaceDir, 'changes.diff'))..writeAsStringSync('diff --git');
    await diffFile.setLastModified(startedAt.add(const Duration(seconds: 1)));
    final existingFile = File(p.join(workspaceDir, 'preexisting.txt'))..writeAsStringSync('existing');
    await existingFile.setLastModified(startedAt.subtract(const Duration(days: 1)));
    File(p.join(sessionsDir, session.id, 'messages.ndjson')).writeAsStringSync('internal');

    final artifacts = await collector.collect(task, executionDirectory: workspaceDir);

    expect(artifacts.map((artifact) => artifact.name), unorderedEquals(['notes.md', 'result.json', 'changes.diff']));
    expect(
      {for (final artifact in artifacts) artifact.name: artifact.kind},
      {'notes.md': ArtifactKind.document, 'result.json': ArtifactKind.data, 'changes.diff': ArtifactKind.diff},
    );
  });

  test('worktree-backed task without DiffGenerator returns empty', () async {
    final startedAt = DateTime.parse('2026-03-10T10:00:00Z');
    final session = await sessions.createSession(type: SessionType.task);

    final task = await _createTask(tasks, id: 'task-5', sessionId: session.id, startedAt: startedAt);
    final taskWithWorktree = await tasks.updateFields(
      task.id,
      worktreeJson: const {
        'path': '/tmp/worktree-no-diff',
        'branch': 'dartclaw/task-5',
        'createdAt': '2026-03-10T10:00:00.000Z',
      },
    );

    final artifacts = await collector.collect(taskWithWorktree, executionDirectory: workspaceDir);

    expect(artifacts, isEmpty);
    expect(await tasks.listArtifacts(task.id), isEmpty);
  });

  test('task without worktreeJson uses workspace collection even when a diff generator exists', () async {
    final startedAt = DateTime.parse('2026-03-10T10:00:00Z');
    final session = await sessions.createSession(type: SessionType.task);

    final mockDiffGen = _MockDiffGenerator();
    final collectorWithDiff = ArtifactCollector(
      tasks: tasks,
      sessionsDir: sessionsDir,
      dataDir: tempDir.path,
      diffGenerator: mockDiffGen,
      baseRef: 'main',
    );

    final task = await _createTask(tasks, id: 'task-6', sessionId: session.id, startedAt: startedAt);
    final output = File(p.join(workspaceDir, 'result.txt'))..writeAsStringSync('done');
    await output.setLastModified(startedAt.add(const Duration(seconds: 1)));

    final artifacts = await collectorWithDiff.collect(task, executionDirectory: workspaceDir);

    expect(artifacts.single.name, 'result.txt');
    expect(mockDiffGen.lastBranch, isNull);
  });

  test('task with DiffGenerator and worktreeJson produces diff artifact', () async {
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
      sessionsDir: sessionsDir,
      dataDir: tempDir.path,
      diffGenerator: mockDiffGen,
      baseRef: 'main',
    );

    var task = await _createTask(tasks, id: 'task-7', sessionId: session.id, startedAt: startedAt);
    task = await tasks.updateFields(
      task.id,
      worktreeJson: const {
        'path': '/tmp/worktree',
        'branch': 'dartclaw/task-7',
        'createdAt': '2026-03-10T10:00:00.000Z',
      },
    );

    final artifacts = await collectorWithDiff.collect(task, executionDirectory: workspaceDir);

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

  test('worktree-backed task with DiffGenerator failure returns empty gracefully', () async {
    final startedAt = DateTime.parse('2026-03-10T10:00:00Z');
    final session = await sessions.createSession(type: SessionType.task);

    final mockDiffGen = _MockDiffGenerator(shouldThrow: true);

    final collectorWithDiff = ArtifactCollector(
      tasks: tasks,
      sessionsDir: sessionsDir,
      dataDir: tempDir.path,
      diffGenerator: mockDiffGen,
      baseRef: 'main',
    );

    var task = await _createTask(tasks, id: 'task-8', sessionId: session.id, startedAt: startedAt);
    task = await tasks.updateFields(
      task.id,
      worktreeJson: const {
        'path': '/tmp/worktree',
        'branch': 'dartclaw/task-8',
        'createdAt': '2026-03-10T10:00:00.000Z',
      },
    );

    final artifacts = await collectorWithDiff.collect(task, executionDirectory: workspaceDir);

    expect(artifacts, isEmpty);
  });

  test('project-backed worktree task diffs against the selected project clone', () async {
    final startedAt = DateTime.parse('2026-03-10T10:00:00Z');
    final session = await sessions.createSession(type: SessionType.task);

    final mockDiffGen = _MockDiffGenerator(
      result: DiffResult(files: const [], totalAdditions: 0, totalDeletions: 0, filesChanged: 0),
    );
    final project = Project(
      id: 'my-app',
      name: 'My App',
      remoteUrl: 'git@github.com:acme/my-app.git',
      localPath: '/projects/my-app',
      defaultBranch: 'develop',
      status: ProjectStatus.ready,
      createdAt: startedAt,
    );
    final collectorWithProject = ArtifactCollector(
      tasks: tasks,
      sessionsDir: sessionsDir,
      dataDir: tempDir.path,
      diffGenerator: mockDiffGen,
      projectService: FakeProjectService(
        projects: [project],
        includeLocalProjectInGetAll: false,
        defaultProjectId: project.id,
      ),
      baseRef: 'main',
    );

    var task = await _createTask(tasks, id: 'task-project-diff', sessionId: session.id, startedAt: startedAt);
    task = await tasks.updateFields(
      task.id,
      projectId: 'my-app',
      worktreeJson: const {
        'path': '/tmp/worktree-project',
        'branch': 'dartclaw/task-project-diff',
        'createdAt': '2026-03-10T10:00:00.000Z',
      },
    );

    final artifacts = await collectorWithProject.collect(task, executionDirectory: workspaceDir);

    expect(artifacts, hasLength(1));
    expect(mockDiffGen.lastBaseRef, 'origin/develop');
    expect(mockDiffGen.lastBranch, 'dartclaw/task-project-diff');
    expect(mockDiffGen.lastProjectDir, '/tmp/worktree-project');
  });

  test('local workflow-owned worktree task diffs against the local workflow branch', () async {
    final startedAt = DateTime.parse('2026-03-10T10:00:00Z');
    final session = await sessions.createSession(type: SessionType.task);

    final mockDiffGen = _MockDiffGenerator(
      result: DiffResult(files: const [], totalAdditions: 0, totalDeletions: 0, filesChanged: 0),
    );
    final project = Project(
      id: 'my-app',
      name: 'My App',
      remoteUrl: '',
      localPath: '/projects/my-app',
      defaultBranch: '',
      status: ProjectStatus.ready,
      createdAt: startedAt,
    );
    final collectorWithProject = ArtifactCollector(
      tasks: tasks,
      sessionsDir: sessionsDir,
      dataDir: tempDir.path,
      diffGenerator: mockDiffGen,
      projectService: FakeProjectService(
        projects: [project],
        includeLocalProjectInGetAll: false,
        defaultProjectId: project.id,
      ),
      baseRef: 'main',
    );

    var task = await _createTask(tasks, id: 'task-project-workflow-ref', sessionId: session.id, startedAt: startedAt);
    task = await tasks.updateFields(
      task.id,
      projectId: 'my-app',
      configJson: const {'_baseRef': 'dartclaw/workflow/run123'},
      worktreeJson: const {
        'path': '/tmp/worktree-project',
        'branch': 'dartclaw/workflow/run123',
        'createdAt': '2026-03-10T10:00:00.000Z',
      },
    );

    final artifacts = await collectorWithProject.collect(task, executionDirectory: workspaceDir);

    expect(artifacts, hasLength(1));
    expect(mockDiffGen.lastBaseRef, 'dartclaw/workflow/run123');
    expect(mockDiffGen.lastBranch, 'dartclaw/workflow/run123');
    expect(mockDiffGen.lastProjectDir, '/tmp/worktree-project');
  });
}

Future<Task> _createTask(
  TaskService tasks, {
  required String id,
  required String sessionId,
  required DateTime startedAt,
  Map<String, dynamic> configJson = const {},
}) async {
  final effectiveConfig = <String, dynamic>{...configJson};
  await tasks.create(
    id: id,
    title: 'Task $id',
    description: 'Description',
    autoStart: true,
    configJson: effectiveConfig,
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
  String? lastProjectDir;

  new({this.result, this.shouldThrow = false}) : super(projectDir: '/mock');

  @override
  Future<DiffResult> generate({required String baseRef, required String branch, String? projectDir}) async {
    lastBaseRef = baseRef;
    lastBranch = branch;
    lastProjectDir = projectDir;
    if (shouldThrow) {
      throw Exception('Mock diff generation failure');
    }
    return result ?? DiffResult(files: const [], totalAdditions: 0, totalDeletions: 0, filesChanged: 0);
  }
}
