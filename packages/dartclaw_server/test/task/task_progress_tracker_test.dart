import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/task/task_progress_tracker.dart';
import 'package:dartclaw_server/src/task/task_service.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

void main() {
  late InMemoryTaskRepository repo;
  late TaskService taskService;
  late TestEventBus eventBus;
  late TaskProgressTracker tracker;
  late List<TaskProgressSnapshot> emitted;
  late StreamSubscription<TaskProgressSnapshot> sub;

  TaskEventCreatedEvent makeEvent({
    String taskId = 'task-1',
    required String kind,
    Map<String, dynamic> details = const {},
  }) {
    return TaskEventCreatedEvent(
      taskId: taskId,
      eventId: 'evt-${DateTime.now().microsecondsSinceEpoch}',
      kind: kind,
      details: details,
      timestamp: DateTime.now(),
    );
  }

  void fireEvent({String taskId = 'task-1', required String kind, Map<String, dynamic> details = const {}}) {
    eventBus.fire(makeEvent(taskId: taskId, kind: kind, details: details));
  }

  setUp(() {
    repo = InMemoryTaskRepository();
    taskService = TaskService(repo);
    eventBus = TestEventBus();
    emitted = [];
    tracker = TaskProgressTracker(eventBus: eventBus, tasks: taskService);
    sub = tracker.onProgress.listen(emitted.add);
    tracker.start();
  });

  tearDown(() async {
    await sub.cancel();
    tracker.dispose();
    await eventBus.dispose();
    await taskService.dispose();
  });

  // Helper: pump event loop to let async handlers run.
  Future<void> pump() => Future<void>.delayed(Duration.zero);

  group('toolCalled event', () {
    test('emits snapshot with currentActivity set', () async {
      fireEvent(kind: 'statusChanged', details: {'newStatus': 'running'});
      fireEvent(kind: 'toolCalled', details: {'name': 'Read'});
      await pump();

      expect(emitted, isNotEmpty);
      expect(emitted.last.taskId, 'task-1');
      expect(emitted.last.currentActivity, 'Reading');
      expect(emitted.last.isComplete, isFalse);
    });

    test('unknown tool name uses raw name', () async {
      fireEvent(kind: 'statusChanged', details: {'newStatus': 'running'});
      fireEvent(kind: 'toolCalled', details: {'name': 'mcp__dart__run_tests'});
      await pump();

      expect(emitted.last.currentActivity, 'mcp__dart__run_tests');
    });
  });

  group('tokenUpdate event', () {
    test('accumulates tokensUsed', () async {
      fireEvent(kind: 'statusChanged', details: {'newStatus': 'running'});
      fireEvent(kind: 'tokenUpdate', details: {'inputTokens': 500, 'outputTokens': 300});
      await pump();

      expect(emitted.last.tokensUsed, 800);
    });

    test('accumulates across multiple updates', () async {
      fireEvent(kind: 'statusChanged', details: {'newStatus': 'running'});
      fireEvent(kind: 'tokenUpdate', details: {'inputTokens': 100, 'outputTokens': 50});
      fireEvent(kind: 'tokenUpdate', details: {'inputTokens': 200, 'outputTokens': 100});
      // Wait for throttle timer to fire and emit deferred snapshot.
      await Future<void>.delayed(const Duration(milliseconds: 1100));

      // Both updates must be accumulated in the deferred snapshot.
      final snapshotsForTask = emitted.where((s) => s.taskId == 'task-1').toList();
      expect(snapshotsForTask.last.tokensUsed, 450);
    });

    test('negative token counts are treated as 0', () async {
      fireEvent(kind: 'statusChanged', details: {'newStatus': 'running'});
      fireEvent(kind: 'tokenUpdate', details: {'inputTokens': -10, 'outputTokens': 50});
      await pump();

      expect(emitted.last.tokensUsed, 50);
    });
  });

  group('progress percentage', () {
    test('computed when tokenBudget set via seedFromEvents', () async {
      tracker.seedFromEvents('task-1', [
        {
          'kind': 'tokenUpdate',
          'details': {'inputTokens': 847, 'outputTokens': 1000},
        },
      ], tokenBudget: 10000);
      fireEvent(kind: 'statusChanged', details: {'newStatus': 'running'});
      fireEvent(kind: 'tokenUpdate', details: {'inputTokens': 0, 'outputTokens': 0});
      await pump();

      final snapshot = emitted.where((s) => s.taskId == 'task-1').last;
      // 1847 / 10000 = 18.47% → rounds to 18
      expect(snapshot.progress, 18);
      expect(snapshot.tokenBudget, 10000);
    });

    test('null when no tokenBudget', () async {
      fireEvent(kind: 'statusChanged', details: {'newStatus': 'running'});
      fireEvent(kind: 'tokenUpdate', details: {'inputTokens': 500, 'outputTokens': 300});
      await pump();

      expect(emitted.last.progress, isNull);
    });

    test('capped at 100 when over budget', () async {
      tracker.seedFromEvents('task-1', [
        {
          'kind': 'tokenUpdate',
          'details': {'inputTokens': 10000, 'outputTokens': 5000},
        },
      ], tokenBudget: 10000);
      fireEvent(kind: 'statusChanged', details: {'newStatus': 'running'});
      fireEvent(kind: 'tokenUpdate', details: {'inputTokens': 0, 'outputTokens': 0});
      await pump();

      expect(emitted.last.progress, 100);
    });

    test('null when tokenBudget is 0', () async {
      tracker.seedFromEvents('task-1', [], tokenBudget: 0);
      fireEvent(kind: 'statusChanged', details: {'newStatus': 'running'});
      fireEvent(kind: 'tokenUpdate', details: {'inputTokens': 100, 'outputTokens': 50});
      await pump();

      expect(emitted.last.progress, isNull);
    });
  });

  group('statusChanged to running', () {
    test('initializes state', () async {
      fireEvent(kind: 'statusChanged', details: {'newStatus': 'running'});
      await pump();

      expect(emitted, isEmpty); // No progress emitted until a real event.
    });
  });

  group('statusChanged to non-running', () {
    test('emits isComplete: true and clears state', () async {
      fireEvent(kind: 'statusChanged', details: {'newStatus': 'running'});
      fireEvent(kind: 'tokenUpdate', details: {'inputTokens': 100, 'outputTokens': 50});
      fireEvent(kind: 'statusChanged', details: {'newStatus': 'review'});
      await pump();

      final completions = emitted.where((s) => s.isComplete).toList();
      expect(completions, hasLength(1));
      expect(completions.first.taskId, 'task-1');
    });

    test('events after task leaves running state are ignored', () async {
      fireEvent(kind: 'statusChanged', details: {'newStatus': 'running'});
      fireEvent(kind: 'statusChanged', details: {'newStatus': 'done'});
      fireEvent(kind: 'tokenUpdate', details: {'inputTokens': 100, 'outputTokens': 50});
      await pump();

      // Only a completion event, no further progress updates.
      expect(emitted.where((s) => !s.isComplete), isEmpty);
    });
  });

  group('seedFromEvents', () {
    test('replays tokenUpdate events for cumulative tokensUsed', () async {
      tracker.seedFromEvents('task-1', [
        {
          'kind': 'tokenUpdate',
          'details': {'inputTokens': 100, 'outputTokens': 50},
        },
        {
          'kind': 'tokenUpdate',
          'details': {'inputTokens': 200, 'outputTokens': 100},
        },
        {
          'kind': 'tokenUpdate',
          'details': {'inputTokens': 50, 'outputTokens': 25},
        },
      ], tokenBudget: 5000);

      // Trigger a live event to emit snapshot.
      fireEvent(kind: 'statusChanged', details: {'newStatus': 'running'});
      fireEvent(kind: 'tokenUpdate', details: {'inputTokens': 0, 'outputTokens': 0});
      await pump();

      expect(emitted.last.tokensUsed, 525);
    });

    test('replays toolCalled events for currentActivity', () async {
      tracker.seedFromEvents('task-1', [
        {
          'kind': 'toolCalled',
          'details': {'name': 'Bash'},
        },
        {
          'kind': 'toolCalled',
          'details': {'name': 'Read'},
        },
      ]);

      fireEvent(kind: 'statusChanged', details: {'newStatus': 'running'});
      fireEvent(kind: 'tokenUpdate', details: {'inputTokens': 0, 'outputTokens': 0});
      await pump();

      expect(emitted.last.currentActivity, 'Reading');
    });

    test('passes tokenBudget to state', () async {
      tracker.seedFromEvents('task-1', [], tokenBudget: 8000);

      fireEvent(kind: 'statusChanged', details: {'newStatus': 'running'});
      fireEvent(kind: 'tokenUpdate', details: {'inputTokens': 800, 'outputTokens': 0});
      await pump();

      expect(emitted.last.tokenBudget, 8000);
    });
  });

  group('throttle', () {
    test('events separated by >1s each emit immediately', () async {
      fireEvent(kind: 'statusChanged', details: {'newStatus': 'running'});
      fireEvent(kind: 'toolCalled', details: {'name': 'Read'});
      await pump();
      final countAfterFirst = emitted.length;

      // Wait for throttle to expire.
      await Future<void>.delayed(const Duration(milliseconds: 1100));

      fireEvent(kind: 'toolCalled', details: {'name': 'Write'});
      await pump();

      expect(emitted.length, greaterThan(countAfterFirst));
      expect(emitted.last.currentActivity, 'Writing');
    });
  });

  group('_formatActivity', () {
    test('maps known tool names correctly', () {
      expect(TaskProgressTracker.formatActivity('Read', {}), 'Reading');
      expect(
        TaskProgressTracker.formatActivity('Read', {'context': 'src/auth/login.dart'}),
        'Reading src/auth/login.dart',
      );
      expect(TaskProgressTracker.formatActivity('Edit', {}), 'Editing');
      expect(TaskProgressTracker.formatActivity('Write', {}), 'Writing');
      expect(TaskProgressTracker.formatActivity('Bash', {}), 'Running');
      expect(TaskProgressTracker.formatActivity('Grep', {}), 'Searching');
      expect(TaskProgressTracker.formatActivity('Search', {}), 'Searching');
      expect(TaskProgressTracker.formatActivity('Glob', {}), 'Finding files');
      expect(TaskProgressTracker.formatActivity('LSP', {}), 'Analyzing');
      expect(TaskProgressTracker.formatActivity('lsp', {}), 'Analyzing');
      expect(TaskProgressTracker.formatActivity('read', {}), 'Reading');
    });

    test('unknown tool name returns raw name', () {
      expect(TaskProgressTracker.formatActivity('CustomTool', {}), 'CustomTool');
    });

    test('empty tool name returns empty string', () {
      expect(TaskProgressTracker.formatActivity('', {}), '');
    });
  });

  group('TaskProgressSnapshot.toJson', () {
    test('includes all fields with correct types', () {
      final snapshot = TaskProgressSnapshot(
        taskId: 'task-abc',
        progress: 42,
        currentActivity: 'Reading',
        tokensUsed: 1847,
        tokenBudget: 10000,
        isComplete: false,
      );
      final json = snapshot.toJson();
      expect(json['type'], 'task_progress');
      expect(json['taskId'], 'task-abc');
      expect(json['progress'], 42);
      expect(json['currentActivity'], 'Reading');
      expect(json['tokensUsed'], 1847);
      expect(json['tokenBudget'], 10000);
      expect(json['isComplete'], false);
    });

    test('progress and currentActivity can be null', () {
      final snapshot = TaskProgressSnapshot(
        taskId: 'task-1',
        progress: null,
        currentActivity: null,
        tokensUsed: 0,
        tokenBudget: null,
        isComplete: false,
      );
      final json = snapshot.toJson();
      expect(json['progress'], isNull);
      expect(json['currentActivity'], isNull);
      expect(json['tokenBudget'], isNull);
    });
  });

  group('dispose', () {
    test('cancels subscription, closes stream', () async {
      tracker.dispose();
      await pump();

      // Firing events after dispose should not throw.
      expect(() => fireEvent(kind: 'toolCalled', details: {'name': 'Read'}), returnsNormally);
      await pump();

      // No new snapshots after dispose.
      expect(emitted, isEmpty);
    });
  });

  group('multiple concurrent tasks', () {
    test('independent state per task', () async {
      fireEvent(taskId: 'task-1', kind: 'statusChanged', details: {'newStatus': 'running'});
      fireEvent(taskId: 'task-2', kind: 'statusChanged', details: {'newStatus': 'running'});
      fireEvent(taskId: 'task-1', kind: 'tokenUpdate', details: {'inputTokens': 100, 'outputTokens': 0});
      fireEvent(taskId: 'task-2', kind: 'tokenUpdate', details: {'inputTokens': 200, 'outputTokens': 0});
      await pump();

      final task1Snapshots = emitted.where((s) => s.taskId == 'task-1').toList();
      final task2Snapshots = emitted.where((s) => s.taskId == 'task-2').toList();
      expect(task1Snapshots.last.tokensUsed, 100);
      expect(task2Snapshots.last.tokensUsed, 200);
    });
  });
}
