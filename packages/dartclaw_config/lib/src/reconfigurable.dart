import 'config_delta.dart';

/// Interface for services that can apply live configuration updates without
/// requiring a server restart.
///
/// Services implement this interface and register with [ConfigNotifier].
/// On each successful reload, [reconfigure] is called synchronously with a
/// [ConfigDelta] filtered to this service's [watchKeys].
///
/// [reconfigure] must be synchronous. Services that need async work should
/// fire-and-forget internally (e.g. schedule a microtask or use an isolate).
abstract interface class Reconfigurable {
  /// Dot-separated YAML paths or section-level glob patterns that this service
  /// cares about (e.g. `'scheduling.*'`, `'alerts.enabled'`).
  ///
  /// [ConfigNotifier] only calls [reconfigure] when the delta contains at
  /// least one key that intersects with this set.
  Set<String> get watchKeys;

  /// Apply the configuration change described by [delta].
  ///
  /// Called synchronously by [ConfigNotifier]. Must not throw — if it does,
  /// [ConfigNotifier] logs the error and continues notifying other services.
  void reconfigure(ConfigDelta delta);
}
