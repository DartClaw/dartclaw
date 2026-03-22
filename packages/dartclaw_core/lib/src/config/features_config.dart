/// Configuration for the thread binding feature within the `features:` namespace.
///
/// Thread binding routes inbound channel messages in a bound thread directly
/// to the task's agent session, enabling per-task conversation tracking in
/// Crowd Coding scenarios.
class ThreadBindingFeatureConfig {
  /// Whether thread binding is enabled.
  ///
  /// When `true`, inbound Google Chat messages in a thread bound to a task
  /// are routed directly to the task's agent session, and task notifications
  /// are sent as new threads to enable per-task conversation tracking.
  final bool enabled;

  /// How many minutes of inactivity before a thread binding is removed.
  ///
  /// Defaults to 60 minutes (1 hour). The idle-timeout sweep runs every
  /// 5 minutes so actual removal may lag by up to 5 minutes.
  final int idleTimeoutMinutes;

  /// Creates a thread binding feature config.
  const ThreadBindingFeatureConfig({
    this.enabled = false,
    this.idleTimeoutMinutes = 60,
  });

  /// Parses from a YAML map. Returns defaults when [yaml] is `null` or empty.
  factory ThreadBindingFeatureConfig.fromYaml(Map<String, dynamic>? yaml) {
    if (yaml == null) return const ThreadBindingFeatureConfig();
    final timeoutRaw = yaml['idle_timeout_minutes'];
    final timeoutMinutes = timeoutRaw is int ? timeoutRaw : 60;
    return ThreadBindingFeatureConfig(
      enabled: yaml['enabled'] == true,
      idleTimeoutMinutes: timeoutMinutes,
    );
  }

  /// Serializes to a JSON map.
  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'idleTimeoutMinutes': idleTimeoutMinutes,
  };
}

/// Configuration for the `features:` top-level config namespace.
///
/// Groups optional feature flags that can be enabled independently.
class FeaturesConfig {
  /// Thread binding feature configuration.
  final ThreadBindingFeatureConfig threadBinding;

  /// Creates a features config.
  const FeaturesConfig({
    this.threadBinding = const ThreadBindingFeatureConfig(),
  });

  /// Parses from a YAML map. Returns defaults when [yaml] is `null` or empty.
  factory FeaturesConfig.fromYaml(Map<String, dynamic>? yaml) {
    if (yaml == null) return const FeaturesConfig();
    final threadBindingRaw = yaml['thread_binding'];
    final threadBinding = threadBindingRaw is Map
        ? ThreadBindingFeatureConfig.fromYaml(Map<String, dynamic>.from(threadBindingRaw))
        : const ThreadBindingFeatureConfig();
    return FeaturesConfig(threadBinding: threadBinding);
  }

  /// Serializes to a JSON map.
  Map<String, dynamic> toJson() => {
    'threadBinding': threadBinding.toJson(),
  };
}
