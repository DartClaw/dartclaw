import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

TaskEvent _makeEvent({
  required String id,
  String taskId = 'task-1',
  TaskEventKind kind = const StatusChanged(),
  Map<String, dynamic> details = const {},
  DateTime? timestamp,
}) {
  return TaskEvent(
    id: id,
    taskId: taskId,
    timestamp: timestamp ?? DateTime.utc(2026, 3, 24, 10, 0, 0),
    kind: kind,
    details: details,
  );
}

void main() {
  late Database db;
  late TaskEventService service;

  setUp(() {
    db = openTaskDbInMemory();
    service = TaskEventService(db);
  });

  tearDown(() {
    db.close();
  });

  test('creates task_events table and indexes', () {
    final names =
        db
            .select("SELECT name FROM sqlite_master WHERE type IN ('table', 'index') ORDER BY name")
            .map((row) => row['name'])
            .toList();
    expect(names, contains('task_events'));
    expect(names, contains('idx_task_events_task'));
    expect(names, contains('idx_task_events_task_kind'));
    expect(names, contains('idx_task_events_timestamp'));
  });

  test('insert and retrieve by taskId', () {
    final event = _makeEvent(
      id: 'evt-1',
      taskId: 'task-A',
      kind: const StatusChanged(),
      details: {'oldStatus': 'draft', 'newStatus': 'queued', 'trigger': 'system'},
    );
    service.insert(event);

    final result = service.listForTask('task-A');
    expect(result, hasLength(1));
    expect(result[0].id, 'evt-1');
    expect(result[0].kind.name, 'statusChanged');
    expect(result[0].details['oldStatus'], 'draft');
  });

  test('insert multiple events and verify chronological order', () {
    service.insert(_makeEvent(id: 'evt-1', taskId: 'task-B', timestamp: DateTime.utc(2026, 3, 24, 10, 0, 0)));
    service.insert(_makeEvent(id: 'evt-2', taskId: 'task-B', timestamp: DateTime.utc(2026, 3, 24, 11, 0, 0)));
    service.insert(_makeEvent(id: 'evt-3', taskId: 'task-B', timestamp: DateTime.utc(2026, 3, 24, 12, 0, 0)));

    final result = service.listForTask('task-B');
    expect(result, hasLength(3));
    expect(result[0].id, 'evt-1');
    expect(result[1].id, 'evt-2');
    expect(result[2].id, 'evt-3');
  });

  test('listForTask with kind filter returns only matching events', () {
    service.insert(_makeEvent(id: 'evt-1', taskId: 'task-C', kind: const StatusChanged()));
    service.insert(_makeEvent(id: 'evt-2', taskId: 'task-C', kind: const ToolCalled()));
    service.insert(_makeEvent(id: 'evt-3', taskId: 'task-C', kind: const ToolCalled()));

    final result = service.listForTask('task-C', kind: const ToolCalled());
    expect(result, hasLength(2));
    for (final e in result) {
      expect(e.kind.name, 'toolCalled');
    }
  });

  test('listForTask with limit returns at most N events', () {
    for (var i = 0; i < 5; i++) {
      service.insert(
        _makeEvent(id: 'evt-$i', taskId: 'task-D', timestamp: DateTime.utc(2026, 3, 24, i, 0, 0)),
      );
    }
    final result = service.listForTask('task-D', limit: 3);
    expect(result, hasLength(3));
  });

  test('listForTask with kind + limit combined', () {
    for (var i = 0; i < 4; i++) {
      service.insert(
        _makeEvent(id: 'tool-$i', taskId: 'task-E', kind: const ToolCalled(), timestamp: DateTime.utc(2026, 3, 24, i, 0, 0)),
      );
    }
    service.insert(_makeEvent(id: 'status-1', taskId: 'task-E', kind: const StatusChanged()));

    final result = service.listForTask('task-E', kind: const ToolCalled(), limit: 2);
    expect(result, hasLength(2));
    for (final e in result) {
      expect(e.kind.name, 'toolCalled');
    }
  });

  test('countForTask returns correct count', () {
    service.insert(_makeEvent(id: 'evt-1', taskId: 'task-F'));
    service.insert(_makeEvent(id: 'evt-2', taskId: 'task-F'));
    service.insert(_makeEvent(id: 'evt-3', taskId: 'task-G'));

    expect(service.countForTask('task-F'), 2);
    expect(service.countForTask('task-G'), 1);
    expect(service.countForTask('task-H'), 0);
  });

  test('countForTask with kind filter', () {
    service.insert(_makeEvent(id: 'evt-1', taskId: 'task-I', kind: const StatusChanged()));
    service.insert(_makeEvent(id: 'evt-2', taskId: 'task-I', kind: const ToolCalled()));
    service.insert(_makeEvent(id: 'evt-3', taskId: 'task-I', kind: const ToolCalled()));

    expect(service.countForTask('task-I', kind: const ToolCalled()), 2);
    expect(service.countForTask('task-I', kind: const StatusChanged()), 1);
    expect(service.countForTask('task-I', kind: const TaskErrorEvent()), 0);
  });

  test('insert with empty details map, details round-trips correctly', () {
    service.insert(_makeEvent(id: 'evt-empty', taskId: 'task-J', details: const {}));

    final result = service.listForTask('task-J');
    expect(result, hasLength(1));
    expect(result[0].details, isEmpty);
  });

  test('listForTask returns only events for the requested task', () {
    service.insert(_makeEvent(id: 'evt-1', taskId: 'task-K'));
    service.insert(_makeEvent(id: 'evt-2', taskId: 'task-L'));
    service.insert(_makeEvent(id: 'evt-3', taskId: 'task-K'));

    expect(service.listForTask('task-K'), hasLength(2));
    expect(service.listForTask('task-L'), hasLength(1));
  });

  test('each of the 6 kinds round-trips through insert + list', () {
    final kinds = [
      const StatusChanged(),
      const ToolCalled(),
      const ArtifactCreated(),
      const PushBack(),
      const TokenUpdate(),
      const TaskErrorEvent(),
    ];
    for (var i = 0; i < kinds.length; i++) {
      service.insert(
        _makeEvent(
          id: 'kind-$i',
          taskId: 'task-M',
          kind: kinds[i],
          timestamp: DateTime.utc(2026, 3, 24, i, 0, 0),
        ),
      );
    }
    final result = service.listForTask('task-M');
    expect(result, hasLength(6));
    for (var i = 0; i < kinds.length; i++) {
      expect(result[i].kind.name, kinds[i].name);
    }
  });

  test('details with complex values round-trips correctly', () {
    final details = {
      'name': 'bash',
      'success': true,
      'durationMs': 250,
      'errorType': 'tool_error',
    };
    service.insert(_makeEvent(id: 'evt-complex', taskId: 'task-N', kind: const ToolCalled(), details: details));

    final result = service.listForTask('task-N');
    expect(result[0].details['name'], 'bash');
    expect(result[0].details['success'], isTrue);
    expect(result[0].details['durationMs'], 250);
    expect(result[0].details['errorType'], 'tool_error');
  });

  test('malformed JSON in details column returns empty map gracefully', () {
    // Insert malformed JSON directly into the DB to simulate corruption.
    db.execute(
      "INSERT INTO task_events (id, task_id, timestamp, kind, details) VALUES ('bad-evt', 'task-O', '2026-03-24T10:00:00.000Z', 'error', 'not-valid-json')",
    );
    final result = service.listForTask('task-O');
    expect(result, hasLength(1));
    expect(result[0].details, isEmpty);
  });
}
