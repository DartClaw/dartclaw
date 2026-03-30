import 'dart:math';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

import 'google_chat_config.dart';
import 'google_chat_channel.dart';
import 'google_chat_rest_client.dart' show GoogleChatRestClient, typingIndicatorEmoji;

/// Google Chat progress feedback using placeholder message edits.
class GoogleChatFeedbackStrategy implements ChannelFeedbackStrategy {
  static final _log = Logger('GoogleChatFeedbackStrategy');

  final GoogleChatRestClient _restClient;
  final DateTime Function() _now;
  final Duration _throttleWindow;
  final Duration _minFeedbackDelay;
  final Duration _statusInterval;
  final GoogleChatFeedbackStatusStyle _statusStyle;
  final Map<String, DateTime> _lastUpdateAt = {};

  GoogleChatFeedbackStrategy({
    required GoogleChatRestClient restClient,
    DateTime Function() now = DateTime.now,
    Duration throttleWindow = const Duration(seconds: 1),
    Duration minFeedbackDelay = Duration.zero,
    Duration statusInterval = const Duration(seconds: 30),
    GoogleChatFeedbackStatusStyle statusStyle = GoogleChatFeedbackStatusStyle.creative,
  }) : _restClient = restClient,
       _now = now,
       _throttleWindow = throttleWindow,
       _minFeedbackDelay = minFeedbackDelay,
       _statusInterval = statusInterval,
       _statusStyle = statusStyle;

