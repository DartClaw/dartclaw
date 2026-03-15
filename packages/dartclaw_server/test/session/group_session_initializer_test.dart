import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late SessionService sessions;
  late EventBus eventBus;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('group_session_init_test_');
    sessions = SessionService(baseDir: tempDir.path, eventBus: EventBus());
    eventBus = EventBus();
  });

  tearDown(() {
    eventBus.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('startup initialization', () {
    test('creates sessions for allowlisted groups', () async {
      final init = GroupSessionInitializer(
        sessions: sessions,
        eventBus: eventBus,
        channelConfigs: [
          const ChannelGroupConfig(
            channelType: 'whatsapp',
            groupAccessEnabled: true,
            groupAllowlist: ['grp-wa-1', 'grp-wa-2'],
          ),
          const ChannelGroupConfig(channelType: 'signal', groupAccessEnabled: true, groupAllowlist: ['grp-sig-1']),
        ],
      );
      await init.initialize();
      init.dispose();

      final allSessions = await sessions.listSessions(type: SessionType.channel);
      expect(allSessions, hasLength(3));
    });

    test('skips channels with disabled group access', () async {
      final init = GroupSessionInitializer(
        sessions: sessions,
        eventBus: eventBus,
        channelConfigs: [
          const ChannelGroupConfig(channelType: 'whatsapp', groupAccessEnabled: false, groupAllowlist: ['grp-wa-1']),
          const ChannelGroupConfig(channelType: 'signal', groupAccessEnabled: true, groupAllowlist: ['grp-sig-1']),
        ],
      );
      await init.initialize();
      init.dispose();

      final allSessions = await sessions.listSessions(type: SessionType.channel);
      expect(allSessions, hasLength(1));
    });

    test('idempotent — duplicate calls do not create extra sessions', () async {
      final init = GroupSessionInitializer(
        sessions: sessions,
        eventBus: eventBus,
        channelConfigs: [
          const ChannelGroupConfig(channelType: 'whatsapp', groupAccessEnabled: true, groupAllowlist: ['grp-wa-1']),
        ],
      );
      await init.initialize();

      final firstCount = (await sessions.listSessions(type: SessionType.channel)).length;

      // Create a second initializer and initialize again
      final init2 = GroupSessionInitializer(
        sessions: sessions,
        eventBus: eventBus,
        channelConfigs: [
          const ChannelGroupConfig(channelType: 'whatsapp', groupAccessEnabled: true, groupAllowlist: ['grp-wa-1']),
        ],
      );
      await init2.initialize();
      init.dispose();
      init2.dispose();

      final secondCount = (await sessions.listSessions(type: SessionType.channel)).length;
      expect(secondCount, firstCount);
    });

    test('no sessions created for empty allowlist', () async {
      final init = GroupSessionInitializer(
        sessions: sessions,
        eventBus: eventBus,
        channelConfigs: [
          const ChannelGroupConfig(channelType: 'whatsapp', groupAccessEnabled: true, groupAllowlist: []),
        ],
      );
      await init.initialize();
      init.dispose();

      final allSessions = await sessions.listSessions(type: SessionType.channel);
      expect(allSessions, isEmpty);
    });
  });

  group('config change', () {
    test('creates session for newly added group', () async {
      final init = GroupSessionInitializer(
        sessions: sessions,
        eventBus: eventBus,
        channelConfigs: [
          const ChannelGroupConfig(channelType: 'whatsapp', groupAccessEnabled: true, groupAllowlist: []),
        ],
      );
      await init.initialize();

      // Fire config change with new group
      eventBus.fire(
        ConfigChangedEvent(
          changedKeys: ['channels.whatsapp.group_allowlist'],
          oldValues: {'channels.whatsapp.group_allowlist': <String>[]},
          newValues: {
            'channels.whatsapp.group_allowlist': ['new-grp-1'],
          },
          requiresRestart: true,
          timestamp: DateTime.now(),
        ),
      );

      // Wait for fire-and-forget processing
      await Future<void>.delayed(const Duration(milliseconds: 100));
      init.dispose();

      final allSessions = await sessions.listSessions(type: SessionType.channel);
      expect(allSessions, hasLength(1));
    });

    test('ignores config change when group access is disabled', () async {
      final init = GroupSessionInitializer(
        sessions: sessions,
        eventBus: eventBus,
        channelConfigs: [
          const ChannelGroupConfig(channelType: 'whatsapp', groupAccessEnabled: false, groupAllowlist: []),
        ],
      );
      await init.initialize();

      eventBus.fire(
        ConfigChangedEvent(
          changedKeys: ['channels.whatsapp.group_allowlist'],
          oldValues: {'channels.whatsapp.group_allowlist': <String>[]},
          newValues: {
            'channels.whatsapp.group_allowlist': ['new-grp-1'],
          },
          requiresRestart: true,
          timestamp: DateTime.now(),
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));
      init.dispose();

      final allSessions = await sessions.listSessions(type: SessionType.channel);
      expect(allSessions, isEmpty);
    });

    test('ignores non-group-allowlist config changes', () async {
      final init = GroupSessionInitializer(sessions: sessions, eventBus: eventBus, channelConfigs: []);
      await init.initialize();

      eventBus.fire(
        ConfigChangedEvent(
          changedKeys: ['channels.whatsapp.dm_allowlist'],
          oldValues: {},
          newValues: {
            'channels.whatsapp.dm_allowlist': ['+123'],
          },
          requiresRestart: true,
          timestamp: DateTime.now(),
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));
      init.dispose();

      final allSessions = await sessions.listSessions(type: SessionType.channel);
      expect(allSessions, isEmpty);
    });
  });

  group('session titles', () {
    test('new session gets group ID as title', () async {
      final init = GroupSessionInitializer(
        sessions: sessions,
        eventBus: eventBus,
        channelConfigs: [
          const ChannelGroupConfig(channelType: 'whatsapp', groupAccessEnabled: true, groupAllowlist: ['my-group']),
        ],
      );
      await init.initialize();
      init.dispose();

      final allSessions = await sessions.listSessions(type: SessionType.channel);
      expect(allSessions, hasLength(1));
      expect(allSessions.first.title, 'my-group');
    });

    test('existing session with user-set title is not overwritten', () async {
      // Pre-create a session with the same key
      final key = SessionKey.groupShared(channelType: 'whatsapp', groupId: 'my-group');
      final session = await sessions.getOrCreateByKey(key, type: SessionType.channel);
      await sessions.updateTitle(session.id, 'Custom Name');

      final init = GroupSessionInitializer(
        sessions: sessions,
        eventBus: eventBus,
        channelConfigs: [
          const ChannelGroupConfig(channelType: 'whatsapp', groupAccessEnabled: true, groupAllowlist: ['my-group']),
        ],
      );
      await init.initialize();
      init.dispose();

      final allSessions = await sessions.listSessions(type: SessionType.channel);
      expect(allSessions, hasLength(1));
      expect(allSessions.first.title, 'Custom Name');
    });
  });

  group('dispose', () {
    test('stops listening to events after dispose', () async {
      final init = GroupSessionInitializer(sessions: sessions, eventBus: eventBus, channelConfigs: []);
      await init.initialize();
      init.dispose();

      // Fire event after dispose — should be ignored
      eventBus.fire(
        ConfigChangedEvent(
          changedKeys: ['channels.signal.group_allowlist'],
          oldValues: {},
          newValues: {
            'channels.signal.group_allowlist': ['grp-after-dispose'],
          },
          requiresRestart: true,
          timestamp: DateTime.now(),
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 100));

      final allSessions = await sessions.listSessions(type: SessionType.channel);
      expect(allSessions, isEmpty);
    });
  });
}
