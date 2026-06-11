import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:test/test.dart';

import 'support/load_config.dart';

void main() {
  group('MaintenanceMode', () {
    test('fromYaml maps valid values', () {
      expect(MaintenanceMode.fromYaml('warn'), MaintenanceMode.warn);
      expect(MaintenanceMode.fromYaml('enforce'), MaintenanceMode.enforce);
    });

    test('fromYaml returns null for unknown values', () {
      expect(MaintenanceMode.fromYaml('unknown'), isNull);
      expect(MaintenanceMode.fromYaml(''), isNull);
      expect(MaintenanceMode.fromYaml('WARN'), isNull);
    });

    test('toYaml round-trips', () {
      for (final mode in MaintenanceMode.values) {
        expect(MaintenanceMode.fromYaml(mode.toYaml()), mode);
      }
    });
  });

  group('session maintenance config parsing', () {
    test('default config has SessionMaintenanceConfig.defaults()', () {
      final config = const DartclawConfig.defaults();
      expect(config.sessions.maintenanceConfig, const SessionMaintenanceConfig.defaults());
      expect(config.sessions.maintenanceConfig.mode, MaintenanceMode.warn);
      expect(config.sessions.maintenanceConfig.pruneAfterDays, 30);
      expect(config.sessions.maintenanceConfig.maxSessions, 500);
      expect(config.sessions.maintenanceConfig.maxDiskMb, 0);
      expect(config.sessions.maintenanceConfig.cronRetentionHours, 24);
      expect(config.sessions.maintenanceConfig.schedule, '0 3 * * *');
    });

    test('sessions.maintenance.mode: enforce parses correctly', () {
      final config = loadYaml('sessions:\n  maintenance:\n    mode: enforce\n');
      expect(config.sessions.maintenanceConfig.mode, MaintenanceMode.enforce);
    });

    test('sessions.maintenance.prune_after_days: 7 parses correctly', () {
      final config = loadYaml('sessions:\n  maintenance:\n    prune_after_days: 7\n');
      expect(config.sessions.maintenanceConfig.pruneAfterDays, 7);
    });

    test('all maintenance int fields parse correctly', () {
      final config = loadYaml(
        'sessions:\n  maintenance:\n    max_sessions: 100\n    max_disk_mb: 512\n    cron_retention_hours: 48\n',
      );
      expect(config.sessions.maintenanceConfig.maxSessions, 100);
      expect(config.sessions.maintenanceConfig.maxDiskMb, 512);
      expect(config.sessions.maintenanceConfig.cronRetentionHours, 48);
    });

    test('sessions.maintenance.schedule parses correctly', () {
      final config = loadYaml('sessions:\n  maintenance:\n    schedule: "0 4 * * *"\n');
      expect(config.sessions.maintenanceConfig.schedule, '0 4 * * *');
    });

    test('invalid sessions.maintenance.mode warns and uses default', () {
      final config = loadYaml('sessions:\n  maintenance:\n    mode: invalid\n');
      expect(config.sessions.maintenanceConfig.mode, MaintenanceMode.warn);
      expect(config.warnings, anyElement(contains('Invalid value for sessions.maintenance.mode')));
    });

    test('invalid type for maintenance int field warns and uses default', () {
      final config = loadYaml('sessions:\n  maintenance:\n    prune_after_days: abc\n');
      expect(config.sessions.maintenanceConfig.pruneAfterDays, 30);
      expect(config.warnings, anyElement(contains('Invalid type for prune_after_days')));
    });

    test('invalid type for sessions.maintenance warns and uses defaults', () {
      final config = loadYaml('sessions:\n  maintenance: true\n');
      expect(config.sessions.maintenanceConfig, const SessionMaintenanceConfig.defaults());
      expect(config.warnings, anyElement(contains('Invalid type for maintenance')));
    });
  });
}
