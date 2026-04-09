import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/// Fake harness that resolves immediately with configurable token counts.
class _FakeHarness implements AgentHarness {
  final _eventsCtrl = StreamController<BridgeEvent>.broadcast();

  String responseText = 'Done.';
  bool shouldFail = false;

  @override
  bool get supportsCostReporting => false;
  @override
  bool get supportsToolApproval => true;
  @override
  bool get supportsStreaming => true;
  @override
  bool get supportsCachedTokens => false;

  @override
  bool get supportsSessionContinuity => false;

  @override
  bool get supportsPreCompactHook => false;
  @override
  PromptStrategy get promptStrategy => PromptStrategy.replace;
  @override
  WorkerState get state => WorkerState.idle;
  @override
  Stream<BridgeEvent> get events => _eventsCtrl.stream;
  @override
  Future<void> start() async {}
  @override
  Future<void> cancel() async {}
  @override
  Future<void> stop() async {}

  @override
  Future<Map<String, dynamic>> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    Map<String, dynamic>? mcpServers,
    bool resume = false,
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
  }) async {
    if (shouldFail) throw StateError('simulated failure');
    if (responseText.isNotEmpty) {
      _eventsCtrl.add(DeltaEvent(responseText));
    }
    return <String, dynamic>{'input_tokens': 10, 'output_tokens': 5};
  }

  @override
  Future<void> dispose() async {
    if (!_eventsCtrl.isClosed) await _eventsCtrl.close();
  }
}


