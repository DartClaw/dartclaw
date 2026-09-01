import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show TaskEvent, TaskEventKind;
import 'package:dartclaw_runtime/src/templates/loader.dart';
import 'package:dartclaw_runtime/src/templates/scheduling.dart';
import 'package:dartclaw_runtime/src/templates/sidebar.dart';
import 'package:dartclaw_runtime/src/templates/task_detail.dart';
import 'package:dartclaw_runtime/src/templates/task_timeline.dart';
import 'package:dartclaw_runtime/src/templates/tasks.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

/// The task surfaces compose the shared `pageHeader` and `emptyState` fragments
/// rather than reproducing their markup. What this protects is the failure mode
/// where a surface quietly grows a parallel empty state again: the page still
/// looks fine, but the next change to the shared treatment misses it.
void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  final SidebarData sidebar = (
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
  const navItems = <NavItem>[(label: 'Tasks', href: '/tasks', active: true, navGroup: 'system', icon: 'tasks')];

  // Rendered in setUp, not at load: the template loader is only initialised by
  // setUpAll above.
  late String taskList;
  late String taskDetail;
  late String scheduling;

  setUp(() {
    taskList = tasksPageTemplate(sidebarData: sidebar, navItems: navItems, tasks: const []);
    taskDetail = taskDetailPageTemplate(
      sidebarData: sidebar,
      navItems: navItems,
      task: {'id': 't1', 'title': 'A task', 'status': 'draft'},
      artifacts: const [],
    );
    scheduling = schedulingTemplate(sidebarData: sidebar, navItems: navItems, jobs: [], systemJobNames: []);
  });

  test('each full page emits exactly one pagehead, from the shared fragment', () {
    for (final entry in {'tasks': taskList, 'task detail': taskDetail, 'scheduling': scheduling}.entries) {
      expect(
        '<header class="pagehead">'.allMatches(entry.value).length,
        1,
        reason: '${entry.key} must compose exactly one shared page header',
      );
      expect(entry.value, contains('page-subtitle t-body'), reason: '${entry.key} lost its subtitle slot');
    }
  });

  test('the page templates carry no direct pagehead markup of their own', () async {
    final dir = await resolveTemplatesDir();
    for (final name in ['tasks', 'task_detail', 'scheduling']) {
      expect(File('$dir/$name.html').readAsStringSync(), isNot(contains('pagehead')), reason: '$name.html');
    }
  });

  test('the task-list page action is a verb+noun with an icon, not a "+" label', () {
    expect(taskList, contains('data-icon="plus"'));
    expect(taskList, contains('>New Task<'));
    expect(taskList, isNot(contains('>+ ')));
  });

  test('scheduling section actions follow the same label contract', () {
    expect(scheduling, contains('>Add Job<'));
    expect(scheduling, contains('>Add Task<'));
    expect(scheduling, isNot(contains('>+ ')));
  });

  group('every empty case composes the shared emptyState anatomy', () {
    void expectSharedEmptyState(String html, String title, {required String reason}) {
      expect(html, contains('class="empty-state"'), reason: reason);
      expect(html, contains('empty-state-title t-label'), reason: reason);
      expect(html, contains('>$title<'), reason: reason);
    }

    test('task list', () => expectSharedEmptyState(taskList, 'No tasks yet', reason: 'task list empty'));

    test('task detail session and artifacts', () {
      expectSharedEmptyState(taskDetail, 'Session not started', reason: 'no-session empty');
      expectSharedEmptyState(taskDetail, 'No artifacts yet', reason: 'no-artifacts empty');
      // Both sit on the card plane rather than floating on the page ground.
      expect(taskDetail, contains('class="card task-no-session"'));
    });

    test('both scheduling tables', () {
      expectSharedEmptyState(scheduling, 'No scheduled jobs', reason: 'jobs table empty');
      expectSharedEmptyState(scheduling, 'No scheduled tasks', reason: 'tasks table empty');
    });

    test('filtered timeline with no matches', () {
      final html = taskTimelineHtml(
        events: [
          TaskEvent(
            id: 'e1',
            taskId: 't1',
            timestamp: DateTime(2026, 3, 24),
            kind: TaskEventKind.toolCalled,
            details: const {'name': 'bash', 'success': true},
          ),
        ],
        taskId: 't1',
        taskStatus: 'running',
        activeFilter: 'errors',
      );
      expectSharedEmptyState(html, 'No matching events', reason: 'filtered timeline empty');
    });
  });
}
