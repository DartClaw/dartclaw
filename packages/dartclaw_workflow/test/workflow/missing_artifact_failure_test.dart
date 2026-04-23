import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:test/test.dart';

void main() {
  group('MissingArtifactFailure', () {
    test('carries claimed and missing paths', () {
      const failure = MissingArtifactFailure(
        claimedPaths: ['docs/prd.md'],
        missingPaths: ['docs/prd.md'],
        worktreePath: '/tmp/worktree',
        fieldName: 'prd',
        reason: 'path claimed but not present in worktree diff',
      );

      expect(failure.claimedPaths, ['docs/prd.md']);
      expect(failure.missingPaths, ['docs/prd.md']);
      expect(failure.worktreePath, '/tmp/worktree');
      expect(failure.fieldName, 'prd');
      expect(failure.reason, 'path claimed but not present in worktree diff');
      expect(failure.toString(), contains('docs/prd.md'));
    });

    test('can be caught by type', () {
      Object? caught;

      try {
        throw const MissingArtifactFailure(
          claimedPaths: ['fis/s01.md'],
          missingPaths: ['fis/s01.md'],
          worktreePath: '/tmp/worktree',
          fieldName: 'story_specs',
          reason: 'path claimed but not present in worktree diff',
        );
      } on MissingArtifactFailure catch (error) {
        caught = error;
      }

      expect(caught, isA<MissingArtifactFailure>());
    });
  });
}
