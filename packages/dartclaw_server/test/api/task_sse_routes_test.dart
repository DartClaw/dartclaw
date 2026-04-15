import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/api/task_sse_routes.dart';
import 'package:dartclaw_server/src/task/task_progress_tracker.dart';
import 'package:dartclaw_server/src/task/task_service.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:shelf/shelf.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  late TaskService tasks;
  late EventBus eventBus;
  late Handler handler;

  setUp(() {
    db = openTaskDbInMemory();
    tasks = TaskService(SqliteTaskRepository(db));
    eventBus = EventBus();
    handler = taskSseRoutes(tasks, eventBus).call;
  });

  tearDown(() async {
    await eventBus.dispose();
    await tasks.dispose();
  });

  Map<String, dynamic> decodeFramePayload(String frame) {
    final dataLine = frame.trim().split('\n').first;
    expect(dataLine, startsWith('data: '));
    return jsonDecode(dataLine.substring('data: '.length)) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> nextFramePayload(StreamIterator<String> iterator) async {
    final hasFrame = await iterator.moveNext().timeout(const Duration(seconds: 1));
    expect(hasFrame, isTrue);
    return decodeFramePayload(iterator.current);
  }

  /// Reads frames until one with the given [type] is found.
  Future<Map<String, dynamic>> nextFramePayloadOfType(StreamIterator<String> iterator, String type) async {
    for (var i = 0; i < 20; i++) {
      final payload = await nextFramePayload(iterator);
      if (payload['type'] == type) return payload;
    }
    fail('Did not receive a frame with type=$type within 20 frames');
  }

  test('initial frame reports current review count', () async {
    await tasks.create(
      id: 'task-review',
      title: 'Review task',
      description: 'Check work',
      type: TaskType.coding,
      autoStart: true,
    );
    await tasks.transition('task-review', TaskStatus.running);
    await tasks.transition('task-review', TaskStatus.review);

    final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/events')));
    final iterator = StreamIterator(response.read().transform(utf8.decoder));
    addTearDown(iterator.cancel);

    expect(response.statusCode, 200);
    expect(response.headers['content-type'], 'text/event-stream');

    final hasFrame = await iterator.moveNext().timeout(const Duration(seconds: 1));
    expect(hasFrame, isTrue);
    final frame = iterator.current;
    expect(frame, contains('"type":"connected"'));
    expect(frame, contains('"reviewCount":1'));
  });

  test('sidebar-state endpoint returns review count and active tasks as json', () async {
    await tasks.create(
      id: 'task-running',
      title: 'Running task',
      description: 'Do work',
      type: TaskType.coding,
      autoStart: true,
      provider: ProviderIdentity.codex,
      now: DateTime.parse('2026-03-10T08:00:00Z'),
    );
    await tasks.transition('task-running', TaskStatus.running, now: DateTime.parse('2026-03-10T08:05:00Z'));

    final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/sidebar-state')));
    final payload = jsonDecode(await response.readAsString()) as Map<String, dynamic>;

    expect(response.statusCode, 200);
    expect(response.headers['content-type'], 'application/json');
    expect(payload['reviewCount'], 0);
    expect(payload['activeTasks'], isA<List<dynamic>>());
    final activeTasks = (payload['activeTasks'] as List<dynamic>).cast<Map<String, dynamic>>();
    expect(activeTasks, hasLength(1));
    expect(activeTasks.single['id'], 'task-running');
    expect(activeTasks.single['status'], 'running');
  });

  test('connected frame includes activeTasks with running and review tasks', () async {
    await tasks.create(
      id: 'task-running',
      title: 'Running task',
      description: 'Do work',
      type: TaskType.coding,
      autoStart: true,
      provider: ProviderIdentity.codex,
      now: DateTime.parse('2026-03-10T08:00:00Z'),
    );
    await tasks.transition('task-running', TaskStatus.running, now: DateTime.parse('2026-03-10T08:05:00Z'));

    await tasks.create(
      id: 'task-review',
      title: 'Review task',
      description: 'Check work',
      type: TaskType.coding,
      autoStart: true,
      provider: ProviderIdentity.claude,
      now: DateTime.parse('2026-03-10T09:00:00Z'),
    );
    await tasks.transition('task-review', TaskStatus.running, now: DateTime.parse('2026-03-10T09:10:00Z'));
    await tasks.transition('task-review', TaskStatus.review, now: DateTime.parse('2026-03-10T09:20:00Z'));

    final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/events')));
    final iterator = StreamIterator(response.read().transform(utf8.decoder));
    addTearDown(iterator.cancel);

    final payload = await nextFramePayload(iterator);

    expect(payload['type'], 'connected');
    expect(payload['activeTasks'], isA<List<dynamic>>());
    final activeTasks = (payload['activeTasks'] as List<dynamic>).cast<Map<String, dynamic>>();
    expect(activeTasks, hasLength(2));
    expect(activeTasks[0]['id'], 'task-running');
    expect(activeTasks[0]['status'], 'running');
    expect(activeTasks[0]['startedAt'], isA<String>());
    expect(activeTasks[0]['provider'], ProviderIdentity.codex);
    expect(activeTasks[0]['providerLabel'], 'Codex');
    expect(DateTime.parse(activeTasks[0]['startedAt'] as String), isA<DateTime>());

    expect(activeTasks[1]['id'], 'task-review');
    expect(activeTasks[1]['status'], 'review');
    expect(activeTasks[1]['startedAt'], isA<String>());
    expect(activeTasks[1]['provider'], ProviderIdentity.claude);
    expect(activeTasks[1]['providerLabel'], 'Claude');
    expect(DateTime.parse(activeTasks[1]['startedAt'] as String), isA<DateTime>());
  });

  test('connected frame orders review tasks by startedAt after running tasks', () async {
    await tasks.create(
      id: 'task-running',
      title: 'Running first',
      description: 'Do work',
      type: TaskType.coding,
      autoStart: true,
      now: DateTime.parse('2026-03-10T08:00:00Z'),
    );
    await tasks.transition('task-running', TaskStatus.running, now: DateTime.parse('2026-03-10T08:05:00Z'));

    await tasks.create(
      id: 'task-review-earlier',
      title: 'Earlier review',
      description: 'Check work',
      type: TaskType.coding,
      autoStart: true,
      provider: ProviderIdentity.claude,
      now: DateTime.parse('2026-03-10T09:00:00Z'),
    );
    await tasks.transition('task-review-earlier', TaskStatus.running, now: DateTime.parse('2026-03-10T09:05:00Z'));
    await tasks.transition('task-review-earlier', TaskStatus.review, now: DateTime.parse('2026-03-10T09:10:00Z'));

    await tasks.create(
      id: 'task-review-later',
      title: 'Later review',
      description: 'Check more work',
      type: TaskType.coding,
      autoStart: true,
      provider: ProviderIdentity.codex,
      now: DateTime.parse('2026-03-10T09:30:00Z'),
    );
    await tasks.transition('task-review-later', TaskStatus.running, now: DateTime.parse('2026-03-10T09:35:00Z'));
    await tasks.transition('task-review-later', TaskStatus.review, now: DateTime.parse('2026-03-10T09:40:00Z'));

    final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/events')));
    final iterator = StreamIterator(response.read().transform(utf8.decoder));
    addTearDown(iterator.cancel);

    final payload = await nextFramePayload(iterator);

    expect(payload['type'], 'connected');
    final activeTasks = (payload['activeTasks'] as List<dynamic>).cast<Map<String, dynamic>>();
    expect(activeTasks.map((task) => task['id']), ['task-running', 'task-review-earlier', 'task-review-later']);
  });

  test('status change frame includes updated review count', () async {
    await tasks.create(
      id: 'task-1',
      title: 'Queued task',
      description: 'Do work',
      type: TaskType.coding,
      autoStart: true,
    );

    final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/events')));
    final iterator = StreamIterator(response.read().transform(utf8.decoder));
    addTearDown(iterator.cancel);
    expect(await iterator.moveNext().timeout(const Duration(seconds: 1)), isTrue);

    await tasks.transition('task-1', TaskStatus.running);
    await tasks.transition('task-1', TaskStatus.review);
    eventBus.fire(
      TaskStatusChangedEvent(
        taskId: 'task-1',
        oldStatus: TaskStatus.running,
        newStatus: TaskStatus.review,
        trigger: 'system',
        timestamp: DateTime.parse('2026-03-10T10:15:00Z'),
      ),
    );

    final hasFrame = await iterator.moveNext().timeout(const Duration(seconds: 1));
    expect(hasFrame, isTrue);
    final frame = iterator.current;
    expect(frame, contains('"type":"task_status_changed"'));
    expect(frame, contains('"taskId":"task-1"'));
    expect(frame, contains('"reviewCount":1'));
  });

  test('status change frame includes updated activeTasks', () async {
    await tasks.create(
      id: 'task-1',
      title: 'Running task',
      description: 'Do work',
      type: TaskType.coding,
      autoStart: true,
      provider: ProviderIdentity.codex,
      now: DateTime.parse('2026-03-10T10:00:00Z'),
    );
    await tasks.transition('task-1', TaskStatus.running, now: DateTime.parse('2026-03-10T10:05:00Z'));

    final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/events')));
    final iterator = StreamIterator(response.read().transform(utf8.decoder));
    addTearDown(iterator.cancel);
    final connectedPayload = await nextFramePayload(iterator);
    expect(connectedPayload['type'], 'connected');

    await tasks.transition('task-1', TaskStatus.review, now: DateTime.parse('2026-03-10T10:15:00Z'));
    eventBus.fire(
      TaskStatusChangedEvent(
        taskId: 'task-1',
        oldStatus: TaskStatus.running,
        newStatus: TaskStatus.review,
        trigger: 'system',
        timestamp: DateTime.parse('2026-03-10T10:15:00Z'),
      ),
    );

    final payload = await nextFramePayload(iterator);

    expect(payload['type'], 'task_status_changed');
    expect(payload['taskId'], 'task-1');
    expect(payload['reviewCount'], 1);
    expect(payload['activeTasks'], isA<List<dynamic>>());
    final activeTasks = (payload['activeTasks'] as List<dynamic>).cast<Map<String, dynamic>>();
    expect(activeTasks, hasLength(1));
    expect(activeTasks.single['id'], 'task-1');
    expect(activeTasks.single['status'], 'review');
    expect(activeTasks.single['startedAt'], isA<String>());
    expect(activeTasks.single['provider'], ProviderIdentity.codex);
    expect(activeTasks.single['providerLabel'], 'Codex');
    expect(DateTime.parse(activeTasks.single['startedAt'] as String), isA<DateTime>());
  });

  test('status change frame preserves running-first then review startedAt ordering', () async {
    await tasks.create(
      id: 'task-running-earliest',
      title: 'Running first',
      description: 'Do work',
      type: TaskType.coding,
      autoStart: true,
      now: DateTime.parse('2026-03-10T10:00:00Z'),
    );
    await tasks.transition('task-running-earliest', TaskStatus.running, now: DateTime.parse('2026-03-10T10:01:00Z'));

    await tasks.create(
      id: 'task-review-existing',
      title: 'Existing review',
      description: 'Check work',
      type: TaskType.coding,
      autoStart: true,
      now: DateTime.parse('2026-03-10T10:02:00Z'),
    );
    await tasks.transition('task-review-existing', TaskStatus.running, now: DateTime.parse('2026-03-10T10:03:00Z'));
    await tasks.transition('task-review-existing', TaskStatus.review, now: DateTime.parse('2026-03-10T10:04:00Z'));

    await tasks.create(
      id: 'task-running-later',
      title: 'Running later',
      description: 'More work',
      type: TaskType.coding,
      autoStart: true,
      now: DateTime.parse('2026-03-10T10:05:00Z'),
    );
    await tasks.transition('task-running-later', TaskStatus.running, now: DateTime.parse('2026-03-10T10:06:00Z'));

    final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/events')));
    final iterator = StreamIterator(response.read().transform(utf8.decoder));
    addTearDown(iterator.cancel);
    final connectedPayload = await nextFramePayload(iterator);
    expect(connectedPayload['type'], 'connected');

    await tasks.transition('task-running-later', TaskStatus.review, now: DateTime.parse('2026-03-10T10:07:00Z'));
    eventBus.fire(
      TaskStatusChangedEvent(
        taskId: 'task-running-later',
        oldStatus: TaskStatus.running,
        newStatus: TaskStatus.review,
        trigger: 'system',
        timestamp: DateTime.parse('2026-03-10T10:07:00Z'),
      ),
    );

    final payload = await nextFramePayload(iterator);

    expect(payload['type'], 'task_status_changed');
    final activeTasks = (payload['activeTasks'] as List<dynamic>).cast<Map<String, dynamic>>();
    expect(activeTasks.map((task) => task['id']), [
      'task-running-earliest',
      'task-review-existing',
      'task-running-later',
    ]);
    expect(activeTasks[1]['status'], 'review');
    expect(activeTasks[2]['status'], 'review');
  });

  test('connected frame returns empty activeTasks when all tasks are terminal', () async {
    await tasks.create(
      id: 'task-done',
      title: 'Done task',
      description: 'Do work',
      type: TaskType.coding,
      autoStart: true,
      now: DateTime.parse('2026-03-10T11:00:00Z'),
    );
    await tasks.transition('task-done', TaskStatus.running, now: DateTime.parse('2026-03-10T11:05:00Z'));
    await tasks.transition('task-done', TaskStatus.failed, now: DateTime.parse('2026-03-10T11:20:00Z'));

    final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/events')));
    final iterator = StreamIterator(response.read().transform(utf8.decoder));
    addTearDown(iterator.cancel);

    final payload = await nextFramePayload(iterator);

    expect(payload['type'], 'connected');
    expect(payload['activeTasks'], isA<List<dynamic>>());
    final activeTasks = (payload['activeTasks'] as List<dynamic>).cast<Map<String, dynamic>>();
    expect(activeTasks, isEmpty);
  });

  test('status change frame returns empty activeTasks when all tasks are terminal', () async {
    await tasks.create(
      id: 'task-done',
      title: 'Done task',
      description: 'Do work',
      type: TaskType.coding,
      autoStart: true,
      now: DateTime.parse('2026-03-10T11:00:00Z'),
    );
    await tasks.transition('task-done', TaskStatus.running, now: DateTime.parse('2026-03-10T11:05:00Z'));

    final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/events')));
    final iterator = StreamIterator(response.read().transform(utf8.decoder));
    addTearDown(iterator.cancel);
    final connectedPayload = await nextFramePayload(iterator);
    expect(connectedPayload['type'], 'connected');

    await tasks.transition('task-done', TaskStatus.failed, now: DateTime.parse('2026-03-10T11:20:00Z'));
    eventBus.fire(
      TaskStatusChangedEvent(
        taskId: 'task-done',
        oldStatus: TaskStatus.running,
        newStatus: TaskStatus.failed,
        trigger: 'system',
        timestamp: DateTime.parse('2026-03-10T11:20:00Z'),
      ),
    );

    final payload = await nextFramePayload(iterator);

    expect(payload['type'], 'task_status_changed');
    expect(payload['taskId'], 'task-done');
    expect(payload['reviewCount'], 0);
    expect(payload['activeTasks'], isA<List<dynamic>>());
    final activeTasks = (payload['activeTasks'] as List<dynamic>).cast<Map<String, dynamic>>();
    expect(activeTasks, isEmpty);
  });

  group('task_progress SSE events', () {
    late TaskProgressTracker progressTracker;

    setUp(() {
      progressTracker = TaskProgressTracker(eventBus: eventBus, tasks: tasks);
      progressTracker.start();
      handler = taskSseRoutes(tasks, eventBus, progressTracker: progressTracker).call;
    });

    tearDown(() {
      progressTracker.dispose();
    });

    test('existing tests pass with progressTracker: null (no behavior change)', () async {
      // Re-create handler without tracker to confirm no regression.
      handler = taskSseRoutes(tasks, eventBus).call;
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/events')));
      expect(response.statusCode, 200);
      final iterator = StreamIterator(response.read().transform(utf8.decoder));
      addTearDown(iterator.cancel);
      final payload = await nextFramePayload(iterator);
      expect(payload['type'], 'connected');
    });

    test('task_progress event delivered to SSE client on toolCalled', () async {
      await tasks.create(
        id: 'task-running',
        title: 'Running task',
        description: 'do work',
        type: TaskType.coding,
        autoStart: true,
      );
      await tasks.transition('task-running', TaskStatus.running);

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/events')));
      final iterator = StreamIterator(response.read().transform(utf8.decoder));
      addTearDown(iterator.cancel);
      await nextFramePayload(iterator); // Consume connected frame.

      // Fire statusChanged then toolCalled via EventBus.
      eventBus.fire(
        TaskEventCreatedEvent(
          taskId: 'task-running',
          eventId: 'evt-1',
          kind: 'statusChanged',
          details: {'newStatus': 'running'},
          timestamp: DateTime.now(),
        ),
      );
      eventBus.fire(
        TaskEventCreatedEvent(
          taskId: 'task-running',
          eventId: 'evt-2',
          kind: 'toolCalled',
          details: {'name': 'Read', 'context': 'lib/main.dart'},
          timestamp: DateTime.now(),
        ),
      );

      await Future<void>.delayed(Duration.zero);

      final payload = await nextFramePayloadOfType(iterator, 'task_progress');
      expect(payload['taskId'], 'task-running');
      expect(payload['currentActivity'], 'Reading lib/main.dart');
      expect(payload['isComplete'], isFalse);
    });

    test('isComplete: true delivered when task status changes away from running', () async {
      await tasks.create(
        id: 'task-complete',
        title: 'Completing task',
        description: 'do work',
        type: TaskType.coding,
        autoStart: true,
      );
      await tasks.transition('task-complete', TaskStatus.running);

      final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/events')));
      final iterator = StreamIterator(response.read().transform(utf8.decoder));
      addTearDown(iterator.cancel);
      await nextFramePayload(iterator); // Consume connected frame.

      // Start state.
      eventBus.fire(
        TaskEventCreatedEvent(
          taskId: 'task-complete',
          eventId: 'evt-1',
          kind: 'statusChanged',
          details: {'newStatus': 'running'},
          timestamp: DateTime.now(),
        ),
      );
      // Token event to emit a snapshot.
      eventBus.fire(
        TaskEventCreatedEvent(
          taskId: 'task-complete',
          eventId: 'evt-2',
          kind: 'tokenUpdate',
          details: {'inputTokens': 100, 'outputTokens': 50},
          timestamp: DateTime.now(),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await nextFramePayloadOfType(iterator, 'task_progress'); // Consume progress snapshot.

      // Task completes.
      eventBus.fire(
        TaskEventCreatedEvent(
          taskId: 'task-complete',
          eventId: 'evt-3',
          kind: 'statusChanged',
          details: {'newStatus': 'done'},
          timestamp: DateTime.now(),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final completion = await nextFramePayloadOfType(iterator, 'task_progress');
      expect(completion['taskId'], 'task-complete');
      expect(completion['isComplete'], isTrue);
    });
  });

  group('task_event SSE forwarding', () {
    test('TaskEventCreatedEvent forwarded as task_event frame with all fields', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/events')));
      final iterator = StreamIterator(response.read().transform(utf8.decoder));
      addTearDown(iterator.cancel);
      await nextFramePayload(iterator); // Consume connected frame.

      final ts = DateTime.parse('2026-03-24T10:00:00.000Z');
      eventBus.fire(
        TaskEventCreatedEvent(
          taskId: 'task-xyz',
          eventId: 'evt-abc',
          kind: 'toolCalled',
          details: {'name': 'Read', 'success': true, 'context': 'lib/main.dart'},
          timestamp: ts,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      final payload = await nextFramePayloadOfType(iterator, 'task_event');
      expect(payload['type'], 'task_event');
      expect(payload['taskId'], 'task-xyz');
      expect(payload['eventId'], 'evt-abc');
      expect(payload['kind'], 'toolCalled');
      expect(payload['details'], {'name': 'Read', 'success': true, 'context': 'lib/main.dart'});
      expect(payload['text'], 'Read lib/main.dart');
      expect(payload['timestamp'], ts.toIso8601String());
    });

    test('task_event forwarded for all event kinds', () async {
      final response = await handler(Request('GET', Uri.parse('http://localhost/api/tasks/events')));
      final iterator = StreamIterator(response.read().transform(utf8.decoder));
      addTearDown(iterator.cancel);
      await nextFramePayload(iterator); // Consume connected frame.

      for (final kind in ['statusChanged', 'artifactCreated', 'pushBack', 'tokenUpdate', 'taskError']) {
        eventBus.fire(
          TaskEventCreatedEvent(
            taskId: 'task-1',
            eventId: 'evt-$kind',
            kind: kind,
            details: {},
            timestamp: DateTime.now(),
          ),
        );
      }
      await Future<void>.delayed(Duration.zero);

      final kinds = <String>[];
      for (var i = 0; i < 5; i++) {
        final payload = await nextFramePayloadOfType(iterator, 'task_event');
        kinds.add(payload['kind'] as String);
      }
      expect(kinds, containsAll(['statusChanged', 'artifactCreated', 'pushBack', 'tokenUpdate', 'taskError']));
    });
  });
}
