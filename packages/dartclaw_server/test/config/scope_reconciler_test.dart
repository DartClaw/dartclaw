import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart' show ScopeReconciler;
import 'package:test/test.dart';

void main() {
  group('ScopeReconciler', () {
    late EventBus eventBus;
    late LiveScopeConfig liveScopeConfig;
    late ScopeReconciler reconciler;

    setUp(() {
      eventBus = EventBus();
      liveScopeConfig = LiveScopeConfig(
        SessionScopeConfig(
          dmScope: DmScope.perContact,
          groupScope: GroupScope.shared,
          channels: {'signal': const ChannelScopeConfig(groupScope: GroupScope.perMember)},
        ),
      );
      reconciler = ScopeReconciler(liveScopeConfig: liveScopeConfig);
      reconciler.subscribe(eventBus);
    });

    tearDown(() async {
      await reconciler.cancel();
      await eventBus.dispose();
    });

    test('updates LiveScopeConfig on dm_scope change', () async {
      eventBus.fire(
        ConfigChangedEvent(
          changedKeys: ['sessions.dm_scope'],
          oldValues: {'sessions.dm_scope': 'per-contact'},
          newValues: {'sessions.dm_scope': 'shared'},
          requiresRestart: false,
          timestamp: DateTime.now(),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(liveScopeConfig.current.dmScope, DmScope.shared);
      expect(liveScopeConfig.current.groupScope, GroupScope.shared);
    });

    test('updates LiveScopeConfig on group_scope change', () async {
      eventBus.fire(
        ConfigChangedEvent(
          changedKeys: ['sessions.group_scope'],
          oldValues: {'sessions.group_scope': 'shared'},
          newValues: {'sessions.group_scope': 'per-member'},
          requiresRestart: false,
          timestamp: DateTime.now(),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(liveScopeConfig.current.groupScope, GroupScope.perMember);
      expect(liveScopeConfig.current.dmScope, DmScope.perContact);
    });

    test('ignores irrelevant config changes', () async {
      final before = liveScopeConfig.current;

      eventBus.fire(
        ConfigChangedEvent(
          changedKeys: ['channels.whatsapp.group_allowlist'],
          oldValues: const {},
          newValues: {
            'channels.whatsapp.group_allowlist': ['grp-1'],
          },
          requiresRestart: true,
          timestamp: DateTime.now(),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(liveScopeConfig.current, before);
    });

    test('preserves channels map on update', () async {
      final originalChannels = liveScopeConfig.current.channels;

      eventBus.fire(
        ConfigChangedEvent(
          changedKeys: ['sessions.dm_scope'],
          oldValues: {'sessions.dm_scope': 'per-contact'},
          newValues: {'sessions.dm_scope': 'shared'},
          requiresRestart: false,
          timestamp: DateTime.now(),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(liveScopeConfig.current.channels, same(originalChannels));
      expect(liveScopeConfig.current.channels['signal']?.groupScope, GroupScope.perMember);
    });

    test('preserves other scope when only one changes', () async {
      eventBus.fire(
        ConfigChangedEvent(
          changedKeys: ['sessions.dm_scope'],
          oldValues: {'sessions.dm_scope': 'per-contact'},
          newValues: {'sessions.dm_scope': 'per-channel-contact'},
          requiresRestart: false,
          timestamp: DateTime.now(),
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(liveScopeConfig.current.dmScope, DmScope.perChannelContact);
      expect(liveScopeConfig.current.groupScope, GroupScope.shared);
    });
  });
}
