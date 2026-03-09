import 'dart:async';

import 'package:logging/logging.dart';

import 'dartclaw_event.dart';
import 'event_bus.dart';

/// Logs session lifecycle events at INFO level.
///
/// Subscribes to [SessionLifecycleEvent] (sealed parent of
/// [SessionCreatedEvent], [SessionEndedEvent], [SessionErrorEvent])
/// and emits structured log lines for each.
class SessionLifecycleSubscriber {
  static final _log = Logger('SessionLifecycle');
  StreamSubscription<SessionLifecycleEvent>? _subscription;

  /// Start listening on the given [EventBus].
  void subscribe(EventBus bus) {
    _subscription = bus.on<SessionLifecycleEvent>().listen((event) {
      switch (event) {
        case SessionCreatedEvent():
          _log.info(
            'Session created: ${event.sessionId} '
            '(type: ${event.sessionType})',
          );
        case SessionEndedEvent():
          _log.info(
            'Session ended: ${event.sessionId} '
            '(type: ${event.sessionType})',
          );
        case SessionErrorEvent():
          _log.warning(
            'Session error: ${event.sessionId} — ${event.error}',
          );
      }
    });
  }

  /// Cancel the subscription.
  Future<void> cancel() async {
    await _subscription?.cancel();
  }
}
