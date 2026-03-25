import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/canvas/canvas_service.dart';
import 'package:dartclaw_server/src/canvas/workshop_canvas_subscriber.dart';
import 'package:dartclaw_server/src/observability/usage_tracker.dart';
import 'package:dartclaw_server/src/task/task_service.dart';
import 'package:dartclaw_server/src/templates/loader.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  group('WorkshopCanvasSubscriber', () {
    late InMemoryTaskRepository repo;
    late TaskService tasks;
    late TestEventBus eventBus;
    late _RecordingCanvasService canvasService;
    late _FakeUsageTracker usageTracker;
    late WorkshopCanvasSubscriber subscriber;

    const sessionKey = 'agent:main:web:';

    setUp(() {
      repo = InMemoryTaskRepository();
      tasks = TaskService(repo);
      eventBus = TestEventBus();
      canvasService = _RecordingCanvasService();
      usageTracker = _FakeUsageTracker(summary: {'total_input_tokens': 100, 'total_output_tokens': 50});
      subscriber = WorkshopCanvasSubscriber(
        canvasService: canvasService,
        taskService: tasks,
        usageTracker: usageTracker,
        sessionKey: sessionKey,
        dailyBudgetTokens: 1000,
        serverStartTime: DateTime.now().subtract(const Duration(minutes: 10)),
      );
    });

    tearDown(() async {
      await subscriber.dispose();
      await canvasService.dispose();
      await eventBus.dispose();
      await tasks.dispose();
    });

    test('subscribe pushes rendered content when task status changes', () async {
      await _createQueuedTask(tasks, id: 'task-a', title: 'Task A');
      subscriber.subscribe(eventBus);

      _fireTaskChange(eventBus, taskId: 'task-a', oldStatus: TaskStatus.queued, newStatus: TaskStatus.running);
      await Future<void>.delayed(const Duration(milliseconds: 650));

      expect(canvasService.pushedHtml, hasLength(1));
      expect(canvasService.pushedHtml.single, contains('canvas-task-board'));
      expect(canvasService.pushedHtml.single, contains('canvas-stats-bar'));
    });

    test('debounce coalesces rapid events into one push', () async {
      await _createQueuedTask(tasks, id: 'task-b', title: 'Task B');
      subscriber.subscribe(eventBus);

      _fireTaskChange(eventBus, taskId: 'task-b', oldStatus: TaskStatus.queued, newStatus: TaskStatus.running);
      _fireTaskChange(eventBus, taskId: 'task-b', oldStatus: TaskStatus.running, newStatus: TaskStatus.review);
      _fireTaskChange(eventBus, taskId: 'task-b', oldStatus: TaskStatus.review, newStatus: TaskStatus.accepted);

      await Future<void>.delayed(const Duration(milliseconds: 650));
      expect(canvasService.pushedHtml, hasLength(1));
    });

    test('debounce timer resets when a new event arrives before expiry', () async {
      await _createQueuedTask(tasks, id: 'task-c', title: 'Task C');
      subscriber.subscribe(eventBus);

      _fireTaskChange(eventBus, taskId: 'task-c', oldStatus: TaskStatus.queued, newStatus: TaskStatus.running);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      _fireTaskChange(eventBus, taskId: 'task-c', oldStatus: TaskStatus.running, newStatus: TaskStatus.review);

      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(canvasService.pushedHtml, isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(canvasService.pushedHtml, hasLength(1));
    });

    test('taskBoardEnabled false pushes only stats bar fragment', () async {
      await subscriber.dispose();
      subscriber = WorkshopCanvasSubscriber(
        canvasService: canvasService,
        taskService: tasks,
        usageTracker: usageTracker,
        sessionKey: sessionKey,
        dailyBudgetTokens: 1000,
        serverStartTime: DateTime.now(),
        taskBoardEnabled: false,
        statsBarEnabled: true,
      );
      await _createQueuedTask(tasks, id: 'task-d', title: 'Task D');
      subscriber.subscribe(eventBus);

      _fireTaskChange(eventBus, taskId: 'task-d', oldStatus: TaskStatus.queued, newStatus: TaskStatus.running);
      await Future<void>.delayed(const Duration(milliseconds: 650));

      expect(canvasService.pushedHtml, hasLength(1));
      expect(canvasService.pushedHtml.single, contains('canvas-stats-bar'));
      expect(canvasService.pushedHtml.single, isNot(contains('canvas-task-board')));
    });

    test('statsBarEnabled false pushes only task board fragment', () async {
      await subscriber.dispose();
      subscriber = WorkshopCanvasSubscriber(
        canvasService: canvasService,
        taskService: tasks,
        usageTracker: usageTracker,
        sessionKey: sessionKey,
        dailyBudgetTokens: 1000,
        serverStartTime: DateTime.now(),
        taskBoardEnabled: true,
        statsBarEnabled: false,
      );
      await _createQueuedTask(tasks, id: 'task-e', title: 'Task E');
      subscriber.subscribe(eventBus);

      _fireTaskChange(eventBus, taskId: 'task-e', oldStatus: TaskStatus.queued, newStatus: TaskStatus.running);
      await Future<void>.delayed(const Duration(milliseconds: 650));

      expect(canvasService.pushedHtml, hasLength(1));
      expect(canvasService.pushedHtml.single, contains('canvas-task-board'));
      expect(canvasService.pushedHtml.single, isNot(contains('canvas-stats-bar')));
    });

    test('both flags disabled results in no pushes', () async {
      await subscriber.dispose();
      subscriber = WorkshopCanvasSubscriber(
        canvasService: canvasService,
        taskService: tasks,
        usageTracker: usageTracker,
        sessionKey: sessionKey,
        dailyBudgetTokens: 1000,
        serverStartTime: DateTime.now(),
        taskBoardEnabled: false,
        statsBarEnabled: false,
      );
      await _createQueuedTask(tasks, id: 'task-f', title: 'Task F');
      subscriber.subscribe(eventBus);

      _fireTaskChange(eventBus, taskId: 'task-f', oldStatus: TaskStatus.queued, newStatus: TaskStatus.running);
      await Future<void>.delayed(const Duration(milliseconds: 650));

      expect(canvasService.pushedHtml, isEmpty);
    });

    test('dispose cancels pending/debounced updates', () async {
      await _createQueuedTask(tasks, id: 'task-g', title: 'Task G');
      subscriber.subscribe(eventBus);

      _fireTaskChange(eventBus, taskId: 'task-g', oldStatus: TaskStatus.queued, newStatus: TaskStatus.running);
      await subscriber.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 650));

      expect(canvasService.pushedHtml, isEmpty);
    });

    test('list failure is caught and does not crash', () async {
      await subscriber.dispose();
      final failingService = _FailingTaskService();
      subscriber = WorkshopCanvasSubscriber(
        canvasService: canvasService,
        taskService: failingService,
        usageTracker: usageTracker,
        sessionKey: sessionKey,
        dailyBudgetTokens: 1000,
        serverStartTime: DateTime.now(),
      );
      subscriber.subscribe(eventBus);

      _fireTaskChange(eventBus, taskId: 'missing', oldStatus: TaskStatus.queued, newStatus: TaskStatus.running);
      await Future<void>.delayed(const Duration(milliseconds: 650));

      expect(canvasService.pushedHtml, isEmpty);
    });
  });
}