void main() {
  late Directory tempDir;
  late String sessionsDir;
  late String workspaceDir;
  late SessionService sessions;
  late MessageService messages;
  late TaskService tasks;
  late _FakeHarness worker;
  late TurnManager turns;
  late ArtifactCollector collector;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('dartclaw_task_autonomy_test_');
    sessionsDir = p.join(tempDir.path, 'sessions');
    workspaceDir = Directory.systemTemp.createTempSync('dartclaw_task_autonomy_ws_').path;
    Directory(sessionsDir).createSync(recursive: true);

    sessions = SessionService(baseDir: sessionsDir);
    messages = MessageService(baseDir: sessionsDir);
    tasks = TaskService(SqliteTaskRepository(sqlite3.openInMemory()));
    worker = _FakeHarness();
    turns = TurnManager(
      messages: messages,
      worker: worker,
      behavior: BehaviorFileService(workspaceDir: workspaceDir),
      sessions: sessions,
    );
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
    await worker.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    final wsDir = Directory(workspaceDir);
    if (wsDir.existsSync()) wsDir.deleteSync(recursive: true);
  });

  // ---------------------------------------------------------------------------
  // Review mode enforcement
  // ---------------------------------------------------------------------------

  group('reviewMode enforcement', () {
    test('null reviewMode — all task types go to review (current default)', () async {
      final executor = TaskExecutor(
        tasks: tasks,
        sessions: sessions,
        messages: messages,
        turns: turns,
        artifactCollector: collector,
        pollInterval: const Duration(milliseconds: 10),
      );
      addTearDown(executor.stop);

      await tasks.create(
        id: 'task-default',
        title: 'Default review',
        description: 'No reviewMode set.',
        type: TaskType.research,
        autoStart: true,
      );

      await executor.pollOnce();

      expect((await tasks.get('task-default'))!.status, TaskStatus.review);
    });

    test('mandatory — research task goes to review', () async {
      final executor = TaskExecutor(
        tasks: tasks,
        sessions: sessions,
        messages: messages,
        turns: turns,
        artifactCollector: collector,
        pollInterval: const Duration(milliseconds: 10),
      );
      addTearDown(executor.stop);

      await tasks.create(
        id: 'task-mandatory',
        title: 'Mandatory review',
        description: 'reviewMode = mandatory.',
        type: TaskType.research,
        autoStart: true,
        configJson: const {'reviewMode': 'mandatory'},
      );

      await executor.pollOnce();

      expect((await tasks.get('task-mandatory'))!.status, TaskStatus.review);
    });

    test('auto-accept — task transitions directly to accepted', () async {
      final executor = TaskExecutor(
        tasks: tasks,
        sessions: sessions,
        messages: messages,
        turns: turns,
        artifactCollector: collector,
        pollInterval: const Duration(milliseconds: 10),
      );
      addTearDown(executor.stop);

      await tasks.create(
        id: 'task-auto-accept',
        title: 'Auto-accept task',
        description: 'Should skip review.',
        type: TaskType.research,
        autoStart: true,
        configJson: const {'reviewMode': 'auto-accept'},
      );

      await executor.pollOnce();

      expect((await tasks.get('task-auto-accept'))!.status, TaskStatus.accepted);
    });

    test('coding-only + coding task — goes to review', () async {
      final executor = TaskExecutor(
        tasks: tasks,
        sessions: sessions,
        messages: messages,
        turns: turns,
        artifactCollector: collector,
        pollInterval: const Duration(milliseconds: 10),
      );
      addTearDown(executor.stop);

      await tasks.create(
        id: 'task-coding-review',
        title: 'Coding review',
        description: 'coding-only, coding type.',
        type: TaskType.coding,
        autoStart: true,
        configJson: const {'reviewMode': 'coding-only'},
      );

      await executor.pollOnce();

      expect((await tasks.get('task-coding-review'))!.status, TaskStatus.review);
    });

    test('coding-only + research task — goes to accepted', () async {
      final executor = TaskExecutor(
        tasks: tasks,
        sessions: sessions,
        messages: messages,
        turns: turns,
        artifactCollector: collector,
        pollInterval: const Duration(milliseconds: 10),
      );
      addTearDown(executor.stop);

      await tasks.create(
        id: 'task-coding-only-research',
        title: 'Coding-only research',
        description: 'coding-only mode, research type.',
        type: TaskType.research,
        autoStart: true,
        configJson: const {'reviewMode': 'coding-only'},
      );

      await executor.pollOnce();

      expect((await tasks.get('task-coding-only-research'))!.status, TaskStatus.accepted);
    });

    test('unknown reviewMode — logs warning and defaults to review', () async {
      final executor = TaskExecutor(
        tasks: tasks,
        sessions: sessions,
        messages: messages,
        turns: turns,
        artifactCollector: collector,
        pollInterval: const Duration(milliseconds: 10),
      );
      addTearDown(executor.stop);

      await tasks.create(
        id: 'task-unknown-mode',
        title: 'Unknown mode',
        description: 'reviewMode with invalid value.',
        type: TaskType.research,
        autoStart: true,
        configJson: const {'reviewMode': 'invalid'},
      );

      await executor.pollOnce();

      // Falls back to default behavior: goes to review.
      expect((await tasks.get('task-unknown-mode'))!.status, TaskStatus.review);
    });
  });

  // ---------------------------------------------------------------------------
  // Tool filter callback wiring
  // ---------------------------------------------------------------------------

  group('TaskToolFilterGuard integration', () {
    test('tool filter guard is updated with allowedTools before turn and cleared after', () async {
      final filter = TaskToolFilterGuard();

      // Create a runner with the filter guard wired.
      final runner = TurnRunner(
        harness: worker,
        messages: messages,
        behavior: BehaviorFileService(workspaceDir: workspaceDir),
        sessions: sessions,
        taskToolFilterGuard: filter,
      );
      final pool = HarnessPool(runners: [runner]);
      final poolTurns = TurnManager.fromPool(pool: pool);

      final executor = TaskExecutor(
        tasks: tasks,
        sessions: sessions,
        messages: messages,
        turns: poolTurns,
        artifactCollector: collector,
        pollInterval: const Duration(milliseconds: 10),
      );
      addTearDown(executor.stop);
      addTearDown(runner.harness.dispose);

      await tasks.create(
        id: 'task-filter',
        title: 'Tool filter task',
        description: 'Has allowedTools.',
        type: TaskType.research,
        autoStart: true,
        configJson: const {'allowedTools': ['file_read', 'shell']},
      );

      await executor.pollOnce();

      // Guard should be cleared after the turn (null for cleanup).
      expect(filter.allowedTools, isNull);
    });

    test('TurnRunner.setTaskToolFilter sets allowedTools on the guard', () {
      final filter = TaskToolFilterGuard();
      filter.allowedTools = null;

      final runner = TurnRunner(
        harness: worker,
        messages: messages,
        behavior: BehaviorFileService(workspaceDir: workspaceDir),
        sessions: sessions,
        taskToolFilterGuard: filter,
      );

      runner.setTaskToolFilter(['shell', 'file_read']);
      expect(filter.allowedTools, ['shell', 'file_read']);

      runner.setTaskToolFilter(null);
      expect(filter.allowedTools, isNull);
    });

    test('TurnRunner.setTaskToolFilter is a no-op when no guard is present', () {
      final runner = TurnRunner(
        harness: worker,
        messages: messages,
        behavior: BehaviorFileService(workspaceDir: workspaceDir),
        sessions: sessions,
      );
      // Should not throw.
      expect(() => runner.setTaskToolFilter(['shell']), returnsNormally);
    });

    test('TurnManager.setTaskToolFilter delegates to primary runner', () {
      final filter = TaskToolFilterGuard();
      final runner = TurnRunner(
        harness: worker,
        messages: messages,
        behavior: BehaviorFileService(workspaceDir: workspaceDir),
        sessions: sessions,
        taskToolFilterGuard: filter,
      );
      final pool = HarnessPool(runners: [runner]);
      final poolTurns = TurnManager.fromPool(pool: pool);

      poolTurns.setTaskToolFilter(['web_fetch']);
      expect(filter.allowedTools, ['web_fetch']);

      poolTurns.setTaskToolFilter(null);
      expect(filter.allowedTools, isNull);
    });

    test('malformed allowedTools (not a list) — guard receives null', () async {
      final filter = TaskToolFilterGuard();
      final runner = TurnRunner(
        harness: worker,
        messages: messages,
        behavior: BehaviorFileService(workspaceDir: workspaceDir),
        sessions: sessions,
        taskToolFilterGuard: filter,
      );
      final pool = HarnessPool(runners: [runner]);
      final poolTurns = TurnManager.fromPool(pool: pool);

      final executor = TaskExecutor(
        tasks: tasks,
        sessions: sessions,
        messages: messages,
        turns: poolTurns,
        artifactCollector: collector,
        pollInterval: const Duration(milliseconds: 10),
      );
      addTearDown(executor.stop);
      addTearDown(runner.harness.dispose);

      await tasks.create(
        id: 'task-malformed-filter',
        title: 'Malformed filter task',
        description: 'allowedTools is a string, not a list.',
        type: TaskType.research,
        autoStart: true,
        configJson: const {'allowedTools': 'not-a-list'},
      );

      await executor.pollOnce();

      // Task should still complete — malformed allowedTools is fail-safe.
      expect((await tasks.get('task-malformed-filter'))!.status, TaskStatus.review);
      // Guard should be null (cleared after turn).
      expect(filter.allowedTools, isNull);
    });
  });
}
