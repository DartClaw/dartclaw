import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/templates/loader.dart';
import 'package:dartclaw_server/src/templates/sidebar.dart';
import 'package:dartclaw_server/src/web/sidebar_data_builder.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  group('SidebarDataBuilder', () {
    test('SC: Builder produces identical SidebarData payload with active session id', () async {
      var nextId = 0;
      final sessions = InMemorySessionService(idGenerator: () => 'session-${++nextId}');
      final main = await sessions.createSession(type: SessionType.main, provider: 'codex');
      final dm = await sessions.createSession(
        type: SessionType.channel,
        channelKey: SessionKey.dmPerContact(peerId: '+15551234567'),
        provider: 'claude',
      );
      final group = await sessions.createSession(
        type: SessionType.channel,
        channelKey: SessionKey.groupShared(channelType: 'signal', groupId: 'team'),
        provider: 'codex',
      );
      final user = await sessions.createSession(type: SessionType.user, provider: 'claude');
      final archived = await sessions.createSession(type: SessionType.archive, provider: 'codex');
      await sessions.createSession(type: SessionType.task, provider: 'claude');
      await sessions.createSession(type: SessionType.cron, provider: 'claude');

      final builder = SidebarDataBuilder(
        sessions: sessions,
        defaultProvider: 'claude',
        showChannels: true,
        tasksEnabled: false,
      );

      final data = await builder.build(activeSessionId: user.id);

      expect(data.main, (id: main.id, title: '', type: SessionType.main, provider: 'codex'));
      expect(data.dmChannels, [(id: dm.id, title: '', type: SessionType.channel, provider: 'claude')]);
      expect(data.groupChannels, [(id: group.id, title: '', type: SessionType.channel, provider: 'codex')]);
      expect(data.activeEntries, [(id: user.id, title: '', type: SessionType.user, provider: 'claude')]);
      expect(data.archivedEntries, [(id: archived.id, title: '', type: SessionType.archive, provider: 'codex')]);
      expect(data.activeTasks, isEmpty);
      expect(data.activeWorkflows, isEmpty);
      expect(data.showChannels, isTrue);
      expect(data.tasksEnabled, isFalse);
      expect(data.activeSessionId, user.id);
    });

    test('SC: Empty / null active-session case marks no rendered entries active', () async {
      var nextId = 0;
      final sessions = InMemorySessionService(idGenerator: () => 'session-${++nextId}');
      await sessions.createSession(type: SessionType.main, provider: 'claude');
      await sessions.createSession(type: SessionType.user, provider: 'codex');
      final builder = SidebarDataBuilder(
        sessions: sessions,
        defaultProvider: 'claude',
        showChannels: true,
        tasksEnabled: false,
      );

      final data = await builder.build();
      final html = buildSidebar(sidebarData: data, navItems: const []);

      expect(data.activeSessionId, isNull);
      expect(html, isNot(contains('class="session-link active"')));
    });
  });
}
