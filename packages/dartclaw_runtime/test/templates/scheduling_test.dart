import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/scheduling/scheduled_task_runner.dart';
import 'package:dartclaw_runtime/src/task/task_service.dart';
import 'package:dartclaw_runtime/src/templates/loader.dart';
import 'package:dartclaw_runtime/src/templates/scheduling.dart';
import 'package:dartclaw_runtime/src/templates/sidebar.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
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

    // A job reporting itself as running keeps its row and its run control, disabled:
    // hiding the row would read as "the job is gone" rather than "it is busy".
    test('keeps a running job visible but not startable', () {
      final html = schedulingTemplate(
        sidebarData: emptySidebar,
        navItems: emptyNavItems,
        jobs: [
          {
            'name': 'memory-curation',
            'schedule': '0 3 * * *',
            'delivery': 'none',
            'status': 'running',
            'runnable': true,
          },
        ],
        systemJobNames: ['memory-curation'],
      );

      expect(html, contains('status-dot--live'));
      expect(html, contains('>running</span>'));
      expect(html, contains('title="Already running" aria-label="Already running"'));
      expect(html, contains('disabled="" aria-disabled="true"'));
      expect(html, isNot(contains('click->dc-scheduling#runJob')));
      expect(html, isNot(contains('click->dc-scheduling#editJob')));
      expect(html, isNot(contains('click->dc-scheduling#confirmDeleteJob')));
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
      expect(html, contains('hx-get="/scheduling/jobs/my-cron/form"'));
      expect(html, contains('data-action="click->dc-scheduling#confirmDelete"'));
      expect(html, contains('hx-post="/scheduling/jobs/my-cron/run"'));
      expect('aria-label="Enable heartbeat"'.allMatches(html), hasLength(1));
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

    test('prompt system jobs can run without edit or delete actions', () {
      final html = schedulingTemplate(
        sidebarData: emptySidebar,
        navItems: emptyNavItems,
        jobs: [
          {
            'name': 'memory-journal',
            'schedule': '0 22 * * *',
            'delivery': 'none',
            'status': 'active',
            'runnable': true,
          },
          {'name': 'memory-pruner', 'schedule': '0 3 * * *', 'delivery': 'none', 'status': 'active'},
        ],
        systemJobNames: ['memory-journal', 'memory-pruner'],
      );

      expect('hx-post="/scheduling/jobs/memory-journal/run"'.allMatches(html), hasLength(1));
      expect(html, contains('title="Run now" aria-label="Run now" data-icon="play"'));
      expect(html, isNot(contains('/scheduling/jobs/memory-journal/form')));
      expect(html, isNot(contains('/scheduling/jobs/memory-journal/delete')));
      expect(html, isNot(contains('/scheduling/jobs/memory-pruner/run')));
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

    test('S01 table fragments are independently rooted and composed verbatim into the page', () {
      final jobs = <Map<String, dynamic>>[
        {'name': 'digest', 'schedule': '0 7 * * *', 'delivery': 'announce'},
      ];
      final tasks = [
        const ScheduledTaskDefinition(
          id: 'weekly-report',
          cronExpression: '0 9 * * 1',
          title: 'Weekly report',
          description: 'Summarise the week',
        ),
      ];
      final jobsFragment = schedulingJobsFragment(jobs: jobs, systemJobNames: const [], loadedJobIds: const {'digest'});
      final loadedTaskIds = {ScheduledTaskRunner.jobIdForDefinition('weekly-report')};
      final tasksFragment = schedulingTasksFragment(tasks: tasks, loadedJobIds: loadedTaskIds);
      final page = schedulingTemplate(
        sidebarData: emptySidebar,
        navItems: emptyNavItems,
        jobs: jobs,
        scheduledTasks: tasks,
        loadedJobIds: {'digest', ...loadedTaskIds},
      );

      expect(jobsFragment, startsWith('<div id="scheduling-jobs-table"'));
      expect(tasksFragment, startsWith('<div id="scheduling-tasks-table"'));
      expect(page, contains(jobsFragment));
      expect(page, contains(tasksFragment));
    });

    test('loaded scheduled tasks use the runner job ID while config-only tasks require restart', () {
      const loaded = ScheduledTaskDefinition(
        id: 'weekly-report',
        cronExpression: '0 9 * * 1',
        title: 'Weekly report',
        description: 'Summarise the week',
      );
      const configOnly = ScheduledTaskDefinition(
        id: 'monthly-report',
        cronExpression: '0 9 1 * *',
        title: 'Monthly report',
        description: 'Summarise the month',
      );
      final runner = ScheduledTaskRunner(
        taskService: TaskService(InMemoryTaskRepository()),
        definitions: const [loaded],
      );
      final loadedJobIds = runner.buildJobs().map((job) => job.id).toSet();

      final loadedHtml = schedulingTasksFragment(tasks: const [loaded], loadedJobIds: loadedJobIds);
      final configOnlyHtml = schedulingTasksFragment(tasks: const [configOnly], loadedJobIds: loadedJobIds);

      expect(loadedHtml, isNot(contains('Restart to run')));
      expect(configOnlyHtml, contains('Restart to run'));
    });

    test('forms use hidden attributes and canonical metric cards', () {
      final html = schedulingTemplate(sidebarData: emptySidebar, navItems: emptyNavItems, jobs: [], systemJobNames: []);
      expect(html, contains('job-form'));
      expect(html, contains('class="well-content" id="job-form" hidden=""'));
      expect(html, contains('class="well-content" id="task-form" hidden=""'));
      expect(html, isNot(contains('style=')));
      expect(html, contains('hx-get="/scheduling/jobs/form"'));
      // A disabled heartbeat has no interval to report, so the block shows only
      // its status badge. Nothing non-numeric reaches the 32px metric tier.
      expect(html, isNot(contains('card-metric')));
      expect(html, isNot(contains('metric-value')));
      expect(html, contains('status-badge-muted'));
      expect(html, contains('Disabled'));
      final controls =
          '${schedulingJobFormFragment(values: emptyJobFormValues)}'
          '${schedulingTaskFormFragment(values: emptyTaskFormValues)}';
      expect(RegExp(r'type="radio"[^>]*class="form-radio"').allMatches(controls), hasLength(3));
      expect(controls, contains('role="radiogroup" aria-labelledby="job-delivery-label"'));
      expect(
        RegExp(r'<label class="form-field form-field--checkbox"><input type="radio"').allMatches(controls),
        hasLength(3),
      );
      expect(controls, contains('<input type="checkbox" class="form-checkbox" id="task-enabled"'));
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
      final html = schedulingJobFormFragment(values: emptyJobFormValues);
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
          {'name': 'my-cron', 'schedule': '17 3 * * 1', 'delivery': 'announce', 'status': 'active'},
          {
            'type': 'task',
            'schedule': '0 9 * * *',
            'task': {'title': 'nightly digest'},
          },
        ],
        systemJobNames: [],
      );
      expect(html, contains('my-cron'));
      // The raw cron expression, not only its humanised form, reaches the
      // schedule column — an operator edits the expression, not the prose. The
      // value is deliberately unlike the form's placeholder cron, which would
      // otherwise satisfy this on its own.
      expect(html, contains('<span class="cron-expr">17 3 * * 1</span>'));
      // Exactly one actionable row — the prompt job — proving the task entry
      // added no second (phantom) row.
      expect('hx-get="/scheduling/jobs/my-cron/form"'.allMatches(html).length, 1);
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
          ),
        ],
      );

      expect(html, contains('click->dc-scheduling#confirmDelete'));
      expect(html, contains('data-delete-url="/scheduling/tasks/visual-review-seed/delete"'));
      // The quote and ampersand are escaped, so the title cannot break out of the
      // attribute; angle brackets need no escaping inside a quoted value.
      expect(
        html,
        contains('data-delete-message="Delete scheduled task \'Deploy &quot;prod&quot; <now> &amp; wait\'?"'),
      );
      expect(html, isNot(contains('data-delete-message="Delete scheduled task \'Deploy "prod"')));
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
