import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('TaskArtifact', () {
    test('creates with all fields', () {
      final createdAt = DateTime.parse('2026-03-10T10:00:00Z');
      final artifact = TaskArtifact(
        id: 'artifact-1',
        taskId: 'task-1',
        name: 'Patch',
        kind: ArtifactKind.diff,
        path: '/tmp/patch.diff',
        createdAt: createdAt,
      );

      expect(artifact.id, 'artifact-1');
      expect(artifact.taskId, 'task-1');
      expect(artifact.name, 'Patch');
      expect(artifact.kind, ArtifactKind.diff);
      expect(artifact.path, '/tmp/patch.diff');
      expect(artifact.createdAt, createdAt);
    });

    group('JSON serialization', () {
      test('round-trips through toJson and fromJson', () {
        final artifact = TaskArtifact(
          id: 'artifact-1',
          taskId: 'task-1',
          name: 'Spec',
          kind: ArtifactKind.document,
          path: '/tmp/spec.md',
          createdAt: DateTime.parse('2026-03-10T10:00:00Z'),
        );
        final restored = TaskArtifact.fromJson(artifact.toJson());

        expect(restored.toJson(), equals(artifact.toJson()));
      });

      test('toJson serializes kind as string', () {
        final artifact = TaskArtifact(
          id: 'artifact-1',
          taskId: 'task-1',
          name: 'Data',
          kind: ArtifactKind.data,
          path: '/tmp/data.json',
          createdAt: DateTime.parse('2026-03-10T10:00:00Z'),
        );

        expect(artifact.toJson()['kind'], 'data');
      });

      test('fromJson parses kind enum', () {
        final artifact = TaskArtifact.fromJson({
          'id': 'artifact-1',
          'taskId': 'task-1',
          'name': 'Patch',
          'kind': 'diff',
          'path': '/tmp/patch.diff',
          'createdAt': '2026-03-10T10:00:00Z',
        });

        expect(artifact.kind, ArtifactKind.diff);
      });
    });
  });
}
