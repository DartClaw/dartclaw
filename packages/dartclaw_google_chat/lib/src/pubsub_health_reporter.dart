import 'package:logging/logging.dart';

import 'pubsub_client.dart';

/// Callback to retrieve the count of active Workspace Events subscriptions.
typedef SubscriptionCountGetter = int Function();

/// Bridges Pub/Sub infrastructure health into the HealthService reporting
/// pipeline.
///
/// Reads status from [PubSubClient.healthStatus] and active subscription count
/// from a callback (provided by WorkspaceEventsManager). Produces a
/// JSON-serializable map for inclusion in the `/health` endpoint response.
class PubSubHealthReporter {
  static final _log = Logger('PubSubHealthReporter');

  final PubSubClient? _client;
  final SubscriptionCountGetter? _subscriptionCount;
  final bool _enabled;

  /// Creates a health reporter for configured Pub/Sub infrastructure.
  ///
  /// [client] — the running PubSubClient (null if not started).
  /// [subscriptionCount] — callback returning active subscription count.
  /// [enabled] — whether Pub/Sub is configured in the YAML config.
  PubSubHealthReporter({
    PubSubClient? client,
    SubscriptionCountGetter? subscriptionCount,
    bool enabled = false,
  }) : _client = client,
       _subscriptionCount = subscriptionCount,
       _enabled = enabled;

  /// Returns a JSON-serializable health status map for the Pub/Sub subsystem.
  ///
  /// Always returns a map (never null) — includes `enabled: false` when
  /// Pub/Sub is not configured so the dashboard can display a clear
  /// "Not configured" state.
  Map<String, dynamic> getStatus() {
    if (!_enabled) {
      return {
        'status': 'disabled',
        'enabled': false,
      };
    }

    final client = _client;
    if (client == null) {
      _log.fine('Pub/Sub configured but client not started');
      return {
        'status': 'unavailable',
        'enabled': true,
        'active_subscriptions': _safeSubscriptionCount(),
      };
    }

    final health = client.healthStatus;
    return {
      'status': health.status,
      'enabled': true,
      if (health.lastSuccessfulPull != null)
        'last_successful_pull': health.lastSuccessfulPull!.toUtc().toIso8601String(),
      'consecutive_errors': health.consecutiveErrors,
      'active_subscriptions': _safeSubscriptionCount(),
    };
  }

  int _safeSubscriptionCount() {
    try {
      return _subscriptionCount?.call() ?? 0;
    } catch (e) {
      _log.warning('Failed to retrieve subscription count', e);
      return 0;
    }
  }
}
