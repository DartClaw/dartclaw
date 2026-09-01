import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:test/test.dart';

import 'support/load_config.dart';

void main() {
  group('workspace.git_sync config', () {
    test('interval_minutes parses alongside enabled and push_enabled', () {
      final config = loadYaml(
        'workspace:\n  git_sync:\n    enabled: false\n    push_enabled: false\n    interval_minutes: 5\n',
      );

      expect(config.workspace.gitSyncEnabled, isFalse);
      expect(config.workspace.gitSyncPushEnabled, isFalse);
      expect(config.workspace.gitSyncIntervalMinutes, 5);
    });

    test('interval_minutes defaults to 30, keeping the pre-fold heartbeat cadence', () {
      expect(loadYaml('workspace:\n  git_sync:\n    enabled: true\n').workspace.gitSyncIntervalMinutes, 30);
      expect(const WorkspaceConfig.defaults().gitSyncIntervalMinutes, 30);
    });

    test('interval_minutes participates in value equality', () {
      expect(
        const WorkspaceConfig(gitSyncIntervalMinutes: 5),
        isNot(equals(const WorkspaceConfig(gitSyncIntervalMinutes: 10))),
      );
      expect(
        const WorkspaceConfig(gitSyncIntervalMinutes: 5),
        equals(const WorkspaceConfig(gitSyncIntervalMinutes: 5)),
      );
    });

    test('out-of-range interval_minutes is rejected by ConfigValidator', () {
      const validator = ConfigValidator();

      expect(validator.validate({'workspace.git_sync.interval_minutes': 30}), isEmpty);
      expect(validator.validate({'workspace.git_sync.interval_minutes': 0}).map((error) => error.field), [
        'workspace.git_sync.interval_minutes',
      ]);
      expect(validator.validate({'workspace.git_sync.interval_minutes': 1441}).map((error) => error.field), [
        'workspace.git_sync.interval_minutes',
      ]);
    });
  });
}
