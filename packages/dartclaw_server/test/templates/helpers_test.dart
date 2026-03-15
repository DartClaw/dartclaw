import 'package:dartclaw_server/src/templates/helpers.dart';
import 'package:test/test.dart';

void main() {
  group('formatUptime', () {
    test('formats durations correctly', () {
      expect(formatUptime(0), '0m');
      expect(formatUptime(300), '5m');
      expect(formatUptime(5400), '1h 30m');
      expect(formatUptime(90120), '1d 1h 2m');
    });
  });

  group('formatBytes', () {
    test('formats sizes correctly', () {
      expect(formatBytes(500), '500 B');
      expect(formatBytes(2048), '2 KB');
      expect(formatBytes(2 * 1024 * 1024), '2.0 MB');
    });
  });
}
