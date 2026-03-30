import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:logging/logging.dart';

/// Builds a [TurnObserver] that bridges [TurnRunner.progressEvents] to a
/// [GoogleChatFeedbackStrategy], eliminating duplicated counters and timers.
class FeedbackObserverFactory {
  static final _log = Logger('FeedbackObserverFactory');

  /// Builds a [TurnObserver] that drives Google Chat feedback via the unified
  /// progress stream. Returns `null` if feedback is disabled.
  static TurnObserver? build({
    required GoogleChatConfig googleChatConfig,
    required SessionService sessions,
    required TurnManager Function() turnManagerGetter,
  }) {
    if (!googleChatConfig.feedback.enabled) {
      return null;
    }

    return (
      String sessionKey,
      ChannelMessage message,
      Channel sourceChannel,
      String recipientJid,
      Future<String> responseFuture,
    ) async {
      if (sourceChannel is! GoogleChatChannel) {
        return false;
      }

      final feedbackConfig = googleChatConfig.feedback;
      final strategy = GoogleChatFeedbackStrategy(
        restClient: sourceChannel.restClient,
        now: DateTime.now,
        minFeedbackDelay: feedbackConfig.minFeedbackDelay,
        statusInterval: feedbackConfig.statusInterval,
        statusStyle: feedbackConfig.statusStyle,
      );
      final session = await sessions.getOrCreateByKey(sessionKey, type: SessionType.channel);
      final context = FeedbackContext(
        channel: sourceChannel,
        recipientJid: recipientJid,
        inboundMessageId: message.id,
        placeholderMessageId: sourceChannel.peekPlaceholderMessageId(spaceName: recipientJid, turnId: message.id),
      );

      final runners = turnManagerGetter().pool.runners;

      // Configure status tick interval on runners.
      for (final runner in runners) {
        runner.statusTickInterval = feedbackConfig.statusInterval;
      }

      // Subscribe to unified progress stream instead of raw harness events.
      final subscriptions = <StreamSubscription<TurnProgressEvent>>[];
      for (final runner in runners) {
        subscriptions.add(
          runner.progressEvents.listen((event) {
            if (!runner.isActive(session.id)) return;
            switch (event) {
              case TextDeltaProgressEvent(:final text, :final snapshot):
                unawaited(
                  _safeFeedbackCall(
                    () => strategy.onTextDelta(context: context, snapshot: snapshot, text: text),
                    message: 'Google Chat feedback text update failed',
                  ),
                );
              case ToolStartedProgressEvent(:final toolName, :final snapshot):
                unawaited(
                  _safeFeedbackCall(
                    () => strategy.onToolUse(context: context, snapshot: snapshot, toolName: toolName),
                    message: 'Google Chat feedback tool update failed',
                  ),
                );
              case ToolCompletedProgressEvent(:final toolName, :final isError, :final snapshot):
                unawaited(
                  _safeFeedbackCall(
                    () => strategy.onToolResult(
                      context: context,
                      snapshot: snapshot,
                      toolName: toolName,
                      isError: isError,
                    ),
                    message: 'Google Chat feedback tool-result update failed',
                  ),
                );
              case StatusTickProgressEvent(:final snapshot):
                unawaited(
                  _safeFeedbackCall(
                    () => strategy.onStatusTick(context: context, snapshot: snapshot),
                    message: 'Google Chat feedback status update failed',
                  ),
                );
              case TurnStallProgressEvent():
                break; // Already handled by TurnRunner (SSE + cancel)
            }
          }),
        );
      }

      try {
        await _safeFeedbackCall(
          () => strategy.onTurnStarted(context: context),
          message: 'Google Chat feedback start failed',
        );
        final responseText = await responseFuture;
        return await _safeFeedbackResult(
          () => strategy.onTurnCompleted(context: context, responseText: responseText),
          message: 'Google Chat feedback completion failed',
        );
      } catch (_) {
        return false;
      } finally {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
      }
    };
  }

  static Future<void> _safeFeedbackCall(Future<void> Function() callback, {required String message}) async {
    try {
      await callback();
    } catch (error, stackTrace) {
      _log.warning(message, error, stackTrace);
    }
  }

  static Future<bool> _safeFeedbackResult(Future<bool> Function() callback, {required String message}) async {
    try {
      return await callback();
    } catch (error, stackTrace) {
      _log.warning(message, error, stackTrace);
      return false;
    }
  }
}
