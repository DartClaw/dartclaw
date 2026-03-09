import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

/// Lightweight config describing a channel's group access settings.
///
/// Decouples [GroupSessionInitializer] from WhatsApp/Signal-specific config types.
class ChannelGroupConfig {
  final String channelType;
  final bool groupAccessEnabled;
  final List<String> groupAllowlist;

  const ChannelGroupConfig({
    required this.channelType,
    required this.groupAccessEnabled,
    required this.groupAllowlist,
  });
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
  StreamSubscription<ConfigChangedEvent>? _subscription;

  GroupSessionInitializer({
    required SessionService sessions,
    EventBus? eventBus,
    required List<ChannelGroupConfig> channelConfigs,
  })  : _sessions = sessions,
        _eventBus = eventBus,
        _channelConfigs = channelConfigs;

  /// Pre-create sessions for all configured groups and subscribe to config changes.
  Future<void> initialize() async {
    _subscription = _eventBus?.on<ConfigChangedEvent>().listen(_onConfigChanged);

    for (final config in _channelConfigs) {
      if (!config.groupAccessEnabled) continue;
      await _ensureGroupSessions(config.channelType, config.groupAllowlist);
    }
  }

  Future<void> _ensureGroupSessions(String channelType, List<String> groupIds) async {
    for (final groupId in groupIds) {
      try {
        final key = SessionKey.groupShared(
          channelType: channelType,
          groupId: groupId,
        );
        final session = await _sessions.getOrCreateByKey(
          key,
          type: SessionType.channel,
        );
        // Set title to group ID only if title is null (newly created).
        // Don't overwrite user-set titles.
        if (session.title == null) {
          await _sessions.updateTitle(session.id, groupId);
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
      final channelConfig = _channelConfigs
          .where((c) => c.channelType == channelType)
          .firstOrNull;
      if (channelConfig == null || !channelConfig.groupAccessEnabled) continue;

      final newList = event.newValues[key];
      if (newList is! List) continue;

      final groupIds = newList.whereType<String>().toList();
      unawaited(_ensureGroupSessions(channelType, groupIds).catchError(
        (Object e) => _log.warning('Failed to auto-create group sessions on config change', e),
      ));
    }
  }

  void dispose() {
    _subscription?.cancel();
    _subscription = null;
  }
}
