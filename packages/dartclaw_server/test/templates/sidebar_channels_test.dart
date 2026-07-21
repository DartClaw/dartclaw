import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/templates/loader.dart';
import 'package:dartclaw_server/src/templates/sidebar.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  group('sidebarTemplate showChannels', () {
    test('showChannels true with no channels renders the section and placeholder', () {
      final html = sidebarTemplate(showChannels: true, navItems: const []);

      expect(html, contains('Channels'));
      expect(html, contains('No active channels'));
    });

    test('showChannels false hides the channels section entirely', () {
      final html = sidebarTemplate(showChannels: false, navItems: const []);

      expect(html, isNot(contains('Channels')));
      expect(html, isNot(contains('No active channels')));
    });

    test('showChannels true with DM channels renders channel entries', () {
      final html = sidebarTemplate(
        showChannels: true,
        dmChannels: const [(id: 'dm-1', title: 'Team DM', type: SessionType.channel, provider: 'claude')],
        navItems: const [],
      );

      expect(html, contains('Channels'));
      expect(html, contains('Team DM'));
      expect(html, isNot(contains('No active channels')));
    });

    test('tasksEnabled adds the explicit task SSE marker', () {
      final html = sidebarTemplate(tasksEnabled: true, navItems: const []);

      expect(html, contains('data-tasks-enabled="true"'));
    });

    test('session and channel rows mount identicons without scope glyphs', () {
      final html = sidebarTemplate(
        dmChannels: const [(id: 'dm-1', title: 'Team DM', type: SessionType.channel, provider: 'claude')],
        groupChannels: const [(id: 'group-1', title: 'Team Group', type: SessionType.channel, provider: 'claude')],
        activeEntries: const [(id: 'chat-1', title: 'Inbox', type: SessionType.user, provider: 'codex')],
        archivedEntries: const [(id: 'chat-2', title: 'Done', type: SessionType.archive, provider: 'codex')],
        navItems: const [],
      );

      for (final id in ['dm-1', 'group-1', 'chat-1', 'chat-2']) {
        expect(html, contains('class="identicon" aria-hidden="true" data-identicon-id="$id"'));
      }
      expect(html, isNot(contains('data-icon="message-circle"')));
      expect(html, isNot(contains('data-icon="archive"')));
      expect(html, isNot(contains('data-icon="hash"')));
      expect(html, contains('class="provider-badge provider-badge-claude"'));
      expect(html, contains('class="sidebar-archive-list" hidden'));
    });
  });
}
