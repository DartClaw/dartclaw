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
  });
}
