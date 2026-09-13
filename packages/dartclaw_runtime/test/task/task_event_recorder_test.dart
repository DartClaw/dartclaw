import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_runtime/src/task/task_event_recorder.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show openPreparedTaskBackend;
import 'package:test/test.dart';

void main() {
  late SqliteBackend backend;
  late TaskEventService eventService;
  late EventBus bus;
  late TaskEventRecorder recorder;

  setUp(() async {
    backend = await openPreparedTaskBackend();
    eventService = TaskEventService(backend);
    bus = EventBus();
    recorder = TaskEventRecorder(eventService: eventService, eventBus: bus);
  });

  tearDown(() async {
    await backend.close();
    if (!bus.isDisposed) await bus.dispose();
  });

  test('recordStatusChanged inserts statusChanged event with correct details', () async {
    await recorder.recordStatusChanged(
      'task-1',
      oldStatus: TaskStatus.draft,
      newStatus: TaskStatus.queued,
      trigger: 'system',
    );

    final events = await eventService.listForTask('task-1');
    expect(events, hasLength(1));
    expect(events[0].kind.name, 'statusChanged');
    expect(events[0].details['oldStatus'], 'draft');
    expect(events[0].details['newStatus'], 'queued');
    expect(events[0].details['trigger'], 'system');
  });

  test('recordToolCalled inserts toolCalled event', () async {
    await recorder.recordToolCalled(
      'task-2',
      name: 'bash',
      success: true,
      durationMs: 150,
      errorType: null,
      context: 'dart test',
    );

    final events = await eventService.listForTask('task-2');
    expect(events, hasLength(1));
    expect(events[0].kind.name, 'toolCalled');
    expect(events[0].details['name'], 'bash');
    expect(events[0].details['success'], isTrue);
    expect(events[0].details['durationMs'], 150);
    expect(events[0].details.containsKey('errorType'), isFalse);
    expect(events[0].details['context'], 'dart test');
  });

  test('recordToolCalled includes errorType when provided', () async {
    await recorder.recordToolCalled(
      'task-3',
      name: 'edit',
      success: false,
      durationMs: 30,
      errorType: 'tool_error',
      context: 'lib/main.dart',
    );

    final events = await eventService.listForTask('task-3');
    expect(events[0].details['errorType'], 'tool_error');
    expect(events[0].details['context'], 'lib/main.dart');
  });

  test('recordArtifactCreated inserts artifactCreated event', () async {
    await recorder.recordArtifactCreated('task-4', name: 'diff.json', kind: 'diff');

    final events = await eventService.listForTask('task-4');
    expect(events, hasLength(1));
    expect(events[0].kind.name, 'artifactCreated');
    expect(events[0].details['name'], 'diff.json');
    expect(events[0].details['kind'], 'diff');
  });

  test('recordStructuredOutputFinalizerUsed inserts structuredOutputFinalizerUsed event', () async {
    await recorder.recordStructuredOutputFinalizerUsed('task-4f', stepId: 'plan', outputKey: 'stories');

    final events = await eventService.listForTask('task-4f');
    expect(events, hasLength(1));
    expect(events[0].kind.name, 'structuredOutputFinalizerUsed');
    expect(events[0].details['stepId'], 'plan');
    expect(events[0].details['outputKey'], 'stories');
  });

  test('recordStructuredOutputValidationFailed inserts structuredOutputValidationFailed event', () async {
    await recorder.recordStructuredOutputValidationFailed(
      'task-4v',
      stepId: 'review',
      outputKey: 'verdict',
      failureReason: 'missing_envelope',
    );

    final events = await eventService.listForTask('task-4v');
    expect(events, hasLength(1));
    expect(events[0].kind.name, 'structuredOutputValidationFailed');
    expect(events[0].details['stepId'], 'review');
    expect(events[0].details['outputKey'], 'verdict');
    expect(events[0].details['failureReason'], 'missing_envelope');
  });

  test('recordStructuredOutputFallbackUsed inserts structuredOutputFallbackUsed event', () async {
    await recorder.recordStructuredOutputFallbackUsed(
      'task-4b',
      stepId: 'review',
      outputKey: 'verdict',
      failureReason: 'missing_payload',
    );

    final events = await eventService.listForTask('task-4b');
    expect(events, hasLength(1));
    expect(events[0].kind.name, 'structuredOutputFallbackUsed');
    expect(events[0].details['stepId'], 'review');
    expect(events[0].details['outputKey'], 'verdict');
    expect(events[0].details['failureReason'], 'missing_payload');
    expect(events[0].details.containsKey('providerSubtype'), isFalse);
  });

  test('recordPushBack inserts pushBack event with comment', () async {
    await recorder.recordPushBack('task-5', comment: 'Needs better tests');

    final events = await eventService.listForTask('task-5');
    expect(events, hasLength(1));
    expect(events[0].kind.name, 'pushBack');
    expect(events[0].details['comment'], 'Needs better tests');
  });

  test('recordTokenUpdate inserts tokenUpdate event with counts', () async {
    await recorder.recordTokenUpdate('task-6', inputTokens: 100, outputTokens: 50, cacheReadTokens: 200);

    final events = await eventService.listForTask('task-6');
    expect(events, hasLength(1));
    expect(events[0].kind.name, 'tokenUpdate');
    expect(events[0].details['inputTokens'], 100);
    expect(events[0].details['outputTokens'], 50);
    expect(events[0].details['cacheReadTokens'], 200);
    expect(events[0].details.containsKey('cacheWriteTokens'), isFalse);
  });

  test('recordError inserts error event with message', () async {
    await recorder.recordError('task-7', message: 'Unexpected failure');

    final events = await eventService.listForTask('task-7');
    expect(events, hasLength(1));
    expect(events[0].kind.name, 'taskError');
    expect(events[0].details['message'], 'Unexpected failure');
  });

  test('each recording fires TaskEventCreatedEvent on EventBus', () async {
    final fired = <TaskEventCreatedEvent>[];
    bus.on<TaskEventCreatedEvent>().listen(fired.add);

    await recorder.recordStatusChanged(
      'task-8',
      oldStatus: TaskStatus.queued,
      newStatus: TaskStatus.running,
      trigger: 'test',
    );
    await recorder.recordError('task-8', message: 'oops');
    await Future<void>.delayed(Duration.zero);

    expect(fired, hasLength(2));
    expect(fired[0].kind, 'statusChanged');
    expect(fired[0].taskId, 'task-8');
    expect(fired[1].kind, 'taskError');
  });

  test('recordCompaction inserts compaction event with trigger, sessionId, and optional preTokens', () async {
    await recorder.recordCompaction('task-c', trigger: 'auto', sessionId: 'sess-xyz', preTokens: 142857);

    final events = await eventService.listForTask('task-c');
    expect(events, hasLength(1));
    expect(events[0].kind.name, 'compaction');
    expect(events[0].details['trigger'], 'auto');
    expect(events[0].details['sessionId'], 'sess-xyz');
    expect(events[0].details['preTokens'], 142857);
  });

  test('recordCompaction omits preTokens when null', () async {
    await recorder.recordCompaction('task-d', trigger: 'manual', sessionId: 'sess-abc');

    final events = await eventService.listForTask('task-d');
    expect(events, hasLength(1));
    expect(events[0].details.containsKey('preTokens'), isFalse);
  });

  test('recordCompaction fires TaskEventCreatedEvent on EventBus', () async {
    final fired = <TaskEventCreatedEvent>[];
    bus.on<TaskEventCreatedEvent>().listen(fired.add);

    await recorder.recordCompaction('task-e', trigger: 'auto', sessionId: 'sess-e', preTokens: 50000);
    await Future<void>.delayed(Duration.zero);

    expect(fired, hasLength(1));
    expect(fired[0].kind, 'compaction');
    expect(fired[0].taskId, 'task-e');
  });

  test('with null EventBus, recording still inserts to SQLite (no exception)', () async {
    final noEventBusRecorder = TaskEventRecorder(eventService: eventService);
    await expectLater(noEventBusRecorder.recordError('task-9', message: 'no bus'), completes);
    expect(await eventService.listForTask('task-9'), hasLength(1));
  });
}
