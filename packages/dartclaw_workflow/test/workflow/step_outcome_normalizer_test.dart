import 'dart:io';

import 'package:dartclaw_workflow/src/workflow/produced_artifact_resolver.dart';
import 'package:dartclaw_workflow/src/workflow/step_outcome_normalizer.dart';
import 'package:dartclaw_workflow/src/workflow/workflow_runner_types.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('resolveStorySpecPathAgainstPlanDir', () {
    test('resolves a workspace-relative path exactly once', () {
      final resolved = resolveStorySpecPathAgainstPlanDir(path: 'fis/s01-foo.md', planDir: 'docs/plans/my-plan/');

      expect(resolved, equals('docs/plans/my-plan/fis/s01-foo.md'));
      expect(
        resolveStorySpecPathAgainstPlanDir(path: resolved, planDir: 'docs/plans/my-plan/'),
        equals('docs/plans/my-plan/fis/s01-foo.md'),
      );
    });

    test('leaves already plan-rooted paths unchanged', () {
      expect(
        resolveStorySpecPathAgainstPlanDir(path: 'docs/specs/demo/fis/s01.md', planDir: 'docs/specs/demo'),
        equals('docs/specs/demo/fis/s01.md'),
      );
    });

    test('normalizes absolute paths without joining plan dir', () {
      final absolute = p.normalize(p.absolute('tmp/fis/s01.md'));

      expect(resolveStorySpecPathAgainstPlanDir(path: absolute, planDir: 'docs/specs/demo'), equals(absolute));
    });
  });

  group('normalizeOutputs', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('step_outcome_normalizer_test_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('reports missing FIS files without sentinel output keys', () {
      final handoff = normalizeOutputs({
        'story_specs': ['docs/plans/foo/fis/a.md', 'docs/plans/foo/fis/b.md'],
      }, StepOutputNormalizationContext(projectRoot: tempDir.path));

      expect(handoff, isA<StepHandoffValidationFailed>());
      final failure = handoff.validationFailure!;
      expect(failure.missingPaths, equals(['docs/plans/foo/fis/a.md', 'docs/plans/foo/fis/b.md']));
      expect(handoff.outputs, isEmpty);
      final reservedPrefix = ['_dartclaw', 'internal', ''].join('.');
      expect(handoff.outputs.keys.any((key) => key.startsWith(reservedPrefix)), isFalse);
    });

    test('normalizes nested story_specs items and succeeds when files exist', () {
      final fisPath = p.join(tempDir.path, 'docs/plans/foo/fis/a.md');
      File(fisPath).createSync(recursive: true);

      final handoff = normalizeOutputs({
        'plan': 'docs/plans/foo/plan.md',
        'story_specs': {
          'items': [
            {'story_id': 'S01', 'spec_path': 'fis/a.md'},
          ],
        },
      }, StepOutputNormalizationContext(planDir: 'docs/plans/foo', projectRoot: tempDir.path));

      expect(handoff, isA<StepHandoffSuccess>());
      final storySpecs = handoff.outputs['story_specs'] as Map<String, Object?>;
      final items = storySpecs['items'] as List;
      expect(items.single, containsPair('spec_path', 'docs/plans/foo/fis/a.md'));
    });

    test('empty outputs pass through as success', () {
      final handoff = normalizeOutputs({}, const StepOutputNormalizationContext());

      expect(handoff, isA<StepHandoffSuccess>());
      expect(handoff.outputs, isEmpty);
    });
  });
}
