import 'package:dartclaw_server/src/templates/helpers.dart';
import 'package:test/test.dart';

void main() {
  group('formatUptime', () {
    test('formats minutes only', () {
      expect(formatUptime(300), '5m');
    });

    test('formats hours and minutes', () {
      expect(formatUptime(5400), '1h 30m');
    });

    test('formats days, hours, and minutes', () {
      expect(formatUptime(90120), '1d 1h 2m');
    });

    test('formats zero', () {
      expect(formatUptime(0), '0m');
    });
  });

  group('formatBytes', () {
    test('formats bytes', () {
      expect(formatBytes(500), '500 B');
    });

    test('formats kilobytes', () {
      expect(formatBytes(2048), '2 KB');
    });

    test('formats megabytes', () {
      expect(formatBytes(2 * 1024 * 1024), '2.0 MB');
    });
  });
}
