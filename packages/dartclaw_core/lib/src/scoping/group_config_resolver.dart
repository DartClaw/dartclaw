import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'group_entry.dart';

/// The one lookup from a conversation to its structured allowlist row, for
/// both allowlists: group rows keyed by `(ChannelType, groupId)` and DM rows
/// keyed by `(ChannelType, peerId)`.
///
/// Only rows that carry at least one optional field (`name`, `project`,
/// `model`, `effort`, or `agent`) are stored — plain-string-equivalent rows
/// (all optional fields null) are omitted and every lookup returns null for
/// them.
class GroupConfigResolver {
  final Map<(ChannelType, String), GroupEntry> _groups;
  final Map<(ChannelType, String), GroupEntry> _dms;

  const new _(this._groups, this._dms);

  /// Builds a resolver from per-channel group rows and per-channel DM rows.
  ///
  /// Rows where all optional fields are null are skipped (they are
  /// semantically identical to plain-string entries and don't need lookup).
  factory fromChannelEntries(
    Map<ChannelType, List<GroupEntry>> groups, {
    Map<ChannelType, List<GroupEntry>> dms = const {},
  }) => GroupConfigResolver._(_index(groups), _index(dms));

  static Map<(ChannelType, String), GroupEntry> _index(Map<ChannelType, List<GroupEntry>> entries) {
    final map = <(ChannelType, String), GroupEntry>{};
    for (final MapEntry(:key, :value) in entries.entries) {
      for (final entry in value) {
        if (entry.name != null ||
            entry.project != null ||
            entry.model != null ||
            entry.effort != null ||
            entry.agent != null) {
          map[(key, entry.id)] = entry;
        }
      }
    }
    return map;
  }

  /// Returns the group row for [channelType] + [groupId], or null if the
  /// entry is a plain string (no overrides) or not found.
  GroupEntry? resolve(ChannelType channelType, String groupId) => _groups[(channelType, groupId)];

  /// Returns the DM row for [channelType] + [peerId], or null if the entry is
  /// a plain string (no overrides) or not found.
  GroupEntry? resolveDm(ChannelType channelType, String peerId) => _dms[(channelType, peerId)];

  /// Returns the row owning a conversation: the group row when [groupId] is
  /// given, else the DM row for [peerId].
  GroupEntry? resolveRow(ChannelType channelType, {String? groupId, String? peerId}) {
    if (groupId != null) return resolve(channelType, groupId);
    if (peerId != null) return resolveDm(channelType, peerId);
    return null;
  }

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
