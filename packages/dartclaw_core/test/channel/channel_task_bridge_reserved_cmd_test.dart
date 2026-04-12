import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeChannel;
import 'package:test/test.dart';

void main() {
  group('ChannelTaskBridge — reserved command handler', () {
    late FakeChannel channel;

    setUp(() {
      channel = FakeChannel(ownedJids: {'sender@s.whatsapp.net'});
    });

    ChannelMessage makeMessage({String text = 'hello', String senderJid = 'sender@s.whatsapp.net'}) {
      return ChannelMessage(channelType: ChannelType.whatsapp, senderJid: senderJid, text: text);
    }

    test('/stop handled — returns true (consumed)', () async {
      final handledTexts = <String>[];

      final bridge = ChannelTaskBridge(
        reservedCommandHandler: (msg, ch) async {
          handledTexts.add(msg.text);
          return 'handled';
        },
      );

      final consumed = await bridge.tryHandle(
        makeMessage(text: '/stop'),
        channel,
        sessionKey: 'agent:main:dm:whatsapp:sender',
      );

      expect(consumed, isTrue);
      expect(handledTexts, ['/stop']);
    });

    test('stop! handled — returns true (consumed)', () async {
      bool called = false;

      final bridge = ChannelTaskBridge(
        reservedCommandHandler: (msg, ch) async {
          called = true;
          return 'handled';
        },
      );

      final consumed = await bridge.tryHandle(
        makeMessage(text: 'stop!'),
        channel,
        sessionKey: 'agent:main:dm:whatsapp:sender',
      );

      expect(consumed, isTrue);
      expect(called, isTrue);
    });

    test('non-reserved message — handler returns null, falls through', () async {
      final bridge = ChannelTaskBridge(
        reservedCommandHandler: (msg, ch) async => null, // not consumed
      );

      final consumed = await bridge.tryHandle(
        makeMessage(text: 'hello world'),
        channel,
        sessionKey: 'agent:main:dm:whatsapp:sender',
      );

      // Falls through (no task trigger/review configured = not consumed).
      expect(consumed, isFalse);
    });

    test('no handler injected — no reserved command processing', () async {
      final bridge = ChannelTaskBridge(
        // reservedCommandHandler: null (default)
      );

      final consumed = await bridge.tryHandle(
        makeMessage(text: '/stop'),
        channel,
        sessionKey: 'agent:main:dm:whatsapp:sender',
      );

      // Falls through — no handler means /stop is treated as a normal message.
      expect(consumed, isFalse);
    });

    test('reserved command check happens before rate limit — /stop bypasses rate limit', () async {
      // Exhaust the rate limit first.
      final limiter = SlidingWindowRateLimiter(limit: 1, window: const Duration(minutes: 1));
      limiter.check('sender@s.whatsapp.net'); // burn the one allowed slot

      bool stopHandled = false;

      final bridge = ChannelTaskBridge(
        reservedCommandHandler: (msg, ch) async {
          stopHandled = true;
          return 'handled';
        },
        perSenderRateLimiter: limiter,
        isAdmin: (_) => false,
        isReservedCommand: (text) => text.startsWith('/stop'),
      );

      final consumed = await bridge.tryHandle(
        makeMessage(text: '/stop'),
        channel,
        sessionKey: 'agent:main:dm:whatsapp:sender',
      );

      // /stop was handled — NOT blocked by rate limiter.
      expect(consumed, isTrue);
      expect(stopHandled, isTrue);
      // No rate-limit rejection was sent.
      expect(channel.sentMessages, isEmpty);
    });

    test('handler returns null (non-reserved) — rate limit is still applied', () async {
      final limiter = SlidingWindowRateLimiter(limit: 1, window: const Duration(minutes: 1));
      limiter.check('sender@s.whatsapp.net'); // burn the slot

      final bridge = ChannelTaskBridge(
        reservedCommandHandler: (msg, ch) async => null, // not a reserved command
        perSenderRateLimiter: limiter,
        isAdmin: (_) => false,
        isReservedCommand: (_) => false,
      );

      final consumed = await bridge.tryHandle(
        makeMessage(text: 'hello'),
        channel,
        sessionKey: 'agent:main:dm:whatsapp:sender',
      );

      // Rate limited — consumed with rejection.
      expect(consumed, isTrue);
      expect(channel.sentMessages, hasLength(1));
      expect(channel.sentMessages.first.$2.text, contains('Rate limit reached'));
    });
  });
}
