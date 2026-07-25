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
    activeTasks: <SidebarActiveTask>[],
    activeWorkflows: <SidebarActiveWorkflow>[],
    showChannels: true,
    tasksEnabled: false,
    activeSessionId: null,
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
      expect(html, contains('click->dc-scheduling#editJob'));
      expect(html, contains('click->dc-scheduling#confirmDeleteJob'));
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
      expect(html, isNot(contains('click->dc-scheduling#editJob')));
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

    test('forms use hidden attributes and canonical metric cards', () {
      final html = schedulingTemplate(sidebarData: emptySidebar, navItems: emptyNavItems, jobs: [], systemJobNames: []);
      expect(html, contains('job-form'));
      expect(html, contains('class="well-content" id="job-form" hidden=""'));
      expect(html, contains('class="well-content" id="task-form" hidden=""'));
      expect(html, isNot(contains('style=')));
      expect(html, contains('click->dc-scheduling#toggleJobForm'));
      expect(html, contains('card-metric--info'));
      expect(html, contains('card-metric--warning'));
      expect(html, contains('metric-value">Disabled</div>'));
    });

    test('active heartbeat renders accent metric and success badge', () {
      final html = schedulingTemplate(
        sidebarData: emptySidebar,
        navItems: emptyNavItems,
        heartbeatEnabled: true,
        heartbeatIntervalMinutes: 15,
      );

      expect(html, contains('card-metric--accent'));
      expect(html, contains('metric-value">Active</div>'));
      expect(html, contains('every 15 min'));
      expect(html, contains('status-badge-success'));
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

    test('task-type entries are excluded from the Scheduled Jobs table (no phantom row)', () {
      // Task-type jobs share the unified scheduling.jobs list but belong in the
      // Scheduled Tasks table; a task entry (no top-level name) must not render
      // as a blank, actionable row in Scheduled Jobs.
      final html = schedulingTemplate(
        sidebarData: emptySidebar,
        navItems: emptyNavItems,
        jobs: [
          {
            'type': 'task',
            'schedule': '0 9 * * *',
            'task': {'title': 'nightly digest'},
          },
        ],
        systemJobNames: [],
      );
      expect(html, contains('No scheduled jobs configured'));
      expect(html, isNot(contains('click->dc-scheduling#editJob')));
      expect(html, isNot(contains('click->dc-scheduling#confirmDeleteJob')));
    });

    test('prompt jobs render even when a task-type entry is present', () {
      final html = schedulingTemplate(
        sidebarData: emptySidebar,
        navItems: emptyNavItems,
        jobs: [
          {'name': 'my-cron', 'schedule': '0 7 * * *', 'delivery': 'announce', 'status': 'active'},
          {
            'type': 'task',
            'schedule': '0 9 * * *',
            'task': {'title': 'nightly digest'},
          },
        ],
        systemJobNames: [],
      );
      expect(html, contains('my-cron'));
      // Exactly one actionable row — the prompt job — proving the task entry
      // added no second (phantom) row.
      expect('click->dc-scheduling#editJob'.allMatches(html).length, 1);
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
