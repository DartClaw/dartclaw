import 'dart:io';

import 'package:dartclaw_workflow/dartclaw_workflow.dart';
import 'package:dartclaw_workflow/src/workflow/step_outcome_normalizer.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'workflow_executor_test_support.dart' show WorkflowExecutorHarness;

StorySpecOutputValidation _validateOutputs(
  Map<String, dynamic> envelope, {
  String planDir = '',
  String? activeWorkspaceRoot,
}) => validateStorySpecOutputs(envelope, planDir: planDir, activeWorkspaceRoot: activeWorkspaceRoot);

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
        () => _validateOutputs({
          'story_specs': {
            'items': [
              {'id': 'S01', 'title': 'One', 'dependencies': <String>[], 'spec_path': absolute},
            ],
          },
        }),
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

  group('validateStorySpecOutputs', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('step_outcome_normalizer_test_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('reports missing FIS files without sentinel output keys', () {
      final validation = _validateOutputs(
        {
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
        },
        planDir: 'docs/plans/foo',
        activeWorkspaceRoot: tempDir.path,
      );

      final failure = validation.validationFailure!;
      expect(failure.missingPaths, equals(['docs/plans/foo/fis/s01-a.md', 'docs/plans/foo/fis/s02-b.md']));
      final reservedPrefix = ['_dartclaw', 'internal', ''].join('.');
      expect(validation.outputs.keys.any((key) => key.startsWith(reservedPrefix)), isFalse);
    });

    test('rejects legacy list-shaped story_specs payloads', () {
      final validation = _validateOutputs({
        'story_specs': ['docs/plans/foo/fis/a.md'],
      });

      expect(validation.validationFailure?.reason, contains('legacy list-shaped `story_specs`'));
      expect(validation.validationFailure?.missingPaths, isEmpty);
      expect(validation.outputs.keys.any((key) => key.startsWith('_dartclaw.internal.')), isFalse);
    });

    test('rejects story spec paths outside the project root', () {
      final validation = _validateOutputs({
        'story_specs': {
          'items': [
            {'id': 'S01', 'title': 'One', 'dependencies': <String>[], 'spec_path': '../outside.md'},
          ],
        },
      }, activeWorkspaceRoot: tempDir.path);

      expect(validation.validationFailure?.reason, contains('parent traversal'));
      expect(validation.outputs.keys.any((key) => key.startsWith('_dartclaw.internal.')), isFalse);
    });

    test('rejects story_specs items missing dependencies', () {
      final validation = _validateOutputs({
        'plan': 'docs/plans/foo/plan.md',
        'story_specs': {
          'items': [
            {'id': 'S01', 'title': 'One', 'spec_path': 'fis/s01-a.md'},
          ],
        },
      }, planDir: 'docs/plans/foo');

      expect(validation.validationFailure?.reason, contains('missing `dependencies`'));
      expect(validation.validationFailure?.missingPaths, isEmpty);
      expect(validation.outputs.keys.any((key) => key.startsWith('_dartclaw.internal.')), isFalse);
    });

    test('rejects story_specs dependencies that are not story ids', () {
      final validation = _validateOutputs({
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
      }, planDir: 'docs/plans/foo');

      expect(validation.validationFailure?.reason, contains('Unknown dependency IDs: Blocks A-G complete'));
      expect(validation.validationFailure?.missingPaths, isEmpty);
      expect(validation.outputs.keys.any((key) => key.startsWith('_dartclaw.internal.')), isFalse);
    });

    test('rejects argument-unsafe story spec paths', () {
      for (final specPath in ['fis/s01.md --to-pr 123.md', 'fis/--flag/s01-story.md', 'fis/s01-"bad".md']) {
        final validation = _validateOutputs({
          'story_specs': {
            'items': [
              {'id': 'S01', 'title': 'One', 'dependencies': <String>[], 'spec_path': specPath},
            ],
          },
        });

        expect(validation.validationFailure, isNotNull, reason: specPath);
        expect(validation.outputs.keys.any((key) => key.startsWith('_dartclaw.internal.')), isFalse, reason: specPath);
      }
    });

    test('rejects story spec paths made unsafe by plan directory normalization', () {
      final validation = _validateOutputs({
        'story_specs': {
          'items': [
            {'id': 'S01', 'title': 'One', 'dependencies': <String>[], 'spec_path': 'fis/s01-story.md'},
          ],
        },
      }, planDir: 'docs/my plan');

      expect(validation.validationFailure?.reason, contains('whitespace or control characters'));
      expect(validation.outputs.keys.any((key) => key.startsWith('_dartclaw.internal.')), isFalse);
    });

    test('normalizes nested story_specs items and succeeds when files exist', () {
      final fisPath = p.join(tempDir.path, 'docs/plans/foo/fis/s01-a.md');
      File(fisPath).createSync(recursive: true);
      final dependencyFisPath = p.join(tempDir.path, 'docs/plans/foo/fis/s00-dependency.md');
      File(dependencyFisPath).createSync(recursive: true);

      final validation = _validateOutputs(
        {
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
        },
        planDir: 'docs/plans/foo',
        activeWorkspaceRoot: tempDir.path,
      );

      expect(validation.validationFailure, isNull);
      final storySpecs = validation.outputs['story_specs'] as Map<String, Object?>;
      final items = storySpecs['items'] as List;
      expect(items.last, containsPair('id', 'S01'));
      expect(items.last, containsPair('spec_path', 'docs/plans/foo/fis/s01-a.md'));
      expect(items.last, containsPair('dependencies', <String>['S00']));
    });

    test('preserves plan.json optional story_specs fields', () {
      final fisPath = p.join(tempDir.path, 'docs/plans/foo/fis/s01-a.md');
      File(fisPath).createSync(recursive: true);

      final validation = _validateOutputs(
        {
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
        },
        planDir: 'docs/plans/foo',
        activeWorkspaceRoot: tempDir.path,
      );

      expect(validation.validationFailure, isNull);
      final storySpecs = validation.outputs['story_specs'] as Map<String, Object?>;
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
      final validation = _validateOutputs({});

      expect(validation.validationFailure, isNull);
      expect(validation.outputs, isEmpty);
    });
  });

  group('WorkflowExecutor.execute story_specs normalization', () {
    final h = WorkflowExecutorHarness();

    setUp(h.setUp);
    tearDown(h.tearDown);

    test('rejects story_specs items missing dependencies without sentinel outputs', () async {
      const definition = WorkflowDefinition(
        name: 'plan-invalid-story-specs',
        description: 'Invalid story_specs execute test',
        steps: [
          WorkflowStep(
            id: 'plan',
            name: 'Plan',
            taskType: WorkflowTaskType.agent,
            prompts: ['Plan the work'],
            outputs: {'story_specs': OutputConfig(format: OutputFormat.json, schema: 'story_specs')},
          ),
        ],
      );
      final run = h.makeRun(definition);
      await h.repository.insert(run);
      final context = WorkflowContext();

      final completionSub = h.eventBus
          .on<TaskStatusChangedEvent>()
          .where((event) => event.newStatus == TaskStatus.queued)
          .listen((event) async {
            await Future<void>.delayed(Duration.zero);
            await h.completeTaskWithOutcome(
              event.taskId,
              outcomeContent:
                  'Done.\n\n<workflow-context>{"story_specs":{"items":[{"id":"S01","title":"One","spec_path":"fis/s01-a.md"}]}}</workflow-context>',
            );
          });
      addTearDown(completionSub.cancel);

      await h.executor.execute(run, definition, context);
      await completionSub.cancel();

      final stored = await h.repository.getById(run.id);
      expect(stored?.status, WorkflowRunStatus.failed);
      expect(stored?.errorMessage, contains('missing `dependencies`'));
      expect(context.data.keys.where((key) => key.startsWith('_dartclaw.internal')), isEmpty);
    });
  });
}
