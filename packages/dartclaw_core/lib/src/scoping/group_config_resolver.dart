import 'package:dartclaw_core/dartclaw_core.dart' show ChannelType;

import 'group_entry.dart';

/// Lookup service for structured [GroupEntry] configuration keyed by
/// `(ChannelType, groupId)`.
///
/// Only entries that carry at least one override field (`name`, `project`,
/// `model`, or `effort`) are stored — plain-string-equivalent entries (all
/// overrides null) are omitted and [resolve] returns null for them.
class GroupConfigResolver {
  final Map<(ChannelType, String), GroupEntry> _entries;

  const GroupConfigResolver._(this._entries);

  /// Builds a resolver from per-channel [GroupEntry] lists.
  ///
  /// Entries where all optional fields are null are skipped (they are
  /// semantically identical to plain-string entries and don't need lookup).
  factory GroupConfigResolver.fromChannelEntries(Map<ChannelType, List<GroupEntry>> entries) {
    final map = <(ChannelType, String), GroupEntry>{};
    for (final MapEntry(:key, :value) in entries.entries) {
      for (final entry in value) {
        if (entry.name != null || entry.project != null || entry.model != null || entry.effort != null) {
          map[(key, entry.id)] = entry;
        }
      }
    }
    return GroupConfigResolver._(map);
  }

  /// Returns the [GroupEntry] for [channelType] + [groupId], or null if the
  /// entry is a plain string (no overrides) or not found.
  GroupEntry? resolve(ChannelType channelType, String groupId) => _entries[(channelType, groupId)];

  /// Normalizes a config-file channel key (e.g. `'google_chat'`) to the
  /// matching [ChannelType], or null if not recognized.
  ///
  /// Handles the `google_chat` vs `googlechat` discrepancy by stripping
  /// underscores before comparison.
  static ChannelType? normalizeConfigKey(String configKey) {
    final normalized = configKey.replaceAll('_', '').toLowerCase();
    for (final type in ChannelType.values) {
      if (type.name.toLowerCase() == normalized) return type;
    }
    return null;
  }
}
