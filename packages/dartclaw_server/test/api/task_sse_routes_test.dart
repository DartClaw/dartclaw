import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/api/task_sse_routes.dart';
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
}
