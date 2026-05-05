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
        'plan': 'docs/plans/foo/plan.md',
        'story_specs': {
          'items': [
            {'id': 'S01', 'title': 'One', 'dependencies': <String>[], 'spec_path': 'fis/a.md'},
            {
              'id': 'S02',
              'title': 'Two',
              'dependencies': <String>['S01'],
              'spec_path': 'fis/b.md',
            },
          ],
        },
      }, StepOutputNormalizationContext(planDir: 'docs/plans/foo', projectRoot: tempDir.path));

      expect(handoff, isA<StepHandoffValidationFailed>());
      final failure = handoff.validationFailure!;
      expect(failure.missingPaths, equals(['docs/plans/foo/fis/a.md', 'docs/plans/foo/fis/b.md']));
      expect(handoff.outputs, isEmpty);
      final reservedPrefix = ['_dartclaw', 'internal', ''].join('.');
      expect(handoff.outputs.keys.any((key) => key.startsWith(reservedPrefix)), isFalse);
    });

    test('rejects legacy list-shaped story_specs payloads', () {
      final handoff = normalizeOutputs({
        'story_specs': ['docs/plans/foo/fis/a.md'],
      }, const StepOutputNormalizationContext());

      expect(handoff, isA<StepHandoffValidationFailed>());
      expect(handoff.validationFailure?.reason, contains('legacy list-shaped `story_specs`'));
      expect(handoff.validationFailure?.missingPaths, isEmpty);
      expect(handoff.outputs, isEmpty);
    });

    test('rejects story spec paths outside the project root', () {
      final handoff = normalizeOutputs({
        'story_specs': {
          'items': [
            {'id': 'S01', 'title': 'One', 'dependencies': <String>[], 'spec_path': '../outside.md'},
          ],
        },
      }, StepOutputNormalizationContext(projectRoot: tempDir.path));

      expect(handoff, isA<StepHandoffValidationFailed>());
      expect(handoff.validationFailure?.reason, contains('escapes project root'));
      expect(handoff.outputs, isEmpty);
    });

    test('rejects story_specs items missing dependencies', () {
      final handoff = normalizeOutputs({
        'plan': 'docs/plans/foo/plan.md',
        'story_specs': {
          'items': [
            {'id': 'S01', 'title': 'One', 'spec_path': 'fis/a.md'},
          ],
        },
      }, const StepOutputNormalizationContext(planDir: 'docs/plans/foo'));

      expect(handoff, isA<StepHandoffValidationFailed>());
      expect(handoff.validationFailure?.reason, contains('missing `dependencies`'));
      expect(handoff.validationFailure?.missingPaths, isEmpty);
      expect(handoff.outputs, isEmpty);
    });

    test('rejects story_specs dependencies that are not story ids', () {
      final handoff = normalizeOutputs({
        'plan': 'docs/plans/foo/plan.md',
        'story_specs': {
          'items': [
            {
              'id': 'S26',
              'title': 'Docs Gap-Fill',
              'spec_path': 'fis/s26-docs-gap-fill.md',
              'dependencies': ['Blocks A-G complete'],
            },
          ],
        },
      }, const StepOutputNormalizationContext(planDir: 'docs/plans/foo'));

      expect(handoff, isA<StepHandoffValidationFailed>());
      expect(handoff.validationFailure?.reason, contains('Unknown dependency IDs: Blocks A-G complete'));
      expect(handoff.validationFailure?.missingPaths, isEmpty);
      expect(handoff.outputs, isEmpty);
    });

    test('normalizes nested story_specs items and succeeds when files exist', () {
      final fisPath = p.join(tempDir.path, 'docs/plans/foo/fis/a.md');
      File(fisPath).createSync(recursive: true);
      final dependencyFisPath = p.join(tempDir.path, 'docs/plans/foo/fis/dependency.md');
      File(dependencyFisPath).createSync(recursive: true);

      final handoff = normalizeOutputs({
        'plan': 'docs/plans/foo/plan.md',
        'story_specs': {
          'items': [
            {'id': 'S00', 'title': 'Dependency', 'dependencies': <String>[], 'spec_path': 'fis/dependency.md'},
            {
              'id': ' S01 ',
              'title': 'One',
              'dependencies': <String>[' S00 '],
              'spec_path': 'fis/a.md',
            },
          ],
        },
      }, StepOutputNormalizationContext(planDir: 'docs/plans/foo', projectRoot: tempDir.path));

      expect(handoff, isA<StepHandoffSuccess>());
      final storySpecs = handoff.outputs['story_specs'] as Map<String, Object?>;
      final items = storySpecs['items'] as List;
      expect(items.last, containsPair('id', 'S01'));
      expect(items.last, containsPair('spec_path', 'docs/plans/foo/fis/a.md'));
      expect(items.last, containsPair('dependencies', <String>['S00']));
    });

    test('empty outputs pass through as success', () {
      final handoff = normalizeOutputs({}, const StepOutputNormalizationContext());

      expect(handoff, isA<StepHandoffSuccess>());
      expect(handoff.outputs, isEmpty);
    });
  });
}
