/// How DM sessions are scoped.
enum DmScope {
  /// All DMs share a single session.
  shared,

  /// One session per contact (across channels).
  perContact,

  /// One session per (channel, contact) pair.
  perChannelContact;

  /// Parses a YAML kebab-case value. Returns `null` for unknown values.
  static DmScope? fromYaml(String value) {
    final normalized = value.replaceAll('_', '-');
    return switch (normalized) {
      'shared' => DmScope.shared,
      'per-contact' => DmScope.perContact,
      'per-channel-contact' => DmScope.perChannelContact,
      _ => null,
    };
  }

  /// Returns the YAML kebab-case representation.
  String toYaml() => switch (this) {
    DmScope.shared => 'shared',
    DmScope.perContact => 'per-contact',
    DmScope.perChannelContact => 'per-channel-contact',
  };
}

/// How group sessions are scoped.
enum GroupScope {
  /// All group messages share a single session.
  shared,

  /// One session per group member.
  perMember;

  /// Parses a YAML kebab-case value. Returns `null` for unknown values.
  static GroupScope? fromYaml(String value) {
    final normalized = value.replaceAll('_', '-');
    return switch (normalized) {
      'shared' => GroupScope.shared,
      'per-member' => GroupScope.perMember,
      _ => null,
    };
  }

  /// Returns the YAML kebab-case representation.
  String toYaml() => switch (this) {
    GroupScope.shared => 'shared',
    GroupScope.perMember => 'per-member',
  };
}

/// Per-channel scope overrides. Nullable fields fall back to global defaults.
class ChannelScopeConfig {
  /// DM scope override for the channel, or `null` to use the global value.
  final DmScope? dmScope;

  /// Group scope override for the channel, or `null` to use the global value.
  final GroupScope? groupScope;

  /// Model override for the channel, or `null` to use the scope/global value.
  final String? model;

  /// Effort override for the channel, or `null` to use the scope/global value.
  final String? effort;

  /// Creates a per-channel scope override.
  const ChannelScopeConfig({this.dmScope, this.groupScope, this.model, this.effort});

  /// Empty config — both fields null (use global defaults).
  const ChannelScopeConfig.empty() : dmScope = null, groupScope = null, model = null, effort = null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChannelScopeConfig &&
          dmScope == other.dmScope &&
          groupScope == other.groupScope &&
          model == other.model &&
          effort == other.effort;

  @override
  int get hashCode => Object.hash(dmScope, groupScope, model, effort);

  @override
  String toString() => 'ChannelScopeConfig(dmScope: $dmScope, groupScope: $groupScope, model: $model, effort: $effort)';
}

/// Top-level session scope configuration with per-channel overrides.
class SessionScopeConfig {
  /// Default DM session scope for all channels.
  final DmScope dmScope;

  /// Default group session scope for all channels.
  final GroupScope groupScope;

  /// Per-channel scope overrides keyed by channel type name.
  final Map<String, ChannelScopeConfig> channels;

  /// Default model override for channel-routed turns in this scope.
  final String? model;

  /// Default effort override for channel-routed turns in this scope.
  final String? effort;

  /// Creates a session scope configuration.
  const SessionScopeConfig({
    required this.dmScope,
    required this.groupScope,
    this.channels = const {},
    this.model,
    this.effort,
  });

  /// Default scope configuration: per-channel-contact DMs, shared groups.
  const SessionScopeConfig.defaults()
    : dmScope = DmScope.perChannelContact,
      groupScope = GroupScope.shared,
      channels = const {},
      model = null,
      effort = null;

  /// Returns resolved scope config for [channelType], with per-channel
  /// overrides falling back to global defaults.
  ChannelScopeConfig forChannel(String channelType) {
    final override = channels[channelType];
    return ChannelScopeConfig(
      dmScope: override?.dmScope ?? dmScope,
      groupScope: override?.groupScope ?? groupScope,
      model: override?.model ?? model,
      effort: override?.effort ?? effort,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! SessionScopeConfig) return false;
    if (dmScope != other.dmScope || groupScope != other.groupScope || model != other.model || effort != other.effort) {
      return false;
    }
    if (channels.length != other.channels.length) return false;
    for (final entry in channels.entries) {
      if (other.channels[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    var h = Object.hash(dmScope, groupScope, model, effort);
    final sortedKeys = channels.keys.toList()..sort();
    for (final key in sortedKeys) {
      h = Object.hash(h, key, channels[key]);
    }
    return h;
  }

  @override
  String toString() =>
      'SessionScopeConfig(dmScope: $dmScope, groupScope: $groupScope, channels: $channels, model: $model, '
      'effort: $effort)';
}
