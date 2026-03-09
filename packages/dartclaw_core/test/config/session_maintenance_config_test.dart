import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:test/test.dart';

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

    test('toYaml returns expected strings', () {
      expect(MaintenanceMode.warn.toYaml(), 'warn');
      expect(MaintenanceMode.enforce.toYaml(), 'enforce');
    });
  });

  group('SessionMaintenanceConfig', () {
    test('defaults() has expected values', () {
      const config = SessionMaintenanceConfig.defaults();
      expect(config.mode, MaintenanceMode.warn);
      expect(config.pruneAfterDays, 30);
      expect(config.maxSessions, 500);
      expect(config.maxDiskMb, 0);
      expect(config.cronRetentionHours, 24);
      expect(config.schedule, '0 3 * * *');
    });

    test('default constructor matches defaults()', () {
      expect(
        const SessionMaintenanceConfig(),
        const SessionMaintenanceConfig.defaults(),
      );
    });

    test('equality with same values', () {
      const a = SessionMaintenanceConfig(
        mode: MaintenanceMode.enforce,
        pruneAfterDays: 7,
        maxSessions: 100,
        maxDiskMb: 512,
        cronRetentionHours: 48,
        schedule: '0 4 * * *',
      );
      const b = SessionMaintenanceConfig(
        mode: MaintenanceMode.enforce,
        pruneAfterDays: 7,
        maxSessions: 100,
        maxDiskMb: 512,
        cronRetentionHours: 48,
        schedule: '0 4 * * *',
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('inequality with different mode', () {
      const a = SessionMaintenanceConfig(mode: MaintenanceMode.warn);
      const b = SessionMaintenanceConfig(mode: MaintenanceMode.enforce);
      expect(a, isNot(b));
    });

    test('inequality with different pruneAfterDays', () {
      const a = SessionMaintenanceConfig(pruneAfterDays: 30);
      const b = SessionMaintenanceConfig(pruneAfterDays: 7);
      expect(a, isNot(b));
    });

    test('inequality with different schedule', () {
      const a = SessionMaintenanceConfig(schedule: '0 3 * * *');
      const b = SessionMaintenanceConfig(schedule: '0 4 * * *');
      expect(a, isNot(b));
    });

    test('toString includes all fields', () {
      const config = SessionMaintenanceConfig.defaults();
      final str = config.toString();
      expect(str, contains('mode: MaintenanceMode.warn'));
      expect(str, contains('pruneAfterDays: 30'));
      expect(str, contains('maxSessions: 500'));
      expect(str, contains('maxDiskMb: 0'));
      expect(str, contains('cronRetentionHours: 24'));
      expect(str, contains('schedule: 0 3 * * *'));
    });
  });
}
