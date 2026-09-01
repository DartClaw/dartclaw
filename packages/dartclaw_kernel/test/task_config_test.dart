import 'package:dartclaw_kernel/dartclaw_kernel.dart';
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

    test('high retention and low stale timeout saturate silently', () {
      final config = loadYaml('''
tasks:
  artifact_retention_days: 99999
  worktree:
    stale_timeout_hours: 0
''');

      expect(config.tasks.artifactRetentionDays, 3650);
      expect(config.tasks.worktreeStaleTimeoutHours, 1);
      expect(config.warnings.where((warning) => warning.contains('tasks.artifact_retention_days')), isEmpty);
      expect(config.warnings.where((warning) => warning.contains('tasks.worktree.stale_timeout_hours')), isEmpty);
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

  group('tasks.worktree.merge_strategy config', () {
    test('parses both strategies', () {
      expect(loadYaml('tasks:\n  worktree:\n    merge_strategy: merge\n').tasks.worktreeMergeStrategy, 'merge');
      expect(loadYaml('tasks:\n  worktree:\n    merge_strategy: squash\n').tasks.worktreeMergeStrategy, 'squash');
    });

    test('an unknown value warns and falls back to squash', () {
      final config = loadYaml('tasks:\n  worktree:\n    merge_strategy: rebase\n');
      expect(config.tasks.worktreeMergeStrategy, 'squash');
      expect(config.warnings, ['Invalid value for tasks.worktree.merge_strategy: "rebase" — using default "squash"']);
    });

    test('surrounding whitespace is trimmed before membership is decided', () {
      final merge = loadYaml('tasks:\n  worktree:\n    merge_strategy: "merge "\n');
      final squash = loadYaml('tasks:\n  worktree:\n    merge_strategy: "squash "\n');

      expect(merge.tasks.worktreeMergeStrategy, 'merge');
      expect(merge.warnings, isEmpty);
      expect(squash.tasks.worktreeMergeStrategy, 'squash');
      expect(squash.warnings, isEmpty);
    });
  });
}
