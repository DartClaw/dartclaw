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
  });
}
