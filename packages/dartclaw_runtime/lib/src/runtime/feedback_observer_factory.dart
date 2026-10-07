import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart' show MessageRedactor;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' show TurnManager, TurnRunner;
import 'package:dartclaw_slack/dartclaw_slack.dart';
import 'package:logging/logging.dart';

import '../execution_coordinator.dart' show ExecutionEventKind;

/// Builds the one [TurnObserver] that bridges [TurnRunner.progressEvents] to the
/// feedback strategy of whichever channel a turn arrived on.
class FeedbackObserverFactory {
  static final _log = Logger('FeedbackObserverFactory');

  /// Builds the [TurnObserver] that drives channel feedback via the unified
  /// progress stream: Google Chat placeholder edits, and Slack's assistant status
  /// with the reply streamed into its thread. Returns `null` when neither
  /// channel's feedback is enabled.
  ///
  /// The observer starts right after the queue invokes the dispatcher, before the
  /// turn's session or runner exist. It therefore never creates the session (that
  /// would pin a bound agent's provider, profile and workspace before the dispatch
  /// can), resolves it when the first progress event needs it, and attaches to the
  /// runner a turn leases when the coordinator reports it.
  static TurnObserver? build({
    required GoogleChatConfig googleChatConfig,
    SlackConfig? slackConfig,
    MessageRedactor? redactor,
    required SessionService sessions,
    required TurnManager Function() turnManagerGetter,
  }) {
    final googleChatEnabled = googleChatConfig.feedback.enabled;
    final slackEnabled = slackConfig?.enabled ?? false;
    if (!googleChatEnabled && !slackEnabled) {
      return null;
    }

    return (
      String sessionKey,
      ChannelMessage message,
      Channel sourceChannel,
      String recipientJid,
      Future<String> responseFuture,
    ) async {
      final _TurnFeedback feedback;
      switch (sourceChannel) {
        case GoogleChatChannel() when googleChatEnabled:
          final feedbackConfig = googleChatConfig.feedback;
          feedback = (
            strategy: GoogleChatFeedbackStrategy(
              restClient: sourceChannel.restClient,
              now: DateTime.now,
              minFeedbackDelay: feedbackConfig.minFeedbackDelay,
              statusInterval: feedbackConfig.statusInterval,
              statusStyle: feedbackConfig.statusStyle,
            ),
            placeholderMessageId: sourceChannel.peekPlaceholderMessageId(spaceName: recipientJid, turnId: message.id),
            statusInterval: feedbackConfig.statusInterval,
            onFailed: null,
          );
        case SlackChannel() when slackEnabled:
          final strategy = sourceChannel.feedbackStrategyFor(message, redact: redactor?.redact);
          feedback = (
            strategy: strategy,
            placeholderMessageId: null,
            statusInterval: null,
            onFailed: strategy.onTurnFailed,
          );
        default:
          return false;
      }

      final context = FeedbackContext(
        channel: sourceChannel,
        recipientJid: recipientJid,
        inboundMessageId: message.id,
        placeholderMessageId: feedback.placeholderMessageId,
      );
      final strategy = feedback.strategy;
      final events = _TurnProgress(
        sessions: sessions,
        sessionKey: sessionKey,
        turnManager: turnManagerGetter(),
        statusInterval: feedback.statusInterval,
        onEvent: (event) => _forward(strategy, context, event),
      );

      try {
        await _safeFeedbackCall(
          () => strategy.onTurnStarted(context: context),
          message: 'Channel feedback start failed',
        );
        final responseText = await responseFuture;
        await events.settle();
        return await _safeFeedbackResult(
          () => strategy.onTurnCompleted(context: context, responseText: responseText),
          message: 'Channel feedback completion failed',
        );
      } catch (_) {
        await events.settle();
        final onFailed = feedback.onFailed;
        if (onFailed != null) await _safeFeedbackCall(onFailed, message: 'Channel feedback failure handling failed');
        return false; // Feedback strategy threw or the turn failed — non-critical; do not block the turn.
      } finally {
        await events.dispose();
      }
    };
  }

