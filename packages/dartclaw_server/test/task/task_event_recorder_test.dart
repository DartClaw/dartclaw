import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/task/task_event_recorder.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Database db;
  late TaskEventService eventService;
  late EventBus bus;
  late TaskEventRecorder recorder;

  setUp(() {
    db = openTaskDbInMemory();
    eventService = TaskEventService(db);
    bus = EventBus();
    recorder = TaskEventRecorder(eventService: eventService, eventBus: bus);
  });

  tearDown(() async {
    db.close();
    if (!bus.isDisposed) await bus.dispose();
  });

  test('recordStatusChanged inserts statusChanged event with correct details', () {
    recorder.recordStatusChanged(
      'task-1',
      oldStatus: TaskStatus.draft,
      newStatus: TaskStatus.queued,
      trigger: 'system',
    );

    final events = eventService.listForTask('task-1');
    expect(events, hasLength(1));
    expect(events[0].kind.name, 'statusChanged');
    expect(events[0].details['oldStatus'], 'draft');
    expect(events[0].details['newStatus'], 'queued');
    expect(events[0].details['trigger'], 'system');
  });

  test('recordToolCalled inserts toolCalled event', () {
    recorder.recordToolCalled(
      'task-2',
      name: 'bash',
      success: true,
      durationMs: 150,
      errorType: null,
      context: 'dart test',
    );

    final events = eventService.listForTask('task-2');
    expect(events, hasLength(1));
    expect(events[0].kind.name, 'toolCalled');
    expect(events[0].details['name'], 'bash');
    expect(events[0].details['success'], isTrue);
    expect(events[0].details['durationMs'], 150);
    expect(events[0].details.containsKey('errorType'), isFalse);
    expect(events[0].details['context'], 'dart test');
  });

  test('recordToolCalled includes errorType when provided', () {
    recorder.recordToolCalled(
      'task-3',
      name: 'edit',
      success: false,
      durationMs: 30,
      errorType: 'tool_error',
      context: 'lib/main.dart',
    );

    final events = eventService.listForTask('task-3');
    expect(events[0].details['errorType'], 'tool_error');
    expect(events[0].details['context'], 'lib/main.dart');
  });

  test('recordArtifactCreated inserts artifactCreated event', () {
    recorder.recordArtifactCreated('task-4', name: 'diff.json', kind: 'diff');

    final events = eventService.listForTask('task-4');
    expect(events, hasLength(1));
    expect(events[0].kind.name, 'artifactCreated');
    expect(events[0].details['name'], 'diff.json');
    expect(events[0].details['kind'], 'diff');
  });

  test('recordPushBack inserts pushBack event with comment', () {
    recorder.recordPushBack('task-5', comment: 'Needs better tests');

    final events = eventService.listForTask('task-5');
    expect(events, hasLength(1));
    expect(events[0].kind.name, 'pushBack');
    expect(events[0].details['comment'], 'Needs better tests');
  });

  test('recordTokenUpdate inserts tokenUpdate event with counts', () {
    recorder.recordTokenUpdate('task-6', inputTokens: 100, outputTokens: 50, cacheReadTokens: 200);

    final events = eventService.listForTask('task-6');
    expect(events, hasLength(1));
    expect(events[0].kind.name, 'tokenUpdate');
    expect(events[0].details['inputTokens'], 100);
    expect(events[0].details['outputTokens'], 50);
    expect(events[0].details['cacheReadTokens'], 200);
    expect(events[0].details.containsKey('cacheWriteTokens'), isFalse);
  });

  test('recordError inserts error event with message', () {
    recorder.recordError('task-7', message: 'Unexpected failure');

    final events = eventService.listForTask('task-7');
    expect(events, hasLength(1));
    expect(events[0].kind.name, 'error');
    expect(events[0].details['message'], 'Unexpected failure');
  });

  test('each recording fires TaskEventCreatedEvent on EventBus', () async {
    final fired = <TaskEventCreatedEvent>[];
    bus.on<TaskEventCreatedEvent>().listen(fired.add);

    recorder.recordStatusChanged(
      'task-8',
      oldStatus: TaskStatus.queued,
      newStatus: TaskStatus.running,
      trigger: 'test',
    );
    recorder.recordError('task-8', message: 'oops');
    await Future<void>.delayed(Duration.zero);

    expect(fired, hasLength(2));
    expect(fired[0].kind, 'statusChanged');
    expect(fired[0].taskId, 'task-8');
    expect(fired[1].kind, 'error');
  });

  test('with null EventBus, recording still inserts to SQLite (no exception)', () {
    final noEventBusRecorder = TaskEventRecorder(eventService: eventService);
    expect(() => noEventBusRecorder.recordError('task-9', message: 'no bus'), returnsNormally);
    expect(eventService.listForTask('task-9'), hasLength(1));
  });
}
