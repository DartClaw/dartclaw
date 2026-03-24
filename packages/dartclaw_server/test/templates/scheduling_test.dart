import 'package:dartclaw_server/src/templates/loader.dart';
import 'package:dartclaw_server/src/templates/scheduling.dart';
import 'package:dartclaw_server/src/templates/sidebar.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  final SidebarData emptySidebar = (
    main: null,
    dmChannels: <SidebarSession>[],
    groupChannels: <SidebarSession>[],
    activeEntries: <SidebarSession>[],
    archivedEntries: <SidebarSession>[],
    showChannels: true,
    tasksEnabled: false,
  );
  const emptyNavItems = <NavItem>[];

  group('schedulingTemplate', () {
    test('renders system badge for system jobs', () {
      final html = schedulingTemplate(
        sidebarData: emptySidebar,
        navItems: emptyNavItems,
        jobs: [
          {'name': 'heartbeat', 'schedule': '*/5 * * * *', 'delivery': 'none', 'status': 'active'},
        ],
        systemJobNames: ['heartbeat'],
      );
      expect(html, contains('system-badge'));
      expect(html, contains('SYSTEM'));
    });

    test('renders action buttons for user jobs', () {
      final html = schedulingTemplate(
        sidebarData: emptySidebar,
        navItems: emptyNavItems,
        jobs: [
          {'name': 'my-cron', 'schedule': '0 7 * * *', 'delivery': 'announce', 'status': 'active'},
        ],
        systemJobNames: ['heartbeat'],
      );
      expect(html, contains('action-btns'));
      expect(html, contains('data-action="edit-job"'));
      expect(html, contains('data-action="confirm-delete-job"'));
    });

    test('system jobs have no action buttons', () {
      final html = schedulingTemplate(
        sidebarData: emptySidebar,
        navItems: emptyNavItems,
        jobs: [
          {'name': 'heartbeat', 'schedule': '*/5 * * * *', 'delivery': 'none', 'status': 'active'},
        ],
        systemJobNames: ['heartbeat'],
      );
      // System jobs should not have edit/delete buttons
      expect(html, isNot(contains('data-action="edit-job"')));
    });

    test('cron human-readable description appears in output', () {
      final html = schedulingTemplate(
        sidebarData: emptySidebar,
        navItems: emptyNavItems,
        jobs: [
          {'name': 'daily-review', 'schedule': '0 7 * * *', 'delivery': 'announce', 'status': 'active'},
        ],
        systemJobNames: [],
      );
      expect(html, contains('cron-human'));
      expect(html, contains('Daily at 7:00 AM'));
    });

    test('empty state when no jobs', () {
      final html = schedulingTemplate(sidebarData: emptySidebar, navItems: emptyNavItems, jobs: [], systemJobNames: []);
      expect(html, contains('No scheduled jobs configured'));
    });

    test('add job form card is present but hidden', () {
      final html = schedulingTemplate(sidebarData: emptySidebar, navItems: emptyNavItems, jobs: [], systemJobNames: []);
      expect(html, contains('job-form'));
      expect(html, contains('display: none'));
      expect(html, contains('data-action="toggle-job-form"'));
    });

    test('restart badge present in form', () {
      final html = schedulingTemplate(sidebarData: emptySidebar, navItems: emptyNavItems, jobs: [], systemJobNames: []);
      expect(html, contains('restart-badge'));
      expect(html, contains('restart required'));
    });

    test('info footer mentions restart requirement', () {
      final html = schedulingTemplate(sidebarData: emptySidebar, navItems: emptyNavItems, jobs: [], systemJobNames: []);
      expect(html, contains('Job changes require a restart'));
    });

    test('row-system class applied to system job rows', () {
      final html = schedulingTemplate(
        sidebarData: emptySidebar,
        navItems: emptyNavItems,
        jobs: [
          {'name': 'memory-pruner', 'schedule': '0 3 * * *', 'delivery': 'none', 'status': 'active'},
        ],
        systemJobNames: ['memory-pruner'],
      );
      expect(html, contains('row-system'));
    });
  });
}
