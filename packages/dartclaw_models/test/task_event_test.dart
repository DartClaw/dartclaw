import 'package:dartclaw_models/dartclaw_models.dart';
import 'package:test/test.dart';

void main() {
  group('TaskEventKind.fromName', () {
    test('resolves all 7 known kinds', () {
      expect(TaskEventKind.fromName('statusChanged'), isA<StatusChanged>());
      expect(TaskEventKind.fromName('toolCalled'), isA<ToolCalled>());
      expect(TaskEventKind.fromName('artifactCreated'), isA<ArtifactCreated>());
      expect(TaskEventKind.fromName('pushBack'), isA<PushBack>());
      expect(TaskEventKind.fromName('tokenUpdate'), isA<TokenUpdate>());
      expect(TaskEventKind.fromName('error'), isA<TaskErrorEvent>());
      expect(TaskEventKind.fromName('compaction'), isA<Compaction>());
    });

    test('throws ArgumentError for unknown name', () {
      expect(() => TaskEventKind.fromName('unknown'), throwsArgumentError);
    });

    test('name getter matches fromName key', () {
      final kinds = [
        const StatusChanged(),
        const ToolCalled(),
        const ArtifactCreated(),
        const PushBack(),
        const TokenUpdate(),
        const TaskErrorEvent(),
      ];
      for (final kind in kinds) {
        expect(TaskEventKind.fromName(kind.name).name, kind.name);
      }
    });
  });

  group('TaskEvent', () {
    test('constructs with all fields', () {
      final ts = DateTime.utc(2026, 3, 24, 10, 0, 0);
      final event = TaskEvent(
        id: 'evt-1',
        taskId: 'task-A',
        timestamp: ts,
        kind: const StatusChanged(),
        details: {'oldStatus': 'draft', 'newStatus': 'queued', 'trigger': 'system'},
      );
      expect(event.id, 'evt-1');
      expect(event.taskId, 'task-A');
      expect(event.timestamp, ts);
      expect(event.kind, isA<StatusChanged>());
      expect(event.details['oldStatus'], 'draft');
    });

    test('details defaults to empty map', () {
      final event = TaskEvent(
        id: 'evt-2',
        taskId: 'task-B',
        timestamp: DateTime.utc(2026, 3, 24),
        kind: const TokenUpdate(),
      );
      expect(event.details, isEmpty);
    });

    test('toJson() output shape', () {
      final ts = DateTime.utc(2026, 3, 24, 10, 0, 0);
      final event = TaskEvent(
        id: 'evt-3',
        taskId: 'task-C',
        timestamp: ts,
        kind: const ToolCalled(),
        details: {'name': 'bash', 'success': true, 'durationMs': 100},
      );
      final json = event.toJson();
      expect(json['id'], 'evt-3');
      expect(json['taskId'], 'task-C');
      expect(json['kind'], 'toolCalled');
      expect(json['timestamp'], ts.toIso8601String());
      expect((json['details'] as Map<String, dynamic>)['name'], 'bash');
    });

    test('fromJson() round-trip', () {
      final ts = DateTime.utc(2026, 3, 24, 11, 30, 0);
      final original = TaskEvent(
        id: 'evt-4',
        taskId: 'task-D',
        timestamp: ts,
        kind: const PushBack(),
        details: {'comment': 'Needs more work'},
      );
      final restored = TaskEvent.fromJson(original.toJson());
      expect(restored.id, original.id);
      expect(restored.taskId, original.taskId);
      expect(restored.timestamp, original.timestamp);
      expect(restored.kind.name, original.kind.name);
      expect(restored.details['comment'], 'Needs more work');
    });

    test('round-trip with all 7 event kinds', () {
      final ts = DateTime.utc(2026, 3, 24);
      final kinds = [
        const StatusChanged(),
        const ToolCalled(),
        const ArtifactCreated(),
        const PushBack(),
        const TokenUpdate(),
        const TaskErrorEvent(),
        const Compaction(),
      ];
      for (final kind in kinds) {
        final event = TaskEvent(id: 'id', taskId: 'task', timestamp: ts, kind: kind);
        final restored = TaskEvent.fromJson(event.toJson());
        expect(restored.kind.name, kind.name, reason: 'Kind ${kind.name} failed round-trip');
      }
    });

    test('equality and hashCode', () {
      final ts = DateTime.utc(2026, 3, 24);
      final a = TaskEvent(id: 'evt-5', taskId: 'task-E', timestamp: ts, kind: const TaskErrorEvent());
      final b = TaskEvent(id: 'evt-5', taskId: 'task-E', timestamp: ts, kind: const TaskErrorEvent());
      final c = TaskEvent(id: 'evt-6', taskId: 'task-E', timestamp: ts, kind: const TaskErrorEvent());
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(equals(c)));
    });

    test('toString() includes kind and id', () {
      final event = TaskEvent(
        id: 'evt-7',
        taskId: 'task-F',
        timestamp: DateTime.utc(2026, 3, 24),
        kind: const ArtifactCreated(),
      );
      expect(event.toString(), contains('artifactCreated'));
      expect(event.toString(), contains('evt-7'));
    });

    test('fromJson() with missing details key uses empty map', () {
      final json = {
        'id': 'evt-8',
        'taskId': 'task-G',
        'timestamp': '2026-03-24T10:00:00.000Z',
        'kind': 'error',
        // no 'details' key
      };
      final event = TaskEvent.fromJson(json);
      expect(event.details, isEmpty);
    });
  });
}
