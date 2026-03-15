import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';

/// Bridges guard verdict events from the core event bus into audit logging.
class GuardAuditSubscriber {
  final GuardAuditLogger _logger;
  StreamSubscription<GuardBlockEvent>? _subscription;

  GuardAuditSubscriber(this._logger);

  /// Start listening on the given [EventBus].
  void subscribe(EventBus bus) {
    _subscription = bus.on<GuardBlockEvent>().listen((event) {
      _logger.logVerdict(
        verdict: switch (event.verdict) {
          'block' => GuardVerdict.block(event.verdictMessage ?? ''),
          'warn' => GuardVerdict.warn(event.verdictMessage ?? ''),
          _ => GuardVerdict.warn(event.verdictMessage ?? ''),
        },
        guardName: event.guardName,
        guardCategory: event.guardCategory,
        hookPoint: event.hookPoint,
        timestamp: event.timestamp,
        sessionId: event.sessionId,
        channel: event.channel,
        peerId: event.peerId,
      );
    });
  }

  /// Cancel the subscription.
  Future<void> cancel() async {
    await _subscription?.cancel();
  }
}
