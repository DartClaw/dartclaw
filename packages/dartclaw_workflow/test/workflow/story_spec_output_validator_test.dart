import 'dart:io';

import 'package:dartclaw_workflow/src/workflow/story_spec_output_validator.dart' show validateStorySpecOutputs;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  // The validator carries no plan-status knowledge: a dependency on a story
  // absent from the emitted set is always rejected as unknown. Pruning of
  // already-completed prerequisites is the discovery skill's job (ADR-041),
  // so the validator never reads plan.json to soften this check.
  group('validateStorySpecOutputs rejects unknown dependencies generically', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('story_spec_output_validator_test_');
      Directory(p.join(tempDir.path, 'fis')).createSync();
      File(p.join(tempDir.path, 'fis', 's02-story.md')).writeAsStringSync('# S02');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    test('a dependency on a story absent from the emitted set is rejected as unknown', () {
      // Even with a plan.json present that marks S01 done, the validator does
      // not consult it — the emitted catalog alone decides known vs unknown.
      File(p.join(tempDir.path, 'plan.json')).writeAsStringSync('{"stories":[{"id":"S01","status":"done"}]}');

      final result = validateStorySpecOutputs({
        'plan': 'plan.json',
        'story_specs': {
          'items': [
            {
              'id': 'S02',
              'title': 'Story 2',
              'spec_path': 'fis/s02-story.md',
              'dependencies': ['S01'],
            },
          ],
        },
      }, activeWorkspaceRoot: tempDir.path);

      expect(result.validationFailure, isNotNull);
      expect(result.validationFailure!.reason, contains('Unknown dependency IDs: S01'));
    });

    test('a dependency on an emitted story validates', () {
      File(p.join(tempDir.path, 'fis', 's01-story.md')).writeAsStringSync('# S01');

      final result = validateStorySpecOutputs({
        'story_specs': {
          'items': [
            {'id': 'S01', 'title': 'Story 1', 'spec_path': 'fis/s01-story.md', 'dependencies': <String>[]},
            {
              'id': 'S02',
              'title': 'Story 2',
              'spec_path': 'fis/s02-story.md',
              'dependencies': ['S01'],
            },
          ],
        },
      }, activeWorkspaceRoot: tempDir.path);

      expect(result.validationFailure, isNull);
    });
  });

  // ADR-041 parity: the generic story_specs validators run for any
  // story_specs-emitting payload, independent of skill name. validateStorySpecOutputs
  // takes no step/skill argument, so these outcomes hold for a generically-named
  // step exactly as for the (now un-wired) dartclaw-discover-andthen-plan step.
  group('validateStorySpecOutputs runs generically (no skill-name gating)', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('story_spec_generic_test_');
      Directory(p.join(tempDir.path, 'fis')).createSync();
      File(p.join(tempDir.path, 'fis', 's01-story.md')).writeAsStringSync('# S01');
      File(p.join(tempDir.path, 'fis', 's02-story.md')).writeAsStringSync('# S02');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    Map<String, dynamic> cyclicOutputs() => {
      'story_specs': {
        'items': [
          {
            'id': 'S01',
            'title': 'Story 1',
            'spec_path': 'fis/s01-story.md',
            'dependencies': ['S02'],
          },
          {
            'id': 'S02',
            'title': 'Story 2',
            'spec_path': 'fis/s02-story.md',
            'dependencies': ['S01'],
          },
        ],
      },
    };

    test('rejects an S1→S2→S1 dependency cycle', () {
      // S02-D: DAG/cycle check fires from the output payload alone — no skill name.
      final result = validateStorySpecOutputs(cyclicOutputs(), activeWorkspaceRoot: tempDir.path);

      expect(result.validationFailure, isNotNull);
      expect(result.validationFailure!.reason, contains('Circular dependency'));
    });

    test('rejects a spec_path that escapes the workspace root (containment, root present)', () {
      // S02-C first half: containment violation fails the same way the deleted
      // skill-gated path produced. Assert the reason is a containment rejection,
      // not an incidental missing-file failure, so this proves containment parity.
      final result = validateStorySpecOutputs({
        'story_specs': {
          'items': [
            {'id': 'S01', 'title': 'Story 1', 'spec_path': '../outside/s01-story.md', 'dependencies': <String>[]},
          ],
        },
      }, activeWorkspaceRoot: tempDir.path);

      expect(result.validationFailure, isNotNull);
      expect(result.validationFailure!.reason, contains('parent traversal'));
    });

    test('with no active workspace root: containment is enforced but existence is skipped', () {
      // S02-C second half / OC05 (ADR-041): no root → containment-only. A clean
      // relative path to a non-existent file passes (existence skipped); an
      // escaping path is still rejected.
      final missingButContained = validateStorySpecOutputs({
        'story_specs': {
          'items': [
            {'id': 'S01', 'title': 'Story 1', 'spec_path': 'fis/s99-not-on-disk.md', 'dependencies': <String>[]},
          ],
        },
      }, activeWorkspaceRoot: null);
      expect(
        missingButContained.validationFailure,
        isNull,
        reason: 'existence is skipped when no active workspace root resolves',
      );

      final escaping = validateStorySpecOutputs({
        'story_specs': {
          'items': [
            {'id': 'S01', 'title': 'Story 1', 'spec_path': '../outside/s01-story.md', 'dependencies': <String>[]},
          ],
        },
      }, activeWorkspaceRoot: null);
      expect(escaping.validationFailure, isNotNull, reason: 'containment still rejects escaping paths with no root');
    });
  });
}
