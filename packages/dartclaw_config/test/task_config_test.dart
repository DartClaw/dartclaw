import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

import 'support/load_config.dart';

String _taskCompletionAction(TaskConfig config) => (config as dynamic).completionAction as String;

void main() {
  group('tasks.artifact_retention_days config', () {
    test('defaults to 0 when unset', () {
      final config = loadNoFile();
      expect(config.tasks.artifactRetentionDays, 0);
    });

    test('parses when configured', () {
      final config = loadYaml('tasks:\n  artifact_retention_days: 90\n');
      expect(config.tasks.artifactRetentionDays, 90);
    });

    test('is clamped to 0..3650', () {
      final low = loadYaml('tasks:\n  artifact_retention_days: -30\n');
      final high = loadYaml('tasks:\n  artifact_retention_days: 5000\n');
      expect(low.tasks.artifactRetentionDays, 0);
      expect(high.tasks.artifactRetentionDays, 3650);
    });
  });

  group('tasks.completion_action config', () {
    test('defaults to review when unset', () {
      final config = loadNoFile();
      expect(_taskCompletionAction(config.tasks), 'review');
    });

    test('parses accept when configured', () {
      final config = loadYaml('tasks:\n  completion_action: accept\n');
      expect(_taskCompletionAction(config.tasks), 'accept');
      expect(config.warnings, isEmpty);
    });

    test('trims surrounding whitespace', () {
      final config = loadYaml('tasks:\n  completion_action: " accept "\n');
      expect(_taskCompletionAction(config.tasks), 'accept');
      expect(config.warnings, isEmpty);
    });

    test('wrong type warns and falls back to review', () {
      final config = loadYaml('tasks:\n  completion_action: 42\n');
      expect(_taskCompletionAction(config.tasks), 'review');
      expect(config.warnings, anyElement(contains('Invalid type for completion_action')));
    });

    test('invalid values warn and fall back to review', () {
      final config = loadYaml('tasks:\n  completion_action: ship_it\n');
      expect(_taskCompletionAction(config.tasks), 'review');
      expect(config.warnings, anyElement(contains('Invalid value for tasks.completion_action')));
    });
  });
}
