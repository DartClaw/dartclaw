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

  /// Creates a per-channel scope override.
  const ChannelScopeConfig({this.dmScope, this.groupScope});

  /// Empty config — both fields null (use global defaults).
  const ChannelScopeConfig.empty() : dmScope = null, groupScope = null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChannelScopeConfig && dmScope == other.dmScope && groupScope == other.groupScope;

  @override
  int get hashCode => Object.hash(dmScope, groupScope);

  @override
  String toString() => 'ChannelScopeConfig(dmScope: $dmScope, groupScope: $groupScope)';
}

/// Top-level session scope configuration with per-channel overrides.
class SessionScopeConfig {
  /// Default DM session scope for all channels.
  final DmScope dmScope;

  /// Default group session scope for all channels.
  final GroupScope groupScope;

  /// Per-channel scope overrides keyed by channel type name.
  final Map<String, ChannelScopeConfig> channels;

  /// Creates a session scope configuration.
  const SessionScopeConfig({required this.dmScope, required this.groupScope, this.channels = const {}});

  /// Default scope configuration: per-channel-contact DMs, shared groups.
  const SessionScopeConfig.defaults()
    : dmScope = DmScope.perChannelContact,
      groupScope = GroupScope.shared,
      channels = const {};

  /// Returns resolved scope config for [channelType], with per-channel
  /// overrides falling back to global defaults.
  ChannelScopeConfig forChannel(String channelType) {
    final override = channels[channelType];
    return ChannelScopeConfig(dmScope: override?.dmScope ?? dmScope, groupScope: override?.groupScope ?? groupScope);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! SessionScopeConfig) return false;
    if (dmScope != other.dmScope || groupScope != other.groupScope) return false;
    if (channels.length != other.channels.length) return false;
    for (final entry in channels.entries) {
      if (other.channels[entry.key] != entry.value) return false;
    }
    return true;
  }

  @override
  int get hashCode {
    var h = Object.hash(dmScope, groupScope);
    for (final entry in channels.entries) {
      h = Object.hash(h, entry.key, entry.value);
    }
    return h;
  }

  @override
  String toString() => 'SessionScopeConfig(dmScope: $dmScope, groupScope: $groupScope, channels: $channels)';
}