Future<void> _createQueuedTask(TaskService tasks, {required String id, required String title}) async {
  await tasks.create(
    id: id,
    title: title,
    description: title,
    type: TaskType.research,
    autoStart: true,
    createdBy: 'Alice',
  );
}

void _fireTaskChange(
  TestEventBus eventBus, {
  required String taskId,
  required TaskStatus oldStatus,
  required TaskStatus newStatus,
}) {
  eventBus.fire(
    TaskStatusChangedEvent(
      taskId: taskId,
      oldStatus: oldStatus,
      newStatus: newStatus,
      trigger: 'test',
      timestamp: DateTime.now(),
    ),
  );
}

class _RecordingCanvasService extends CanvasService {
  final List<String> pushedHtml = [];

  @override
  void push(String sessionKey, String htmlFragment) {
    pushedHtml.add(htmlFragment);
    super.push(sessionKey, htmlFragment);
  }
}

class _FakeUsageTracker extends UsageTracker {
  final Map<String, dynamic>? summary;

  _FakeUsageTracker({required this.summary}) : super(dataDir: '/tmp');

  @override
  Future<Map<String, dynamic>?> dailySummary() async => summary;
}

class _FailingTaskService extends TaskService {
  _FailingTaskService() : super(InMemoryTaskRepository());

  @override
  Future<List<Task>> list({TaskStatus? status, TaskType? type}) async {
    throw StateError('boom');
  }
}
