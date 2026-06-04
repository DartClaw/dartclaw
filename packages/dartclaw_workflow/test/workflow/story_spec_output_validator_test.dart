import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_workflow/src/workflow/story_spec_output_validator.dart' show validateStorySpecOutputs;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('validateStorySpecOutputs completed-story dependency pruning', () {
    late Directory tempDir;

    void writePlan(String status) {
      File(p.join(tempDir.path, 'plan.json')).writeAsStringSync(
        jsonEncode({
          'stories': [
            {'id': 'S01', 'status': status},
            {'id': 'S02', 'status': 'spec-ready'},
          ],
        }),
      );
    }

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('story_spec_output_validator_test_');
      Directory(p.join(tempDir.path, 'fis')).createSync();
      File(p.join(tempDir.path, 'fis', 's02-story.md')).writeAsStringSync('# S02');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    // S02 depends on S01; the plan status of S01 decides whether that dep is pruned.
    Map<String, dynamic> outputs({String plan = 'plan.json'}) => {
      if (plan.isNotEmpty) 'plan': plan,
      'story_specs': {
        'items': [
          {
            'id': 'S02',
            'spec_path': 'fis/s02-story.md',
            'dependencies': ['S01'],
          },
        ],
      },
    };

    test('a dependency on a done story is pruned (validates)', () {
      writePlan('done');

      final result = validateStorySpecOutputs(outputs(), activeWorkspaceRoot: tempDir.path);

      expect(result.validationFailure, isNull);
    });

    test('a dependency on a non-completed (blocked) story is rejected, not pruned', () {
      writePlan('blocked');

      final result = validateStorySpecOutputs(outputs(), activeWorkspaceRoot: tempDir.path);

      expect(result.validationFailure, isNotNull);
      expect(result.validationFailure!.reason, contains('Unknown dependency IDs: S01'));
    });

    test('a non-.json plan path leaves validation strict (dependency rejected)', () {
      File(p.join(tempDir.path, 'plan.md')).writeAsStringSync('# plan');

      final result = validateStorySpecOutputs(outputs(plan: 'plan.md'), activeWorkspaceRoot: tempDir.path);

      expect(result.validationFailure, isNotNull);
      expect(result.validationFailure!.reason, contains('Unknown dependency IDs: S01'));
    });

    test('an absent plan leaves validation strict (dependency rejected)', () {
      final result = validateStorySpecOutputs(outputs(plan: ''), activeWorkspaceRoot: tempDir.path);

      expect(result.validationFailure, isNotNull);
      expect(result.validationFailure!.reason, contains('Unknown dependency IDs: S01'));
    });
  });
}
