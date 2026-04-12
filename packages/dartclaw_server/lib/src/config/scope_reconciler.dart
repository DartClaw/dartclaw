import 'dart:async';

import 'package:dartclaw_config/dartclaw_config.dart' show DmScope, GroupScope, SessionScopeConfig;
import 'package:dartclaw_core/dartclaw_core.dart' show ConfigChangedEvent, EventBus, LiveScopeConfig;
import 'package:logging/logging.dart';

/// Subscribes to scope config changes and updates the live scope holder.
class ScopeReconciler {
  static final _log = Logger('ScopeReconciler');

  final LiveScopeConfig liveScopeConfig;
  StreamSubscription<ConfigChangedEvent>? _subscription;

  ScopeReconciler({required this.liveScopeConfig});

  void subscribe(EventBus bus) {
    _subscription = bus.on<ConfigChangedEvent>().listen(_onConfigChanged);
  }

  void _onConfigChanged(ConfigChangedEvent event) {
    if (!_hasScopeChange(event.changedKeys)) return;

    final current = liveScopeConfig.current;
    final nextDmScope = _parseDmScope(event.newValues['sessions.dm_scope']) ?? current.dmScope;
    final nextGroupScope = _parseGroupScope(event.newValues['sessions.group_scope']) ?? current.groupScope;

    liveScopeConfig.update(
      SessionScopeConfig(dmScope: nextDmScope, groupScope: nextGroupScope, channels: current.channels),
    );
  }

  Future<void> cancel() async {
    await _subscription?.cancel();
  }

  bool _hasScopeChange(List<String> changedKeys) =>
      changedKeys.contains('sessions.dm_scope') || changedKeys.contains('sessions.group_scope');

  DmScope? _parseDmScope(Object? value) {
    if (value is! String) return null;
    final parsed = DmScope.fromYaml(value);
    if (parsed == null) {
      _log.warning('Ignoring invalid sessions.dm_scope value: $value');
    }
    return parsed;
  }

  GroupScope? _parseGroupScope(Object? value) {
    if (value is! String) return null;
    final parsed = GroupScope.fromYaml(value);
    if (parsed == null) {
      _log.warning('Ignoring invalid sessions.group_scope value: $value');
    }
    return parsed;
  }
}
