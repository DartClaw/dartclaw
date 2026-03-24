import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

void main() {
  group('TaskArtifact', () {
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

    group('ArtifactKind.pr', () {
      test('byName resolves pr', () {
        expect(ArtifactKind.values.byName('pr'), ArtifactKind.pr);
      });

      test('round-trips through toJson and fromJson', () {
        final artifact = TaskArtifact(
          id: 'artifact-pr',
          taskId: 'task-1',
          name: 'Pull Request',
          kind: ArtifactKind.pr,
          path: 'https://github.com/u/r/pull/42',
          createdAt: DateTime.utc(2026, 3, 24, 12, 0, 0),
        );
        final restored = TaskArtifact.fromJson(artifact.toJson());
        expect(restored.kind, ArtifactKind.pr);
        expect(restored.path, 'https://github.com/u/r/pull/42');
      });
    });
  });
}
