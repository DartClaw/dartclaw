import 'package:collection/collection.dart';

/// A single alert delivery target: a channel type + recipient identifier.
class AlertTarget {
  /// Channel type name (e.g. `'whatsapp'`, `'signal'`, `'googlechat'`).
  final String channel;

  /// Channel-specific recipient identifier (JID, space name, etc.).
  final String recipient;

  const AlertTarget({required this.channel, required this.recipient});

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is AlertTarget && channel == other.channel && recipient == other.recipient;

  @override
  int get hashCode => Object.hash(channel, recipient);

  @override
  String toString() => 'AlertTarget(channel: $channel, recipient: $recipient)';
}

/// Configuration for the alerting subsystem.
///
/// Controls which system events are routed to which channel recipients.
/// Disabled by default — set `enabled: true` and configure at least one
/// target to activate alerts.
class AlertsConfig {
  /// Whether alert routing is active. When false, all events are dropped.
  final bool enabled;

  /// Minimum seconds between repeated alerts of the same type.
  /// Used by S10 throttle logic.
  final int cooldownSeconds;

  /// Number of events before burst-summary mode activates.
  /// Used by S10 throttle logic.
  final int burstThreshold;

  /// Explicit delivery targets (channel + recipient pairs).
  final List<AlertTarget> targets;

  /// Maps event type identifiers (e.g. `'guard_block'`, `'compaction'`) to
  /// the list of target indices they should be routed to.
  /// Use `['*']` to mean all targets.
  /// When empty, all recognized events are sent to all targets.
  final Map<String, List<String>> routes;

  const AlertsConfig({
    this.enabled = false,
    this.cooldownSeconds = 300,
    this.burstThreshold = 5,
    this.targets = const [],
    this.routes = const {},
  });

  const AlertsConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AlertsConfig &&
          enabled == other.enabled &&
          cooldownSeconds == other.cooldownSeconds &&
          burstThreshold == other.burstThreshold &&
          const ListEquality<AlertTarget>().equals(targets, other.targets) &&
          const MapEquality<String, List<String>>(values: ListEquality<String>()).equals(routes, other.routes);

  @override
  int get hashCode => Object.hash(
    enabled,
    cooldownSeconds,
    burstThreshold,
    Object.hashAll(targets),
    Object.hashAll(routes.entries.map((e) => Object.hash(e.key, Object.hashAll(e.value)))),
  );

  @override
  String toString() =>
      'AlertsConfig(enabled: $enabled, cooldownSeconds: $cooldownSeconds, '
      'burstThreshold: $burstThreshold, targets: ${targets.length}, routes: ${routes.length})';
}
