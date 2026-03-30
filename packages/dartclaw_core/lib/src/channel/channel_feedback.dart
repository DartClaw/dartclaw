import 'channel.dart';

/// Snapshot of ongoing turn progress used by feedback strategies.
class TurnProgressSnapshot {
  final Duration elapsed;
  final int toolCallCount;
  final String? lastToolName;
  final int accumulatedTokens;
  final int textLength;

  const TurnProgressSnapshot({
    required this.elapsed,
    required this.toolCallCount,
    this.lastToolName,
    this.accumulatedTokens = 0,
    this.textLength = 0,
  });
}

/// Mutable state shared between turn execution and a feedback strategy.
class FeedbackContext {
  final Channel channel;
  final String recipientJid;
  final String? inboundMessageId;
  String? placeholderMessageId;

  FeedbackContext({
    required this.channel,
    required this.recipientJid,
    this.inboundMessageId,
    this.placeholderMessageId,
  });
}

/// Channel-specific progress feedback for a running turn.
abstract interface class ChannelFeedbackStrategy {
  Future<void> onTurnStarted({required FeedbackContext context, TurnProgressSnapshot? snapshot});

  Future<void> onTextDelta({
    required FeedbackContext context,
    required TurnProgressSnapshot snapshot,
    required String text,
  });

  Future<void> onToolUse({
    required FeedbackContext context,
    required TurnProgressSnapshot snapshot,
    required String toolName,
  });

  Future<void> onToolResult({
    required FeedbackContext context,
    required TurnProgressSnapshot snapshot,
    required String toolName,
    required bool isError,
  });

  Future<void> onStatusTick({required FeedbackContext context, required TurnProgressSnapshot snapshot});

  Future<bool> onTurnCompleted({required FeedbackContext context, required String responseText});
}

/// No-op feedback strategy used when channel feedback is disabled.
class NoFeedbackStrategy implements ChannelFeedbackStrategy {
  const NoFeedbackStrategy();

  @override
  Future<void> onTurnStarted({required FeedbackContext context, TurnProgressSnapshot? snapshot}) async {}

  @override
  Future<void> onTextDelta({
    required FeedbackContext context,
    required TurnProgressSnapshot snapshot,
    required String text,
  }) async {}

  @override
  Future<void> onToolUse({
    required FeedbackContext context,
    required TurnProgressSnapshot snapshot,
    required String toolName,
  }) async {}

  @override
  Future<void> onToolResult({
    required FeedbackContext context,
    required TurnProgressSnapshot snapshot,
    required String toolName,
    required bool isError,
  }) async {}

  @override
  Future<void> onStatusTick({required FeedbackContext context, required TurnProgressSnapshot snapshot}) async {}

  @override
  Future<bool> onTurnCompleted({required FeedbackContext context, required String responseText}) async => false;
}
