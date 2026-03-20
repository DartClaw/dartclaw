import 'package:dartclaw_core/src/scoping/channel_config.dart';
import 'package:test/test.dart';

void main() {
  group('ChannelConfig', () {
    test('defaults', () {
      const cfg = ChannelConfig.defaults();
      expect(cfg.debounceWindow, const Duration(milliseconds: 1000));
      expect(cfg.maxQueueDepth, 100);
      expect(cfg.defaultRetryPolicy.maxAttempts, 3);
      expect(cfg.channelConfigs, isEmpty);
    });

    test('fromYaml parses all fields', () {
      final warns = <String>[];
      final cfg = ChannelConfig.fromYaml({
        'debounce_window_ms': 500,
        'max_queue_depth': 50,
        'retry_policy': {'max_attempts': 5, 'base_delay_ms': 2000, 'jitter_factor': 0.3},
        'whatsapp': {'phone': '+1234567890'},
      }, warns);

      expect(warns, isEmpty);
      expect(cfg.debounceWindow, const Duration(milliseconds: 500));
      expect(cfg.maxQueueDepth, 50);
      expect(cfg.defaultRetryPolicy.maxAttempts, 5);
      expect(cfg.defaultRetryPolicy.baseDelay, const Duration(milliseconds: 2000));
      expect(cfg.defaultRetryPolicy.jitterFactor, 0.3);
      expect(cfg.channelConfigs['whatsapp'], {'phone': '+1234567890'});
    });

    test('fromYaml warns on invalid types', () {
      final warns = <String>[];
      final cfg = ChannelConfig.fromYaml({'debounce_window_ms': 'not_an_int', 'max_queue_depth': 'bad'}, warns);

      expect(warns, hasLength(2));
      expect(cfg.debounceWindow, const Duration(milliseconds: 1000)); // default
      expect(cfg.maxQueueDepth, 100); // default
    });
  });

  group('RetryPolicy', () {
    test('defaults', () {
      const rp = RetryPolicy();
      expect(rp.maxAttempts, 3);
      expect(rp.baseDelay, const Duration(seconds: 1));
      expect(rp.jitterFactor, 0.2);
    });

    test('fromYaml parses correctly', () {
      final warns = <String>[];
      final rp = RetryPolicy.fromYaml({'max_attempts': 5, 'base_delay_ms': 500, 'jitter_factor': 0.1}, warns);
      expect(warns, isEmpty);
      expect(rp.maxAttempts, 5);
      expect(rp.baseDelay, const Duration(milliseconds: 500));
      expect(rp.jitterFactor, 0.1);
    });
  });
}
