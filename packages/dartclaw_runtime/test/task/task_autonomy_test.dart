import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_runtime/src/turn_manager.dart' show TurnManager;
import 'package:dartclaw_runtime/src/turn_runner.dart' show TurnRunner;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import '../execution_coordinator_test_support.dart';

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/// Fake harness that resolves immediately with configurable token counts.
class _FakeHarness implements AgentHarness {
  @override
  String skillActivationLine(String skill) => "Use the '$skill' skill.";

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
  bool get isRootProcessTerminationConfirmed => true;

  @override
  bool get supportsStructuredOutput => false;

  @override
  bool get supportsProviderSessionResume => false;

  @override
  Stream<BridgeEvent> get events => _eventsCtrl.stream;
  @override
  Future<void> start() async {}
  @override
  Future<void> resetSessionContinuity(String sessionId) async {}

  @override
  Future<void> cancel() async {}
  @override
  Future<void> stop() async {}

  @override
  Future<TurnResult> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    String? agentId,
    Map<String, dynamic>? mcpServers,
    String? providerSessionId,
    bool requestProviderSessionResume = false,
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
    Map<String, dynamic>? outputSchema,
  }) async {
    if (shouldFail) throw StateError('simulated failure');
    if (responseText.isNotEmpty) {
      _eventsCtrl.add(DeltaEvent(responseText));
    }
    return const TurnResult(inputTokens: 10, outputTokens: 5);
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
      turnLimits: const TurnLimitsConfig.defaults(),
      messages: messages,
      worker: worker,
      behavior: BehaviorFileService(workspaceDir: workspaceDir),
      sessions: sessions,
    );
    collector = ArtifactCollector(tasks: tasks, sessionsDir: sessionsDir, dataDir: tempDir.path);
  });

  tearDown(() async {
    await tasks.dispose();
    await messages.dispose();
    await worker.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    final wsDir = Directory(workspaceDir);
    if (wsDir.existsSync()) wsDir.deleteSync(recursive: true);
  });

  TaskExecutor buildExecutor({TurnManager? turnManager}) => TaskExecutor(
    services: TaskExecutorServices(tasks: tasks, sessions: sessions, messages: messages, artifactCollector: collector),
    runners: TaskExecutorRunners(turns: turnManager ?? turns),
    pollInterval: const Duration(milliseconds: 10),
  );

  // ---------------------------------------------------------------------------
  // Review mode enforcement
  // ---------------------------------------------------------------------------

  group('reviewMode enforcement', () {
    test('null reviewMode sends the task to review by default', () async {
      final executor = buildExecutor();
      addTearDown(executor.stop);

      await tasks.create(
        id: 'task-default',
        title: 'Default review',
        description: 'No reviewMode set.',
        autoStart: true,
      );

      await executor.pollOnce();
      await _waitForStatus(tasks, 'task-default', TaskStatus.review);

      expect((await tasks.get('task-default'))!.status, TaskStatus.review);
    });

    test('mandatory sends the task to review', () async {
      final executor = buildExecutor();
      addTearDown(executor.stop);

      await tasks.create(
        id: 'task-mandatory',
        title: 'Mandatory review',
        description: 'reviewMode = mandatory.',
        autoStart: true,
        configJson: const {'reviewMode': 'mandatory'},
      );

      await executor.pollOnce();
      await _waitForStatus(tasks, 'task-mandatory', TaskStatus.review);

      expect((await tasks.get('task-mandatory'))!.status, TaskStatus.review);
    });

    test('auto-accept — task transitions directly to accepted', () async {
      final executor = buildExecutor();
      addTearDown(executor.stop);

      await tasks.create(
        id: 'task-auto-accept',
        title: 'Auto-accept task',
        description: 'Should skip review.',
        autoStart: true,
        configJson: const {'reviewMode': 'auto-accept'},
      );

      await executor.pollOnce();
      await _waitForStatus(tasks, 'task-auto-accept', TaskStatus.accepted);

      expect((await tasks.get('task-auto-accept'))!.status, TaskStatus.accepted);
    });

    test('worktree-only + worktree task — goes to review', () async {
      final executor = buildExecutor();
      addTearDown(executor.stop);

      await tasks.create(
        id: 'task-worktree-review',
        title: 'Worktree review',
        description: 'Worktree-bound task.',
        autoStart: true,
        configJson: const {'reviewMode': 'worktree-only', 'needsWorktree': true},
      );

      await executor.pollOnce();
      await _waitForStatus(tasks, 'task-worktree-review', TaskStatus.review);

      expect((await tasks.get('task-worktree-review'))!.status, TaskStatus.review);
    });

    test('worktree-only + non-worktree task — goes to accepted', () async {
      final executor = buildExecutor();
      addTearDown(executor.stop);

      await tasks.create(
        id: 'task-without-worktree',
        title: 'Non-worktree task',
        description: 'Work that does not need a worktree.',
        autoStart: true,
        configJson: const {'reviewMode': 'worktree-only', 'needsWorktree': false},
      );

      await executor.pollOnce();
      await _waitForStatus(tasks, 'task-without-worktree', TaskStatus.accepted);

      expect((await tasks.get('task-without-worktree'))!.status, TaskStatus.accepted);
    });

    test('unknown reviewMode — logs warning and defaults to review', () async {
      final executor = buildExecutor();
      addTearDown(executor.stop);

      await tasks.create(
        id: 'task-unknown-mode',
        title: 'Unknown mode',
        description: 'reviewMode with invalid value.',
        autoStart: true,
        configJson: const {'reviewMode': 'invalid'},
      );

      await executor.pollOnce();
      await _waitForStatus(tasks, 'task-unknown-mode', TaskStatus.review);

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
        turnLimits: const TurnLimitsConfig.defaults(),
        harness: worker,
        messages: messages,
        behavior: BehaviorFileService(workspaceDir: workspaceDir),
        sessions: sessions,
        taskToolFilterGuard: filter,
      );
      final poolTurns = turnManagerForRunners([turns.executions.primary!, runner]);

      final executor = buildExecutor(turnManager: poolTurns);
      addTearDown(executor.stop);
      addTearDown(runner.harness.dispose);

      await tasks.create(
        id: 'task-filter',
        title: 'Tool filter task',
        description: 'Has allowedTools.',
        autoStart: true,
        configJson: const {
          'allowedTools': ['file_read', 'shell'],
        },
      );

      await executor.pollOnce();
      await _waitForStatus(tasks, 'task-filter', TaskStatus.review);

      // Guard should be cleared after the turn (null for cleanup).
      expect(filter.allowedTools, isNull);
    });

    test('TurnRunner.setTaskToolFilter sets allowedTools on the guard', () {
      final filter = TaskToolFilterGuard();
      filter.allowedTools = null;

      final runner = TurnRunner(
        turnLimits: const TurnLimitsConfig.defaults(),
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

    test('TurnRunner.setTaskReadOnly toggles read-only mode on the guard', () {
      final filter = TaskToolFilterGuard()..readOnly = false;

      final runner = TurnRunner(
        turnLimits: const TurnLimitsConfig.defaults(),
        harness: worker,
        messages: messages,
        behavior: BehaviorFileService(workspaceDir: workspaceDir),
        sessions: sessions,
        taskToolFilterGuard: filter,
      );

      runner.setTaskReadOnly(true);
      expect(filter.readOnly, isTrue);

      runner.setTaskReadOnly(false);
      expect(filter.readOnly, isFalse);
    });

    test('TurnRunner.setTaskToolFilter is a no-op when no guard is present', () {
      final runner = TurnRunner(
        turnLimits: const TurnLimitsConfig.defaults(),
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
        turnLimits: const TurnLimitsConfig.defaults(),
        harness: worker,
        messages: messages,
        behavior: BehaviorFileService(workspaceDir: workspaceDir),
        sessions: sessions,
        taskToolFilterGuard: filter,
      );
      final poolTurns = turnManagerForRunners([runner]);

      poolTurns.setTaskToolFilter(['web_fetch']);
      expect(filter.allowedTools, ['web_fetch']);

      poolTurns.setTaskToolFilter(null);
      expect(filter.allowedTools, isNull);
    });

    test('malformed allowedTools (not a list) — guard receives null', () async {
      final filter = TaskToolFilterGuard();
      final runner = TurnRunner(
        turnLimits: const TurnLimitsConfig.defaults(),
        harness: worker,
        messages: messages,
        behavior: BehaviorFileService(workspaceDir: workspaceDir),
        sessions: sessions,
        taskToolFilterGuard: filter,
      );
      final poolTurns = turnManagerForRunners([turns.executions.primary!, runner]);

      final executor = buildExecutor(turnManager: poolTurns);
      addTearDown(executor.stop);
      addTearDown(runner.harness.dispose);

      await tasks.create(
        id: 'task-malformed-filter',
        title: 'Malformed filter task',
        description: 'allowedTools is a string, not a list.',
        autoStart: true,
        configJson: const {'allowedTools': 'not-a-list'},
      );

      await executor.pollOnce();
      await _waitForStatus(tasks, 'task-malformed-filter', TaskStatus.review);

      // Task should still complete — malformed allowedTools is fail-safe.
      expect((await tasks.get('task-malformed-filter'))!.status, TaskStatus.review);
      // Guard should be null (cleared after turn).
      expect(filter.allowedTools, isNull);
    });

    test('read-only mode blocks mutating shell commands', () async {
      final guard = TaskToolFilterGuard()..readOnly = true;

      final verdict = await guard.evaluate(
        GuardContext(
          hookPoint: 'beforeToolCall',
          toolName: 'shell',
          toolInput: const {'command': 'touch docs/generated.md'},
          timestamp: DateTime.now(),
        ),
      );

      expect(verdict.isBlock, isTrue);
      expect(verdict.message, contains('read-only'));
    });

    test('read-only mode allows non-mutating shell commands', () async {
      final guard = TaskToolFilterGuard()..readOnly = true;

      final verdict = await guard.evaluate(
        GuardContext(
          hookPoint: 'beforeToolCall',
          toolName: 'shell',
          toolInput: const {'command': 'find docs -maxdepth 2 -type f'},
          timestamp: DateTime.now(),
        ),
      );

      expect(verdict.isPass, isTrue);
    });

    test('read-only mode blocks file edit tools even without an allowlist', () async {
      final guard = TaskToolFilterGuard()..readOnly = true;

      final verdict = await guard.evaluate(
        GuardContext(
          hookPoint: 'beforeToolCall',
          toolName: 'file_edit',
          toolInput: const {'path': 'docs/generated.md'},
          timestamp: DateTime.now(),
        ),
      );

      expect(verdict.isBlock, isTrue);
      expect(verdict.message, contains('read-only'));
    });
  });
}

Future<void> _waitForStatus(TaskService tasks, String taskId, TaskStatus expected) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (DateTime.now().isBefore(deadline)) {
    if ((await tasks.get(taskId))?.status == expected) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('Task $taskId did not reach ${expected.name}');
}
