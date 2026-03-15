import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';

/// [EventBus] variant that records every fired event for assertions.
class TestEventBus extends EventBus {
  /// Recorded events in fire order.
  final List<DartclawEvent> firedEvents = [];

  @override
  void fire(DartclawEvent event) {
    if (isDisposed) {
      super.fire(event);
      return;
    }
    firedEvents.add(event);
    super.fire(event);
  }

  /// Waits for the next event of type [T] or throws after [timeout].
  Future<T> expectEvent<T extends DartclawEvent>({Duration timeout = const Duration(seconds: 1)}) {
    return on<T>().first.timeout(
      timeout,
      onTimeout: () => throw TimeoutException('Timed out waiting for event $T', timeout),
    );
  }

  /// Returns the recorded events of type [T].
  List<T> eventsOfType<T extends DartclawEvent>() => firedEvents.whereType<T>().toList(growable: false);

  /// Clears recorded history without affecting live subscriptions.
  void clear() {
    firedEvents.clear();
  }
}
