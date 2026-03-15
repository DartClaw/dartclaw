import 'package:dartclaw_signal/dartclaw_signal.dart';
import 'package:test/test.dart';

void main() {
  group('SignalConfig', () {
    test('fromYaml parses all fields', () {
      final warns = <String>[];
      final config = SignalConfig.fromYaml({
        'enabled': true,
        'phone_number': '+1234567890',
        'executable': '/usr/local/bin/signal-cli',
        'host': '0.0.0.0',
        'port': 9090,
        'max_chunk_size': 2000,
      }, warns);
      expect(warns, isEmpty);
      expect(config.enabled, isTrue);
      expect(config.phoneNumber, '+1234567890');
      expect(config.executable, '/usr/local/bin/signal-cli');
      expect(config.host, '0.0.0.0');
      expect(config.port, 9090);
      expect(config.maxChunkSize, 2000);
    });

    test('fromYaml uses defaults for missing fields', () {
      final warns = <String>[];
      final config = SignalConfig.fromYaml({}, warns);
      expect(warns, isEmpty);
      expect(config.enabled, isFalse);
      expect(config.phoneNumber, '');
      expect(config.executable, 'signal-cli');
      expect(config.host, '127.0.0.1');
      expect(config.port, 8080);
    });

    test('fromYaml warns on invalid types', () {
      final warns = <String>[];
      SignalConfig.fromYaml({
        'enabled': 'yes',
        'phone_number': 123,
        'executable': 456,
        'host': true,
        'port': 'big',
        'max_chunk_size': 'big',
      }, warns);
      expect(warns, hasLength(6));
    });

    test('fromYaml warns on out-of-range port and uses default', () {
      final warns = <String>[];
      final config = SignalConfig.fromYaml({'port': 0}, warns);
      expect(warns, hasLength(1));
      expect(warns.first, contains('1-65535'));
      expect(config.port, 8080);

      final warns2 = <String>[];
      final config2 = SignalConfig.fromYaml({'port': 70000}, warns2);
      expect(warns2, hasLength(1));
      expect(config2.port, 8080);
    });

    test('fromYaml parses retry_policy', () {
      final warns = <String>[];
      final config = SignalConfig.fromYaml({
        'retry_policy': {'max_attempts': 5, 'base_delay_ms': 2000},
      }, warns);
      expect(warns, isEmpty);
      expect(config.retryPolicy.maxAttempts, 5);
      expect(config.retryPolicy.baseDelay, const Duration(milliseconds: 2000));
    });
  });
}
