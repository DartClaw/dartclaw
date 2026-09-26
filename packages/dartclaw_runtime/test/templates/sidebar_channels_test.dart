import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/templates/loader.dart';
import 'package:dartclaw_runtime/src/templates/sidebar.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  group('sidebarTemplate showChannels', () {
    test('showChannels true with no channels renders the section and placeholder', () {
      final html = sidebarTemplate(showChannels: true, navItems: const []);

      expect(html, contains('Channels'));
      expect(html, contains('No active channels'));
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

    test('project-free first paint keeps inbox view controls but hides project navigation', () {
      final html = sidebarTemplate(
        showChannels: false,
        mainSession: const (id: 'agent', title: 'Agent', type: SessionType.main, provider: 'claude'),
        navItems: const [],
      );

      expect(html, contains('data-inbox-view="" data-icon="sliders"'));
      expect(html, contains('data-inbox-scope="" data-project-controls="" hidden=""'));
      expect(html, contains('data-sidebar-projects="" hidden=""'));
      expect(html, contains('>Chats</div>'));
    });
  });
}
