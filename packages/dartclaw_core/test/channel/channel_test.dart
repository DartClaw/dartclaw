import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_core/src/channel/channel_config.dart';
import 'package:test/test.dart';

void main() {
  group('ChannelType', () {
    test('has web and whatsapp values', () {
      expect(ChannelType.values, containsAll([ChannelType.web, ChannelType.whatsapp]));
    });
  });

  group('ChannelMessage', () {
    test('creates with required fields', () {
      final msg = ChannelMessage(
        channelType: ChannelType.whatsapp,
        senderJid: '1234567890@s.whatsapp.net',
        text: 'Hello',
      );

      expect(msg.id, isNotEmpty);
      expect(msg.channelType, ChannelType.whatsapp);
      expect(msg.senderJid, '1234567890@s.whatsapp.net');
      expect(msg.text, 'Hello');
      expect(msg.groupJid, isNull);
      expect(msg.mentionedJids, isEmpty);
      expect(msg.metadata, isEmpty);
      expect(msg.timestamp, isA<DateTime>());
    });

    test('creates with all fields', () {
      final ts = DateTime(2025, 6, 15);
      final msg = ChannelMessage(
        id: 'custom-id',
        channelType: ChannelType.whatsapp,
        senderJid: 'sender@s.whatsapp.net',
        groupJid: 'group@g.us',
        text: 'Hello group',
        timestamp: ts,
        mentionedJids: ['bot@s.whatsapp.net'],
        metadata: {'key': 'value'},
      );

      expect(msg.id, 'custom-id');
      expect(msg.groupJid, 'group@g.us');
      expect(msg.timestamp, ts);
      expect(msg.mentionedJids, ['bot@s.whatsapp.net']);
      expect(msg.metadata, {'key': 'value'});
    });

    test('auto-generates UUID id when not provided', () {
      final msg1 = ChannelMessage(channelType: ChannelType.web, senderJid: 'a', text: 'x');
      final msg2 = ChannelMessage(channelType: ChannelType.web, senderJid: 'a', text: 'x');
      expect(msg1.id, isNot(msg2.id));
    });
  });

  group('ChannelResponse', () {
    test('creates with required text', () {
      const resp = ChannelResponse(text: 'Reply');
      expect(resp.text, 'Reply');
      expect(resp.mediaAttachments, isEmpty);
      expect(resp.metadata, isEmpty);
    });

    test('creates with all fields', () {
      const resp = ChannelResponse(
        text: 'Reply',
        mediaAttachments: ['/path/to/image.png'],
        metadata: {'format': 'rich'},
      );
      expect(resp.mediaAttachments, ['/path/to/image.png']);
      expect(resp.metadata, {'format': 'rich'});
    });
  });

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
        'channels': {
          'whatsapp': {'phone': '+1234567890'},
        },
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
