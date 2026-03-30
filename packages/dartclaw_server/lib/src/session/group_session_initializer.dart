import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

/// Lightweight config describing a channel's group access settings.
///
/// Decouples [GroupSessionInitializer] from WhatsApp/Signal-specific config types.
class ChannelGroupConfig {
  final String channelType;
  final bool groupAccessEnabled;
  final List<GroupEntry> groupEntries;

  const ChannelGroupConfig({
    required this.channelType,
    required this.groupAccessEnabled,
    required this.groupEntries,
  });

  /// Returns the group IDs from [groupEntries] as a plain string list.
  List<String> get groupIds => groupEntries.map((e) => e.id).toList();
}

/// Pre-creates sessions for allowlisted groups so they appear in the sidebar
/// immediately, without waiting for the first inbound message.
///
/// Runs at two trigger points:
/// 1. On server startup via [initialize].
/// 2. On config change (group added to allowlist) via [ConfigChangedEvent].
class GroupSessionInitializer {
  static final _log = Logger('GroupSessionInitializer');

  final SessionService _sessions;
  final EventBus? _eventBus;
  final List<ChannelGroupConfig> _channelConfigs;
  final Future<String?> Function(String channelType, String groupId)? _displayNameResolver;
  StreamSubscription<ConfigChangedEvent>? _subscription;

  GroupSessionInitializer({
    required SessionService sessions,
    EventBus? eventBus,
    required List<ChannelGroupConfig> channelConfigs,
    Future<String?> Function(String channelType, String groupId)? displayNameResolver,
  }) : _sessions = sessions,
       _eventBus = eventBus,
       _channelConfigs = channelConfigs,
       _displayNameResolver = displayNameResolver;

  /// Pre-create sessions for all configured groups and subscribe to config changes.
  Future<void> initialize() async {
    _subscription = _eventBus?.on<ConfigChangedEvent>().listen(_onConfigChanged);

    for (final config in _channelConfigs) {
      if (!config.groupAccessEnabled) continue;
      await _ensureGroupSessions(config.channelType, config.groupEntries);
    }
  }

  Future<void> _ensureGroupSessions(String channelType, List<GroupEntry> entries) async {
    for (final entry in entries) {
      final groupId = entry.id;
      try {
        final key = SessionKey.groupShared(channelType: channelType, groupId: groupId);
        final session = await _sessions.getOrCreateByKey(key, type: SessionType.channel);
        // Set title only if null (newly created) — don't overwrite user-set titles.
        if (session.title == null) {
          // Display name resolution chain:
          // 1. Structured GroupEntry.name (trimmed, non-empty)
          // 2. displayNameResolver callback
          // 3. Raw group ID
          var title = groupId;
          final structuredName = entry.name;
          if (structuredName != null && structuredName.trim().isNotEmpty) {
            title = structuredName.trim();
          } else {
            final resolver = _displayNameResolver;
            if (resolver != null) {
              try {
                final resolved = await resolver(channelType, groupId);
                if (resolved != null && resolved.trim().isNotEmpty) {
                  title = resolved.trim();
                }
              } catch (e, st) {
                _log.warning('Failed to resolve display name for $channelType:$groupId', e, st);
              }
            }
          }
          await _sessions.updateTitle(session.id, title);
        }
        _log.fine('Ensured group session for $channelType:$groupId');
      } catch (e) {
        _log.warning('Failed to create group session for $channelType:$groupId', e);
      }
    }
  }

  void _onConfigChanged(ConfigChangedEvent event) {
    for (final key in event.changedKeys) {
      final match = RegExp(r'^channels\.(\w+)\.group_allowlist$').firstMatch(key);
      if (match == null) continue;

      final channelType = match.group(1)!;

      // Only auto-create if group access is enabled for this channel
      final channelConfig = _channelConfigs.where((c) => c.channelType == channelType).firstOrNull;
      if (channelConfig == null || !channelConfig.groupAccessEnabled) continue;

      final newList = event.newValues[key];
      if (newList is! List) continue;

      // Extract IDs from mixed list (strings or maps with 'id' key).
      // Wrap as GroupEntry(id: ...) — structured overrides not available here
      // since config change fires with raw YAML values.
      final entries = <GroupEntry>[];
      for (final item in newList) {
        if (item is String) {
          entries.add(GroupEntry(id: item));
        } else if (item is Map) {
          final id = item['id'];
          if (id is String && id.trim().isNotEmpty) {
            entries.add(GroupEntry(id: id));
          }
        }
      }
      unawaited(
        _ensureGroupSessions(
          channelType,
          entries,
        ).catchError((Object e) => _log.warning('Failed to auto-create group sessions on config change', e)),
      );
    }
  }

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
  }
}
