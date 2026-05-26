import 'dart:convert';
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

    test('rejects absolute story spec paths', () {
      final absolute = p.normalize(p.absolute('tmp/fis/s01.md'));

      expect(
        () => normalizeOutputs({
          'story_specs': {
            'items': [
              {'id': 'S01', 'title': 'One', 'dependencies': <String>[], 'spec_path': absolute},
            ],
          },
        }, const StepOutputNormalizationContext()),
        returnsNormally,
      );
      expect(
        validateStorySpecOutputs({
          'story_specs': {
            'items': [
              {'id': 'S01', 'title': 'One', 'dependencies': <String>[], 'spec_path': absolute},
            ],
          },
        }).validationFailure?.reason,
        contains('workspace-relative'),
      );
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
            {'id': 'S01', 'title': 'One', 'dependencies': <String>[], 'spec_path': 'fis/s01-a.md'},
            {
              'id': 'S02',
              'title': 'Two',
              'dependencies': <String>['S01'],
              'spec_path': 'fis/s02-b.md',
            },
          ],
        },
      }, StepOutputNormalizationContext(planDir: 'docs/plans/foo', activeWorkspaceRoot: tempDir.path));

      expect(handoff, isA<StepHandoffValidationFailed>());
      final failure = handoff.validationFailure!;
      expect(failure.missingPaths, equals(['docs/plans/foo/fis/s01-a.md', 'docs/plans/foo/fis/s02-b.md']));
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
      }, StepOutputNormalizationContext(activeWorkspaceRoot: tempDir.path));

      expect(handoff, isA<StepHandoffValidationFailed>());
      expect(handoff.validationFailure?.reason, contains('parent traversal'));
      expect(handoff.outputs, isEmpty);
    });

    test('rejects story_specs items missing dependencies', () {
      final handoff = normalizeOutputs({
        'plan': 'docs/plans/foo/plan.md',
        'story_specs': {
          'items': [
            {'id': 'S01', 'title': 'One', 'spec_path': 'fis/s01-a.md'},
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

    test('rejects argument-unsafe story spec paths', () {
      for (final specPath in [
        'fis/s01.md --to-pr 123.md',
        'fis/--flag/s01-story.md',
        'fis/s01-"bad".md',
        'fis/story.md',
      ]) {
        final handoff = normalizeOutputs({
          'story_specs': {
            'items': [
              {'id': 'S01', 'title': 'One', 'dependencies': <String>[], 'spec_path': specPath},
            ],
          },
        }, const StepOutputNormalizationContext());

        expect(handoff, isA<StepHandoffValidationFailed>(), reason: specPath);
        expect(handoff.outputs, isEmpty, reason: specPath);
      }
    });

    test('rejects story spec paths made unsafe by plan directory normalization', () {
      final handoff = normalizeOutputs({
        'story_specs': {
          'items': [
            {'id': 'S01', 'title': 'One', 'dependencies': <String>[], 'spec_path': 'fis/s01-story.md'},
          ],
        },
      }, const StepOutputNormalizationContext(planDir: 'docs/my plan'));

      expect(handoff, isA<StepHandoffValidationFailed>());
      expect(handoff.validationFailure?.reason, contains('whitespace or control characters'));
      expect(handoff.outputs, isEmpty);
    });

    test('normalizes nested story_specs items and succeeds when files exist', () {
      final fisPath = p.join(tempDir.path, 'docs/plans/foo/fis/s01-a.md');
      File(fisPath).createSync(recursive: true);
      final dependencyFisPath = p.join(tempDir.path, 'docs/plans/foo/fis/s00-dependency.md');
      File(dependencyFisPath).createSync(recursive: true);

      final handoff = normalizeOutputs({
        'plan': 'docs/plans/foo/plan.md',
        'story_specs': {
          'items': [
            {'id': 'S00', 'title': 'Dependency', 'dependencies': <String>[], 'spec_path': 'fis/s00-dependency.md'},
            {
              'id': ' S01 ',
              'title': 'One',
              'dependencies': <String>[' S00 '],
              'spec_path': 'fis/s01-a.md',
            },
          ],
        },
      }, StepOutputNormalizationContext(planDir: 'docs/plans/foo', activeWorkspaceRoot: tempDir.path));

      expect(handoff, isA<StepHandoffSuccess>());
      final storySpecs = handoff.outputs['story_specs'] as Map<String, Object?>;
      final items = storySpecs['items'] as List;
      expect(items.last, containsPair('id', 'S01'));
      expect(items.last, containsPair('spec_path', 'docs/plans/foo/fis/s01-a.md'));
      expect(items.last, containsPair('dependencies', <String>['S00']));
    });

    test('preserves plan.json optional story_specs fields', () {
      final fisPath = p.join(tempDir.path, 'docs/plans/foo/fis/s01-a.md');
      File(fisPath).createSync(recursive: true);

      final handoff = normalizeOutputs({
        'plan': 'docs/plans/foo/plan.json',
        'story_specs': {
          'items': [
            {
              'id': 'S01',
              'title': 'One',
              'dependencies': <String>[],
              'spec_path': 'fis/s01-a.md',
              'parallel': true,
              'wave': 'W1',
              'phase': 'P1',
              'risk': 'medium',
              'status': 'spec-ready',
            },
          ],
        },
      }, StepOutputNormalizationContext(planDir: 'docs/plans/foo', activeWorkspaceRoot: tempDir.path));

      expect(handoff, isA<StepHandoffSuccess>());
      final storySpecs = handoff.outputs['story_specs'] as Map<String, Object?>;
      final items = storySpecs['items'] as List;
      expect(
        items.single,
        allOf(
          containsPair('parallel', true),
          containsPair('wave', 'W1'),
          containsPair('phase', 'P1'),
          containsPair('risk', 'medium'),
          containsPair('status', 'spec-ready'),
        ),
      );
    });

    test('empty outputs pass through as success', () {
      final handoff = normalizeOutputs({}, const StepOutputNormalizationContext());

      expect(handoff, isA<StepHandoffSuccess>());
      expect(handoff.outputs, isEmpty);
    });
  });

  group('validateDiscoverAndthenSpecOutputs', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('discover_andthen_spec_validation_test_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('normalizes existing FIS path and checks FEATURE match plus markers', () {
      final fis = File(p.join(tempDir.path, 'dev/specs/demo/fis/s01-story.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('# Story\n\n## Scope\n');

      final validation = validateDiscoverAndthenSpecOutputs(
        {'spec_source': 'existing', 'spec_path': fis.path},
        feature: 'dev/specs/demo/fis/s01-story.md',
        activeWorkspaceRoot: tempDir.path,
      );

      expect(validation.validationFailure, isNull);
      expect(validation.outputs['spec_path'], 'dev/specs/demo/fis/s01-story.md');
    });

    test('rejects existing classification for non-FIS markdown basename', () {
      File(p.join(tempDir.path, 'docs/specs/demo/prd.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('# PRD\n\n## Scope\n');

      final validation = validateDiscoverAndthenSpecOutputs(
        {'spec_source': 'existing', 'spec_path': 'docs/specs/demo/prd.md'},
        feature: 'docs/specs/demo/prd.md',
        activeWorkspaceRoot: tempDir.path,
      );

      expect(validation.validationFailure?.reason, contains('sNN-style markdown FIS'));
    });

    test('rejects existing classification when spec_path differs from FEATURE', () {
      File(p.join(tempDir.path, 'dev/specs/demo/fis/s01-story.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('# Story\n\n## Scope\n');
      File(p.join(tempDir.path, 'dev/specs/demo/fis/s02-story.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('# Story\n\n## Scope\n');

      final validation = validateDiscoverAndthenSpecOutputs(
        {'spec_source': 'existing', 'spec_path': 'dev/specs/demo/fis/s02-story.md'},
        feature: 'dev/specs/demo/fis/s01-story.md',
        activeWorkspaceRoot: tempDir.path,
      );

      expect(validation.validationFailure?.reason, contains('must match FEATURE'));
    });

    test('rejects synthesized classification when FEATURE is an existing FIS', () {
      File(p.join(tempDir.path, 'dev/specs/demo/fis/s01-story.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('# Story\n\n## Scope\n');

      final validation = validateDiscoverAndthenSpecOutputs(
        {'spec_source': 'synthesized', 'spec_path': ''},
        feature: 'dev/specs/demo/fis/s01-story.md',
        activeWorkspaceRoot: tempDir.path,
      );

      expect(validation.validationFailure?.reason, contains('misclassified existing FIS FEATURE as synthesized'));
    });

    test('allows synthesized free text with an embedded FIS path', () {
      final validation = validateDiscoverAndthenSpecOutputs(
        {'spec_source': 'synthesized', 'spec_path': ''},
        feature: 'Implement dev/specs/demo/fis/s01-story.md with extra constraints',
        activeWorkspaceRoot: tempDir.path,
      );

      expect(validation.validationFailure, isNull);
    });

    test('rejects argument-unsafe existing FIS paths', () {
      for (final fisPath in [
        'docs/my plan/fis/s01-story.md',
        'docs/--flag/fis/s01-story.md',
        'docs/fis/s01-"bad".md',
      ]) {
        final validation = validateDiscoverAndthenSpecOutputs(
          {'spec_source': 'existing', 'spec_path': fisPath},
          feature: fisPath,
          activeWorkspaceRoot: tempDir.path,
        );

        expect(validation.validationFailure, isNotNull, reason: fisPath);
      }
    });

    test('rejects existing FIS symlinks that resolve outside project root', () {
      final outside = File(p.join(Directory.systemTemp.createTempSync('outside_fis_').path, 's01-story.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('# Story\n\n## Scope\n');
      addTearDown(() {
        final outsideRoot = outside.parent;
        if (outsideRoot.existsSync()) outsideRoot.deleteSync(recursive: true);
      });
      Link(p.join(tempDir.path, 'dev/specs/demo/fis/s01-story.md')).createSync(outside.path, recursive: true);

      final validation = validateDiscoverAndthenSpecOutputs(
        {'spec_source': 'existing', 'spec_path': 'dev/specs/demo/fis/s01-story.md'},
        feature: 'dev/specs/demo/fis/s01-story.md',
        activeWorkspaceRoot: tempDir.path,
      );

      expect(validation.validationFailure?.reason, contains('resolves outside project root'));
    });
  });

  group('validateDiscoverAndthenPlanOutputs', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('discover_andthen_plan_validation_test_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('normalizes an existing PRD path', () {
      final prd = File(p.join(tempDir.path, 'docs/specs/demo/prd.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('# PRD\n');

      final validation = validateDiscoverAndthenPlanOutputs({'prd': prd.path}, activeWorkspaceRoot: tempDir.path);

      expect(validation.validationFailure, isNull);
      expect(validation.outputs['prd'], 'docs/specs/demo/prd.md');
    });

    test('keeps an empty discovered catalog only when a JSON plan has no executable stories', () {
      File(p.join(tempDir.path, 'docs/specs/demo/prd.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('# PRD\n');
      File(p.join(tempDir.path, 'docs/specs/demo/plan.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'stories': [
              {'id': 'S01', 'status': 'done', 'fis': 'fis/s01-done.md'},
              {'id': 'S02', 'status': 'skipped', 'fis': 'fis/s02-skipped.md'},
            ],
          }),
        );

      final validation = validateDiscoverAndthenPlanOutputs({
        'prd': 'docs/specs/demo/prd.md',
        'plan': 'docs/specs/demo/plan.json',
        'story_specs': {'items': <Map<String, dynamic>>[]},
      }, activeWorkspaceRoot: tempDir.path);

      expect(validation.validationFailure, isNull);
      expect(validation.outputs['plan'], 'docs/specs/demo/plan.json');
    });

    test('clears unproven empty discovered catalogs so planning runs', () {
      File(p.join(tempDir.path, 'docs/specs/demo/prd.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('# PRD\n');
      File(p.join(tempDir.path, 'docs/specs/demo/plan.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          jsonEncode({
            'stories': [
              {'id': 'S01', 'status': 'spec-ready', 'fis': 'fis/s01-open.md'},
            ],
          }),
        );

      final openPlan = validateDiscoverAndthenPlanOutputs({
        'prd': 'docs/specs/demo/prd.md',
        'plan': 'docs/specs/demo/plan.json',
        'story_specs': {'items': <Map<String, dynamic>>[]},
      }, activeWorkspaceRoot: tempDir.path);
      final markdownPlan = validateDiscoverAndthenPlanOutputs({
        'prd': 'docs/specs/demo/prd.md',
        'plan': 'docs/specs/demo/plan.md',
        'story_specs': {'items': <Map<String, dynamic>>[]},
      }, activeWorkspaceRoot: tempDir.path);

      expect(openPlan.validationFailure, isNull);
      expect(openPlan.outputs['plan'], '');
      expect(markdownPlan.validationFailure, isNull);
      expect(markdownPlan.outputs['plan'], '');
    });

    test('rejects empty and missing PRD paths', () {
      final validation = validateDiscoverAndthenPlanOutputs({'prd': ''}, activeWorkspaceRoot: tempDir.path);

      expect(validation.validationFailure?.reason, contains('non-empty existing PRD path'));
    });

    test('rejects non-PRD or missing PRD paths', () {
      final nonPrd = validateDiscoverAndthenPlanOutputs({
        'prd': 'docs/specs/demo/notes.md',
      }, activeWorkspaceRoot: tempDir.path);
      final missing = validateDiscoverAndthenPlanOutputs({
        'prd': 'docs/specs/demo/prd.md',
      }, activeWorkspaceRoot: tempDir.path);

      expect(nonPrd.validationFailure?.reason, contains('PRD markdown path'));
      expect(missing.validationFailure?.reason, contains('missing PRD file'));
      expect(missing.validationFailure?.missingPaths, ['docs/specs/demo/prd.md']);
    });

    test('rejects argument-unsafe PRD paths', () {
      for (final prdPath in ['docs/my plan/prd.md', 'docs/--flag/demo-prd.md', 'docs/prd-"bad".md']) {
        final validation = validateDiscoverAndthenPlanOutputs({'prd': prdPath}, activeWorkspaceRoot: tempDir.path);

        expect(validation.validationFailure, isNotNull, reason: prdPath);
        expect(validation.validationFailure?.missingPaths, isEmpty, reason: prdPath);
      }
    });

    test('rejects PRD symlinks that resolve outside project root', () {
      final outside = File(p.join(Directory.systemTemp.createTempSync('outside_prd_').path, 'prd.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('# PRD\n');
      addTearDown(() {
        final outsideRoot = outside.parent;
        if (outsideRoot.existsSync()) outsideRoot.deleteSync(recursive: true);
      });
      Link(p.join(tempDir.path, 'docs/specs/demo/prd.md')).createSync(outside.path, recursive: true);

      final validation = validateDiscoverAndthenPlanOutputs({
        'prd': 'docs/specs/demo/prd.md',
      }, activeWorkspaceRoot: tempDir.path);

      expect(validation.validationFailure?.reason, contains('resolves outside project root'));
    });
  });
}
