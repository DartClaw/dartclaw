import '../events/dartclaw_event.dart';
import '../events/event_bus.dart';
import '../governance/sliding_window_rate_limiter.dart';
import 'channel.dart';
import 'recipient_resolver.dart';
import 'review_command_dispatcher.dart';
import 'review_command_parser.dart';
import 'task_creator.dart';
import 'task_trigger_evaluator.dart';
import 'thread_binding.dart';

/// Bridge-local support for advisory events, rate limiting, and review dispatch.
class ChannelTaskBridgeSupport {
  final ReviewCommandParser? _reviewCommandParser;
  final SlidingWindowRateLimiter? _perSenderRateLimiter;
  final bool Function(String senderId)? _isAdmin;
  final bool Function(String text)? _isReservedCommand;
  final EventBus? _eventBus;
  final ReviewCommandDispatcher? _reviewDispatcher;

  ChannelTaskBridgeSupport({
    ReviewCommandParser? reviewCommandParser,
    ChannelReviewHandler? reviewHandler,
    TaskLister? taskLister,
    SlidingWindowRateLimiter? perSenderRateLimiter,
    bool Function(String senderId)? isAdmin,
    bool Function(String text)? isReservedCommand,
    EventBus? eventBus,
    required TaskTriggerEvaluator taskTriggerEvaluator,
    required Future<void> Function(
      Channel channel,
      String recipientId,
      ChannelResponse response, {
      required String failureMessage,
    })
    sendBestEffort,
  }) : _reviewCommandParser = reviewCommandParser,
       _perSenderRateLimiter = perSenderRateLimiter,
       _isAdmin = isAdmin,
       _isReservedCommand = isReservedCommand,
       _eventBus = eventBus,
       _reviewDispatcher = (reviewCommandParser != null && taskLister != null && reviewHandler != null)
           ? ReviewCommandDispatcher(
               reviewCommandParser: reviewCommandParser,
               reviewHandler: reviewHandler,
               taskLister: taskLister,
               taskTriggerEvaluator: taskTriggerEvaluator,
               sendBestEffort: sendBestEffort,
             )
           : null;

  String? resolveSourceMessageId(ChannelMessage message) {
    final metadataSourceMessageId = message.metadata[sourceMessageIdMetadataKey];
    if (metadataSourceMessageId is String && metadataSourceMessageId.isNotEmpty) {
      return metadataSourceMessageId;
    }
    return message.id.isEmpty ? null : message.id;
  }

  void emitAdvisorMentionIfNeeded(ChannelMessage message, {required String sessionKey, String? taskId}) {
    if (!_looksLikeAdvisorMention(message.text)) return;
    _eventBus?.fire(
      AdvisorMentionEvent(
        senderJid: message.senderJid,
        channelType: message.channelType.name,
        recipientId: resolveRecipientId(message),
        threadId: extractThreadId(message) ?? message.groupJid,
        messageText: message.text,
        sessionKey: sessionKey,
        taskId: taskId,
        timestamp: DateTime.now(),
      ),
    );
  }

  Future<bool> tryRejectRateLimited(ChannelMessage message, Channel channel) async {
    final rateLimiter = _perSenderRateLimiter;
    if (rateLimiter == null) {
      return false;
    }

    final senderId = message.senderJid;
    final isAdmin = _isAdmin?.call(senderId) ?? false;
    final isReserved = _isReservedCommand?.call(message.text) ?? false;
    final isReviewCommand = _reviewCommandParser?.parse(message.text) != null;
    if (isAdmin || isReserved || isReviewCommand || rateLimiter.check(senderId)) {
      return false;
    }

    await _sendRateLimitRejection(message, channel, rateLimiter);
    return true;
  }

  Future<bool> tryHandleReviewCommand(
    ChannelMessage message,
    Channel channel, {
    String? boundTaskId,
    ThreadBinding? threadBinding,
    String? sourceMessageId,
  }) {
    return _reviewDispatcher?.tryHandle(
          message,
          channel,
          boundTaskId: boundTaskId,
          threadBinding: threadBinding,
          sourceMessageId: sourceMessageId,
        ) ??
        Future.value(false);
  }

  static bool _looksLikeAdvisorMention(String text) => text.trimLeft().toLowerCase().startsWith('@advisor');

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
              'Please wait before trying again. '
              'Tip: review commands (accept, reject, push back) and /status are never rate-limited.',
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
