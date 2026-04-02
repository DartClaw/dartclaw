part of 'dartclaw_event.dart';

/// Fired when authentication fails on a gateway, login, or webhook surface.
final class FailedAuthEvent extends DartclawEvent {
  /// Surface that emitted the authentication failure.
  final String source;

  /// Request path or endpoint associated with the failure.
  final String path;

  /// Human-readable explanation of the failure.
  final String reason;

  /// Optional remote key such as IP address or token fingerprint.
  final String? remoteKey;

  /// Whether rate limiting or a hard limit was applied.
  final bool limited;

  @override
  /// Timestamp when the authentication failure occurred.
  final DateTime timestamp;

  /// Creates an authentication failure event.
  FailedAuthEvent({
    required this.source,
    required this.path,
    required this.reason,
    this.remoteKey,
    required this.limited,
    required this.timestamp,
  });

  @override
  String toString() => 'FailedAuthEvent(source: $source, path: $path, reason: $reason, limited: $limited)';
}

/// Fired when a guard blocks or warns on input.
final class GuardBlockEvent extends DartclawEvent {
  /// Stable name of the guard that emitted the verdict.
  final String guardName;

  /// High-level guard category such as `file` or `network`.
  final String guardCategory;

  /// Verdict label such as `warn` or `block`.
  final String verdict;

  /// Optional explanatory message returned by the guard.
  final String? verdictMessage;

  /// Hook point where the guard evaluated the input.
  final String hookPoint;

  /// Raw provider-native tool name associated with the verdict, if any.
  final String? rawProviderToolName;

  /// Deterministic session key associated with the event, if known.
  final String? sessionKey;

  /// Concrete session id associated with the event, if known.
  final String? sessionId;

  /// Channel associated with the event, if any.
  final String? channel;

  /// Peer identifier associated with the event, if any.
  final String? peerId;

  @override
  /// Timestamp when the guard verdict was produced.
  final DateTime timestamp;

  /// Creates a guard block-or-warn event.
  GuardBlockEvent({
    required this.guardName,
    required this.guardCategory,
    required this.verdict,
    this.verdictMessage,
    required this.hookPoint,
    this.rawProviderToolName,
    this.sessionKey,
    this.sessionId,
    this.channel,
    this.peerId,
    required this.timestamp,
  });

  @override
  String toString() =>
      'GuardBlockEvent(guard: $guardName, category: $guardCategory, verdict: $verdict, hook: $hookPoint)';
}

/// Fired when configuration values change via the config API.
final class ConfigChangedEvent extends DartclawEvent {
  /// Fully-qualified config keys that changed.
  final List<String> changedKeys;

  /// Previous values for changed keys.
  final Map<String, dynamic> oldValues;

  /// New values for changed keys.
  final Map<String, dynamic> newValues;

  /// Whether the change requires a runtime restart to fully apply.
  final bool requiresRestart;

  @override
  /// Timestamp when the config change was recorded.
  final DateTime timestamp;

  /// Creates a configuration change event.
  ConfigChangedEvent({
    required this.changedKeys,
    required this.oldValues,
    required this.newValues,
    required this.requiresRestart,
    required this.timestamp,
  });

  @override
  String toString() => 'ConfigChangedEvent(keys: $changedKeys, requiresRestart: $requiresRestart)';
}
