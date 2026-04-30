import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('ProducedArtifactResolver', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('produced_artifact_resolver_test_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('collects top-level path output, nested story specs, and technical research sibling', () {
      final projectRoot = tempDir.path;
      File(p.join(projectRoot, 'docs/plans/p/.technical-research.md'))
        ..createSync(recursive: true)
        ..writeAsStringSync('research');

      final artifacts = const ProducedArtifactResolver().resolve(
        step: const WorkflowStep(
          id: 'plan',
          name: 'Plan',
          outputs: {
            'story_specs': OutputConfig(format: OutputFormat.json, schema: 'story-specs'),
            'plan': OutputConfig(format: OutputFormat.path),
          },
        ),
        outputs: {
          'plan': 'docs/plans/p/plan.md',
          'story_specs': {
            'items': [
              {'id': 'S01', 'title': 'One', 'dependencies': <String>[], 'spec_path': 'fis/s01.md'},
              {
                'id': 'S02',
                'title': 'Two',
                'dependencies': <String>['S01'],
                'spec_path': 'fis/s02.md',
              },
            ],
          },
        },
        planDir: 'docs/plans/p',
        projectRoot: projectRoot,
      );

      expect(artifacts.requiredPaths, [
        'docs/plans/p/.technical-research.md',
        'docs/plans/p/fis/s01.md',
        'docs/plans/p/fis/s02.md',
        'docs/plans/p/plan.md',
      ]);
      expect(artifacts.advisoryPaths, isEmpty);
    });

    test('normalizes story spec paths idempotently', () {
      final resolution = resolveStorySpecPaths({
        'story_specs': {
          'items': [
            {'id': 'S01', 'dependencies': <String>[], 'spec_path': 'docs/plans/p/fis/s01.md'},
            {
              'id': 'S02',
              'dependencies': <String>['S01'],
              'spec_path': 'fis/s02.md',
            },
          ],
        },
      }, planDir: 'docs/plans/p');

      final storySpecs = resolution.outputs['story_specs'] as Map<String, dynamic>;
      final items = storySpecs['items'] as List;
      expect(items.first, containsPair('spec_path', 'docs/plans/p/fis/s01.md'));
      expect(items.last, containsPair('spec_path', 'docs/plans/p/fis/s02.md'));
      expect(items.first, containsPair('dependencies', <String>[]));
      expect(items.last, containsPair('dependencies', <String>['S01']));
      expect(resolution.specPaths, ['docs/plans/p/fis/s01.md', 'docs/plans/p/fis/s02.md']);
    });

    test('collects top-level list path outputs resolved by filesystem resolver', () {
      final artifacts = const ProducedArtifactResolver().resolve(
        step: const WorkflowStep(
          id: 'plan',
          name: 'Plan',
          outputs: {'fis_paths': OutputConfig(format: OutputFormat.lines)},
        ),
        outputs: {
          'fis_paths': ['fis/s01.md', 'fis/s02.md'],
        },
      );

      expect(artifacts.requiredPaths, ['fis/s01.md', 'fis/s02.md']);
    });

    test('normalizes absolute paths inside the project root to relative paths', () {
      final absolutePlan = p.join(tempDir.path, 'docs', 'plans', 'p', 'plan.md');
      final artifacts = const ProducedArtifactResolver().resolve(
        step: const WorkflowStep(
          id: 'plan',
          name: 'Plan',
          outputs: {'plan': OutputConfig(format: OutputFormat.path)},
        ),
        outputs: {'plan': absolutePlan},
        projectRoot: tempDir.path,
      );

      expect(artifacts.requiredPaths, ['docs/plans/p/plan.md']);
    });

    test('rejects traversal outside the project root', () {
      expect(
        () => const ProducedArtifactResolver().resolve(
          step: const WorkflowStep(
            id: 'plan',
            name: 'Plan',
            outputs: {'plan': OutputConfig(format: OutputFormat.path)},
          ),
          outputs: {'plan': '../outside.md'},
          projectRoot: tempDir.path,
        ),
        throwsFormatException,
      );
    });

    test('rejects the project root as a produced artifact path', () {
      for (final value in ['.', tempDir.path]) {
        expect(
          () => const ProducedArtifactResolver().resolve(
            step: const WorkflowStep(
              id: 'plan',
              name: 'Plan',
              outputs: {'plan': OutputConfig(format: OutputFormat.path)},
            ),
            outputs: {'plan': value},
            projectRoot: tempDir.path,
          ),
          throwsFormatException,
        );
      }
    });

    test('rejects paths below symlinks that escape the project root', () {
      final outside = Directory(p.join(tempDir.parent.path, 'outside_${DateTime.now().microsecondsSinceEpoch}'))
        ..createSync(recursive: true);
      addTearDown(() {
        if (outside.existsSync()) outside.deleteSync(recursive: true);
      });
      Link(p.join(tempDir.path, 'linked-out')).createSync(outside.path);

      expect(
        () => const ProducedArtifactResolver().resolve(
          step: const WorkflowStep(
            id: 'plan',
            name: 'Plan',
            outputs: {'plan': OutputConfig(format: OutputFormat.path)},
          ),
          outputs: {'plan': 'linked-out/secret.md'},
          projectRoot: tempDir.path,
        ),
        throwsFormatException,
      );
    });
  });
}
