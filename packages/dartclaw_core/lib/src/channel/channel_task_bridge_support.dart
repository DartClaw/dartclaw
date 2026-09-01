import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'channel.dart';
import 'recipient_resolver.dart';

/// Bridge-local support for rate limiting.
class ChannelTaskBridgeSupport {
  final SlidingWindowRateLimiter? _perSenderRateLimiter;
  final bool Function(String senderId)? _isAdmin;
  final bool Function(String text)? _isReservedCommand;

  new({
    SlidingWindowRateLimiter? perSenderRateLimiter,
    bool Function(String senderId)? isAdmin,
    bool Function(String text)? isReservedCommand,
  }) : _perSenderRateLimiter = perSenderRateLimiter,
       _isAdmin = isAdmin,
       _isReservedCommand = isReservedCommand;

  Future<bool> tryRejectRateLimited(ChannelMessage message, Channel channel) async {
    final rateLimiter = _perSenderRateLimiter;
    if (rateLimiter == null) {
      return false;
    }

    final senderId = message.senderJid;
    final isAdmin = _isAdmin?.call(senderId) ?? false;
    final isReserved = _isReservedCommand?.call(message.text) ?? false;
    if (isAdmin || isReserved || rateLimiter.check(senderId)) {
      return false;
    }

    await _sendRateLimitRejection(message, channel, rateLimiter);
    return true;
  }

  Future<void> _sendRateLimitRejection(
    ChannelMessage message,
    Channel channel,
    SlidingWindowRateLimiter limiter,
  ) async {
    try {
      await channel.sendMessage(
        resolveRecipientId(message),
        ChannelResponse(
          text:
              'Rate limit reached (${limiter.limit} messages per ${_formatRateLimitWindow(limiter.window)}). '
              'Please wait before trying again.',
        ),
      );
    } catch (_) {
      // Best-effort — rate limit rejection is non-critical.
    }
  }

  static String _formatRateLimitWindow(Duration window) {
    if (window.inSeconds >= 60) {
      final minutes = window.inMinutes;
      return minutes == 1 ? '1 minute' : '$minutes minutes';
    }

    final seconds = window.inSeconds;
    return seconds == 1 ? '1 second' : '$seconds seconds';
  }
}