  static void _forward(ChannelFeedbackStrategy strategy, FeedbackContext context, TurnProgressEvent event) {
    switch (event) {
      case TextDeltaProgressEvent(:final text, :final snapshot):
        unawaited(
          _safeFeedbackCall(
            () => strategy.onTextDelta(context: context, snapshot: snapshot, text: text),
            message: 'Channel feedback text update failed',
          ),
        );
      case ToolStartedProgressEvent(:final toolName, :final snapshot):
        unawaited(
          _safeFeedbackCall(
            () => strategy.onToolUse(context: context, snapshot: snapshot, toolName: toolName),
            message: 'Channel feedback tool update failed',
          ),
        );
      case ToolCompletedProgressEvent(:final toolName, :final isError, :final snapshot):
        unawaited(
          _safeFeedbackCall(
            () => strategy.onToolResult(context: context, snapshot: snapshot, toolName: toolName, isError: isError),
            message: 'Channel feedback tool-result update failed',
          ),
        );
      case StatusTickProgressEvent(:final snapshot):
        unawaited(
          _safeFeedbackCall(
            () => strategy.onStatusTick(context: context, snapshot: snapshot),
            message: 'Channel feedback status update failed',
          ),
        );
      case ProviderProgressEvent():
        break;
      case TurnStallProgressEvent():
        break; // Already handled by TurnRunner (SSE + cancel)
    }
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

typedef _TurnFeedback = ({
  ChannelFeedbackStrategy strategy,
  String? placeholderMessageId,
  Duration? statusInterval,
  Future<void> Function()? onFailed,
});

/// One turn's progress events: those of the runner executing its session, and no other.
///
/// A runner serves one turn at a time and its events carry no session identity, so
/// each is kept only while the runner is active for the turn's session. The session
/// may not exist yet when the first runner event arrives; events wait for it in order.
class _TurnProgress {
  new({
    required SessionService sessions,
    required String sessionKey,
    required TurnManager turnManager,
    required Duration? statusInterval,
    required void Function(TurnProgressEvent event) onEvent,
  }) : _sessions = sessions,
       _sessionKey = sessionKey,
       _statusInterval = statusInterval,
       _onEvent = onEvent {
    final executions = turnManager.executions;
    executions.runners.forEach(_attach);
    // A runner leased for this turn does not exist yet when the observer starts.
    _subscriptions.add(
      executions.events.listen((event) {
        if (event.kind == ExecutionEventKind.acquired && event.runner != null) _attach(event.runner!);
      }),
    );
  }

  final SessionService _sessions;
  final String _sessionKey;
  final Duration? _statusInterval;
  final void Function(TurnProgressEvent event) _onEvent;
  final _attached = Set<TurnRunner>.identity();
  final _subscriptions = <StreamSubscription<Object?>>[];
  final _waiting = <({TurnRunner runner, TurnProgressEvent event})>[];
  String? _sessionId;
  Future<void>? _resolving;

  void _attach(TurnRunner runner) {
    if (!_attached.add(runner)) return;
    final interval = _statusInterval;
    if (interval != null) runner.statusTickInterval = interval;
    _subscriptions.add(runner.progressEvents.listen((event) => _receive(runner, event)));
  }

  void _receive(TurnRunner runner, TurnProgressEvent event) {
    final sessionId = _sessionId;
    if (sessionId != null) {
      if (runner.isActive(sessionId)) _onEvent(event);
      return;
    }
    _waiting.add((runner: runner, event: event));
    _resolving ??= _resolveSession();
  }

  Future<void> _resolveSession() async {
    try {
      final session = await _sessions.getByKey(_sessionKey);
      final id = session?.id;
      if (id != null) _sessionId = id;
      // No session yet means none of the events seen so far were this turn's.
      final waiting = List.of(_waiting);
      _waiting.clear();
      if (id != null) {
        for (final (:runner, :event) in waiting) {
          if (runner.isActive(id)) _onEvent(event);
        }
      }
    } finally {
      _resolving = null;
    }
  }

  /// Completes once every event received so far has reached the strategy.
  Future<void> settle() async => await _resolving;

  Future<void> dispose() async {
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
  }
}
