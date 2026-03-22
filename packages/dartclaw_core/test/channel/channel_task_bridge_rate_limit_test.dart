import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeChannel;
import 'package:test/test.dart';

void main() {
  group('ChannelTaskBridge — per-sender rate limiting', () {
    late FakeChannel channel;

    setUp(() {
      channel = FakeChannel(ownedJids: {'sender@s.whatsapp.net'});
    });

    ChannelMessage makeMessage({String text = 'hello', String senderJid = 'sender@s.whatsapp.net'}) {
      return ChannelMessage(channelType: ChannelType.whatsapp, senderJid: senderJid, text: text);
    }

    test('rate-limited message — sends polite rejection, returns true (consumed)', () async {
      // Limit of 1 message per minute
      final limiter = SlidingWindowRateLimiter(limit: 1, window: const Duration(minutes: 1));
      // Burn the one allowed slot
      limiter.check('sender@s.whatsapp.net');

      final bridge = ChannelTaskBridge(
        perSenderRateLimiter: limiter,
        isAdmin: (_) => false,
        isReservedCommand: (_) => false,
      );

      final handled = await bridge.tryHandle(makeMessage(), channel, sessionKey: 'agent:main:dm:whatsapp:sender');

      expect(handled, isTrue);
      expect(channel.sentMessages, hasLength(1));
      expect(channel.sentMessages.first.$2.text, contains('too fast'));
    });

    test('admin sender — bypasses rate limit even at limit', () async {
      final limiter = SlidingWindowRateLimiter(limit: 1, window: const Duration(minutes: 1));
      limiter.check('admin@s.whatsapp.net');

      final bridge = ChannelTaskBridge(
        perSenderRateLimiter: limiter,
        isAdmin: (id) => id == 'admin@s.whatsapp.net',
        isReservedCommand: (_) => false,
      );

      final handled = await bridge.tryHandle(
        makeMessage(senderJid: 'admin@s.whatsapp.net'),
        channel,
        sessionKey: 'agent:main:dm:whatsapp:admin',
      );

      // Not consumed by rate limit — falls through (no task trigger configured = false)
      expect(handled, isFalse);
      expect(channel.sentMessages, isEmpty);
    });

    test('review command — bypasses rate limit', () async {
      final limiter = SlidingWindowRateLimiter(limit: 1, window: const Duration(minutes: 1));
      limiter.check('sender@s.whatsapp.net');

      final bridge = ChannelTaskBridge(
        perSenderRateLimiter: limiter,
        reviewCommandParser: const ReviewCommandParser(),
        isAdmin: (_) => false,
        isReservedCommand: (_) => false,
        // No taskLister → review command detection will call parse but won't execute
        // The rate limit check detects it's a review command and skips rate limiting.
        // Without taskLister the bridge returns false (not handled) — that's fine,
        // we just verify no rejection is sent.
      );

      final handled = await bridge.tryHandle(
        makeMessage(text: 'accept abc123'),
        channel,
        sessionKey: 'agent:main:dm:whatsapp:sender',
      );

      // Not rate-limited (bypassed), and no task lister = falls through
      expect(channel.sentMessages, isEmpty);
      expect(handled, isFalse);
    });

    test('reserved command /status — bypasses rate limit', () async {
      final limiter = SlidingWindowRateLimiter(limit: 1, window: const Duration(minutes: 1));
      limiter.check('sender@s.whatsapp.net');

      final bridge = ChannelTaskBridge(
        perSenderRateLimiter: limiter,
        isAdmin: (_) => false,
        isReservedCommand: (text) => text.startsWith('/status') || text.startsWith('/stop'),
      );

      final handled = await bridge.tryHandle(
        makeMessage(text: '/status'),
        channel,
        sessionKey: 'agent:main:dm:whatsapp:sender',
      );

      // Not rate-limited — falls through (no task trigger configured = false)
      expect(handled, isFalse);
      expect(channel.sentMessages, isEmpty);
    });

    test('reserved command /stop — bypasses rate limit', () async {
      final limiter = SlidingWindowRateLimiter(limit: 1, window: const Duration(minutes: 1));
      limiter.check('sender@s.whatsapp.net');

      final bridge = ChannelTaskBridge(
        perSenderRateLimiter: limiter,
        isAdmin: (_) => false,
        isReservedCommand: (text) => text.startsWith('/status') || text.startsWith('/stop'),
      );

      final handled = await bridge.tryHandle(
        makeMessage(text: '/stop'),
        channel,
        sessionKey: 'agent:main:dm:whatsapp:sender',
      );

      expect(handled, isFalse);
      expect(channel.sentMessages, isEmpty);
    });

    test('bound-thread traffic is still subject to per-sender rate limiting', () async {
      final limiter = SlidingWindowRateLimiter(limit: 1, window: const Duration(minutes: 1));
      limiter.check('sender@s.whatsapp.net');
      final binding = ThreadBinding(
        channelType: ChannelType.googlechat.name,
        threadId: 'spaces/AAAA/threads/THREAD-1',
        taskId: 'task-123',
        sessionKey: 'bound-session-key',
        createdAt: DateTime.parse('2026-03-21T10:00:00Z'),
        lastActivity: DateTime.parse('2026-03-21T10:00:00Z'),
      );

      final bridge = ChannelTaskBridge(
        perSenderRateLimiter: limiter,
        isAdmin: (_) => false,
        isReservedCommand: (_) => false,
      );

      final handled = await bridge.tryHandle(
        ChannelMessage(
          channelType: ChannelType.googlechat,
          senderJid: 'sender@s.whatsapp.net',
          text: 'hello',
          metadata: const {'spaceName': 'spaces/AAAA', 'threadName': 'spaces/AAAA/threads/THREAD-1'},
        ),
        channel,
        sessionKey: 'default-session',
        boundThreadBinding: binding,
        enqueue: (_, _, _) => fail('rate-limited bound-thread traffic must not enqueue'),
      );

      expect(handled, isTrue);
      expect(channel.sentMessages, hasLength(1));
      expect(channel.sentMessages.single.$2.text, contains('too fast'));
    });

    test('no rate limiter — no rate limiting (backward compat)', () async {
      final bridge = ChannelTaskBridge(
        // No perSenderRateLimiter
        isAdmin: (_) => false,
      );

      for (var i = 0; i < 100; i++) {
        channel.sentMessages.clear();
        final handled = await bridge.tryHandle(makeMessage(), channel, sessionKey: 'agent:main:dm:whatsapp:sender');
        expect(handled, isFalse);
        expect(channel.sentMessages, isEmpty);
      }
    });

    test('rate limiter with limit 0 — no rate limiting', () async {
      final limiter = SlidingWindowRateLimiter(limit: 0, window: const Duration(minutes: 1));
      final bridge = ChannelTaskBridge(perSenderRateLimiter: limiter, isAdmin: (_) => false);

      for (var i = 0; i < 20; i++) {
        channel.sentMessages.clear();
        final handled = await bridge.tryHandle(makeMessage(), channel, sessionKey: 'agent:main:dm:whatsapp:sender');
        expect(handled, isFalse);
        expect(channel.sentMessages, isEmpty);
      }
    });
  });
}
