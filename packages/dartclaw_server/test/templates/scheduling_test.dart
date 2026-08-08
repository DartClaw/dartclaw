import 'package:dartclaw_config/dartclaw_config.dart' show ScheduledTaskDefinition;
import 'package:dartclaw_core/dartclaw_core.dart' show TaskType;
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
      expect(html, contains('No scheduled jobs'));
      expect(html, contains('Add a job to have the agent run a prompt on a cron schedule.'));
      expect(html, contains('empty-state-title'));
    });

    test('forms use hidden attributes and canonical metric cards', () {
      final html = schedulingTemplate(sidebarData: emptySidebar, navItems: emptyNavItems, jobs: [], systemJobNames: []);
      expect(html, contains('job-form'));
      expect(html, contains('class="well-content" id="job-form" hidden=""'));
      expect(html, contains('class="well-content" id="task-form" hidden=""'));
      expect(html, isNot(contains('style=')));
      expect(html, contains('click->dc-scheduling#toggleJobForm'));
      // A disabled heartbeat has no interval to report, so the block shows only
      // its status badge. Nothing non-numeric reaches the 32px metric tier.
      expect(html, isNot(contains('card-metric')));
      expect(html, isNot(contains('metric-value')));
      expect(html, contains('status-badge-muted'));
      expect(html, contains('Disabled'));
      expect(RegExp(r'type="radio"[^>]*class="form-radio"').allMatches(html), hasLength(3));
      expect(html, contains('role="radiogroup" aria-labelledby="job-delivery-label"'));
      expect(
        RegExp(r'<label class="form-field form-field--checkbox"><input type="radio"').allMatches(html),
        hasLength(3),
      );
      expect(
        html,
        contains(
          '<label class="form-field form-field--checkbox">\n'
          '            <input type="checkbox" class="form-checkbox" id="task-enabled"',
        ),
      );
    });

    test('active heartbeat renders one numeric metric and one status badge', () {
      final html = schedulingTemplate(
        sidebarData: emptySidebar,
        navItems: emptyNavItems,
        heartbeatEnabled: true,
        heartbeatIntervalMinutes: 15,
      );

      // The interval is the block's only numeric KPI, so it is the only metric
      // card; status is stated exactly once, by the header badge.
      expect(html, contains('card-metric--info'));
      expect(html, contains('metric-value t-metric">15</div>'));
      expect(html, contains('Interval (min)'));
      expect('card-metric--'.allMatches(html).length, 1);
      expect(html, contains('status-badge-success'));
      expect('status-badge-success'.allMatches(html).length, 1);
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
      expect(html, contains('No scheduled jobs'));
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

    test('scheduled-task delete carries the escaped title, not just the id', () {
      // The in-row confirmation names the task the way the Title column does, so
      // a hostile title must survive as attribute text rather than as markup.
      final html = schedulingTemplate(
        sidebarData: emptySidebar,
        navItems: emptyNavItems,
        scheduledTasks: [
          const ScheduledTaskDefinition(
            id: 'visual-review-seed',
            cronExpression: '0 9 * * *',
            title: 'Deploy "prod" <now> & wait',
            description: 'seed',
            type: TaskType.coding,
          ),
        ],
      );

      expect(html, contains('click->dc-scheduling#deleteScheduledTask'));
      expect(html, contains('data-task-id="visual-review-seed"'));
      // The quote and ampersand are escaped, so the title cannot break out of the
      // attribute; angle brackets need no escaping inside a quoted value.
      expect(html, contains('data-task-title="Deploy &quot;prod&quot; <now> &amp; wait"'));
      expect(html, isNot(contains('data-task-title="Deploy "prod"')));
    });

    test('the scheduled-task toggle carries its state in the glyph', () {
      // Both states painted a blank square while the icon name was hardcoded, so
      // the enabled/disabled reading lived entirely in an aria-label.
      String render({required bool enabled}) => schedulingTemplate(
        sidebarData: emptySidebar,
        navItems: emptyNavItems,
        scheduledTasks: [
          ScheduledTaskDefinition(
            id: 'weekly-report',
            cronExpression: '0 9 * * 1',
            title: 'Weekly report',
            description: 'seed',
            type: TaskType.coding,
            enabled: enabled,
          ),
        ],
      );

      final on = render(enabled: true);
      final off = render(enabled: false);
      expect(on, contains('data-icon="check"'));
      expect(on, contains('aria-label="Disable scheduled task"'));
      expect(off, contains('data-icon="circle-x"'));
      expect(off, contains('aria-label="Enable scheduled task"'));
      // The toggle no longer reserves a label-sized box, so it matches its
      // icon-only siblings instead of stretching to 5.5rem.
      expect(on, isNot(contains('scheduling-action-toggle" data-icon="check" ')));
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
