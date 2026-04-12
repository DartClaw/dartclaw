part of 'governance_config.dart';

/// Strategy for draining queued messages within a session.
enum QueueStrategy {
  /// Preserve existing FIFO behavior.
  fifo,

  /// Drain queued messages in round-robin order across senders.
  fair;

  static QueueStrategy? fromYaml(String value) => switch (value) {
    'fifo' => QueueStrategy.fifo,
    'fair' => QueueStrategy.fair,
    _ => null,
  };

  String toYaml() => name;
}

/// Crowd coding model/effort defaults applied to channel-routed group sessions.
class CrowdCodingConfig {
  /// Default model override for crowd coding turns, or `null` to use the global default.
  final String? model;

  /// Default reasoning effort override for crowd coding turns, or `null` to use the global default.
  final String? effort;

  const CrowdCodingConfig({this.model, this.effort});

  const CrowdCodingConfig.defaults() : this();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is CrowdCodingConfig && model == other.model && effort == other.effort;

  @override
  int get hashCode => Object.hash(model, effort);

  @override
  String toString() => 'CrowdCodingConfig(model: $model, effort: $effort)';
}