  @override
  Future<void> onTurnStarted({required FeedbackContext context, TurnProgressSnapshot? snapshot}) async {
    if (snapshot != null && !_canEmitFeedback(snapshot)) {
      return;
    }
    await _ensureFeedbackAnchor(context, snapshot: snapshot);
  }

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
  }) async {
    if (!_canEmitFeedback(snapshot)) {
      return;
    }
    await _ensureEditablePlaceholder(context, snapshot: snapshot);
    if (_statusStyle == GoogleChatFeedbackStatusStyle.silent) {
      return;
    }
    await _editPlaceholder(context, switch (_statusStyle) {
      GoogleChatFeedbackStatusStyle.minimal => 'Running $toolName (${snapshot.toolCallCount})',
      GoogleChatFeedbackStatusStyle.creative =>
        'Working with $toolName (${snapshot.toolCallCount} tool${snapshot.toolCallCount == 1 ? '' : 's'} so far)',
      GoogleChatFeedbackStatusStyle.silent => throw StateError('unreachable: silent returns early'),
    });
  }

  @override
  Future<void> onToolResult({
    required FeedbackContext context,
    required TurnProgressSnapshot snapshot,
    required String toolName,
    required bool isError,
  }) async {
    if (!_canEmitFeedback(snapshot)) {
      return;
    }
    await _ensureEditablePlaceholder(context, snapshot: snapshot);
    if (_statusStyle == GoogleChatFeedbackStatusStyle.silent) {
      return;
    }
    await _editPlaceholder(context, switch ((_statusStyle, isError)) {
      (GoogleChatFeedbackStatusStyle.minimal, true) => '$toolName failed',
      (GoogleChatFeedbackStatusStyle.minimal, false) => '$toolName done',
      (_, true) => 'Tool $toolName reported an error, adjusting approach',
      (_, false) => 'Tool $toolName completed, continuing',
    });
  }

  @override
  Future<void> onStatusTick({required FeedbackContext context, required TurnProgressSnapshot snapshot}) async {
    if (!_canEmitFeedback(snapshot) || _statusStyle == GoogleChatFeedbackStatusStyle.silent) {
      return;
    }
    await _ensureEditablePlaceholder(context, snapshot: snapshot);
    await _editPlaceholder(context, _statusMessage(snapshot));
  }

  @override
  Future<bool> onTurnCompleted({required FeedbackContext context, required String responseText}) async {
    final placeholderId = context.placeholderMessageId;
    if (placeholderId == null || placeholderId.isEmpty) {
      return false;
    }
    final updated = await _restClient.editMessage(placeholderId, responseText);
    if (updated) {
      if (context.channel is GoogleChatChannel &&
          context.inboundMessageId != null &&
          context.inboundMessageId!.isNotEmpty) {
        (context.channel as GoogleChatChannel).clearPlaceholder(
          spaceName: context.recipientJid,
          turnId: context.inboundMessageId!,
        );
      }
      context.placeholderMessageId = null;
      _lastUpdateAt.remove(placeholderId);
    }
    return updated;
  }

  Future<void> _editPlaceholder(FeedbackContext context, String text) async {
    final placeholderId = context.placeholderMessageId;
    if (placeholderId == null || placeholderId.isEmpty) {
      return;
    }
    if (!_shouldEmit(placeholderId)) {
      return;
    }
    final updated = await _restClient.editMessage(placeholderId, text);
    if (!updated) {
      _log.warning('Failed to edit Google Chat feedback placeholder $placeholderId');
    }
  }

  Future<void> _ensureFeedbackAnchor(FeedbackContext context, {TurnProgressSnapshot? snapshot}) async {
    if (context.placeholderMessageId != null && context.placeholderMessageId!.isNotEmpty) {
      return;
    }
    if (context.channel is! GoogleChatChannel) {
      return;
    }

    final channel = context.channel as GoogleChatChannel;
    final inboundMessageId = context.inboundMessageId;
    if (inboundMessageId == null || inboundMessageId.isEmpty) {
      return;
    }

    switch (channel.config.typingIndicatorMode) {
      case TypingIndicatorMode.message:
        final placeholder = await _restClient.sendMessage(context.recipientJid, _openingMessage(snapshot));
        if (placeholder == null) {
          return;
        }
        context.placeholderMessageId = placeholder;
        channel.setPlaceholder(spaceName: context.recipientJid, turnId: inboundMessageId, messageName: placeholder);
      case TypingIndicatorMode.emoji:
        final reactionName = await _restClient.addReaction(inboundMessageId, typingIndicatorEmoji);
        if (reactionName != null) {
          channel.setReaction(spaceName: context.recipientJid, turnId: inboundMessageId, reactionName: reactionName);
        }
      case TypingIndicatorMode.disabled:
        return;
    }
  }

  Future<void> _ensureEditablePlaceholder(FeedbackContext context, {TurnProgressSnapshot? snapshot}) async {
    if (context.channel is! GoogleChatChannel) {
      return;
    }
    final channel = context.channel as GoogleChatChannel;
    if (channel.config.typingIndicatorMode != TypingIndicatorMode.message) {
      return;
    }
    await _ensureFeedbackAnchor(context, snapshot: snapshot);
  }

  bool _canEmitFeedback(TurnProgressSnapshot snapshot) => snapshot.elapsed >= _minFeedbackDelay;

  bool _shouldEmit(String placeholderId) {
    final now = _now();
    final last = _lastUpdateAt[placeholderId];
    if (last != null && now.difference(last) < _throttleWindow) {
      return false;
    }
    // Bound map size to prevent leaks from non-completing turns.
    if (_lastUpdateAt.length >= 100) {
      _lastUpdateAt.remove(_lastUpdateAt.keys.first);
    }
    _lastUpdateAt[placeholderId] = now;
    return true;
  }

  String _statusMessage(TurnProgressSnapshot snapshot) {
    final elapsedSeconds = snapshot.elapsed.inSeconds;
    final lastTool = snapshot.lastToolName ?? 'tools';
    final cadence = _statusInterval.inSeconds;
    return switch (_statusStyle) {
      GoogleChatFeedbackStatusStyle.minimal => 'Still working: $lastTool (${_formatElapsed(snapshot.elapsed)})',
      GoogleChatFeedbackStatusStyle.silent => throw StateError('unreachable: silent returns early'),
      GoogleChatFeedbackStatusStyle.creative => () {
        if (elapsedSeconds < max(60, cadence)) {
          return 'Still working, checking with $lastTool';
        }
        if (elapsedSeconds < max(120, cadence * 2)) {
          return 'Still working after ${_formatElapsed(snapshot.elapsed)}. Last step: $lastTool';
        }
        return 'Still working after ${_formatElapsed(snapshot.elapsed)}. ${snapshot.toolCallCount} tools used, latest: $lastTool';
      }(),
    };
  }

  String _openingMessage(TurnProgressSnapshot? snapshot) {
    final elapsed = snapshot?.elapsed ?? Duration.zero;
    if (elapsed < const Duration(seconds: 1)) {
      return '_DartClaw is working..._';
    }
    return 'Still working after ${_formatElapsed(elapsed)}.';
  }

  String _formatElapsed(Duration elapsed) {
    final minutes = elapsed.inMinutes;
    final seconds = elapsed.inSeconds % 60;
    if (minutes <= 0) {
      return '${elapsed.inSeconds}s';
    }
    if (seconds == 0) {
      return '${minutes}m';
    }
    return '${minutes}m ${seconds}s';
  }
}
