import 'dart:async';

import 'package:logging/logging.dart';

import 'dartclaw_event.dart';

/// Lightweight typed event bus using a broadcast [StreamController].
///
/// Events are fire-and-forget — if no listener is subscribed, the event is
/// silently dropped (broadcast stream semantics). Subscriber exceptions do
/// not propagate to [fire] callers.
class EventBus {
  final _controller = StreamController<DartclawEvent>.broadcast();
  bool _disposed = false;

  static final _log = Logger('EventBus');

  /// Returns a filtered stream of events matching type [T].
  Stream<T> on<T extends DartclawEvent>() =>
      _controller.stream.where((e) => e is T).cast<T>();

  /// Fires an event to all current subscribers.
  ///
  /// If the bus has been disposed, logs a warning and returns (no exception).
  void fire(DartclawEvent event) {
    if (_disposed) {
      _log.warning('fire() called after dispose — event dropped: $event');
      return;
    }
    runZonedGuarded(
      () => _controller.add(event),
      (error, stack) {
        _log.severe(
          'Subscriber threw during ${event.runtimeType}',
          error,
          stack,
        );
      },
    );
  }

  /// Closes the underlying stream controller.
  Future<void> dispose() async {
    _disposed = true;
    await _controller.close();
  }

  /// Whether [dispose] has been called.
  bool get isDisposed => _disposed;
}
