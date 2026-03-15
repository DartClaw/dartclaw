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
  });

}
