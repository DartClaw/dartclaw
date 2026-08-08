import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' show TaskStatus;
import 'package:dartclaw_server/src/templates/loader.dart';
import 'package:dartclaw_server/src/templates/sidebar.dart';
import 'package:dartclaw_server/src/templates/task_detail.dart';
import 'package:dartclaw_server/src/templates/task_status_display.dart';
import 'package:dartclaw_server/src/templates/tasks.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

/// One presentation table drives both task consumers. What these tests protect
/// is that a status cannot read one way in the list and another on the detail
/// page, and that a status the server does not recognise is reported as unknown
/// rather than silently presented as a draft — which would offer a Start button
/// for a task nobody can start.
void main() {
  setUpAll(() => initTemplates(resolveTemplatesDir()));
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

  // The full contract, restated here so a change to the map has to be a
  // deliberate change to this table too.
  const expected = <String, (String label, String pill, String dot)>{
    'draft': ('Draft', 'info', 'idle'),
    'queued': ('Queued', 'info', 'attention'),
    'running': ('Running', 'live', 'live'),
    'interrupted': ('Interrupted', 'warning', 'warning'),
    'review': ('Review', 'warning', 'attention'),
    'accepted': ('Accepted', 'live', 'success'),
    'rejected': ('Rejected', 'error', 'error'),
    'cancelled': ('Cancelled', 'error', 'error'),
    'failed': ('Failed', 'error', 'error'),
  };

  test('every TaskStatus resolves to its exact label, pill and dot', () {
    expect(TaskStatus.values.length, expected.length, reason: 'a lifecycle status was added without a presentation');
    for (final status in TaskStatus.values) {
      final row = expected[status.name];
      expect(row, isNotNull, reason: '${status.name} has no entry in the contract table');
      final actual = taskStatusPresentation(status.name);
      expect((actual.label, actual.pill, actual.dot), row, reason: 'presentation drift for ${status.name}');
    }
  });

  test('unknown, null and empty inputs all report Unknown rather than Draft', () {
    for (final input in <Object?>['no-such-status', null, '']) {
      final actual = taskStatusPresentation(input);
      expect((actual.label, actual.pill, actual.dot), ('Unknown', 'info', 'idle'), reason: 'input=$input');
      expect(taskStatusKey(input), 'unknown');
    }
  });

  test('every emitted pill and dot suffix resolves to a rule in served canon', () {
    final base = File('packages/dartclaw_server/lib/src/static/design-system.css').existsSync()
        ? 'packages/dartclaw_server/lib/src/static'
        : 'lib/src/static';
    final canon = File('$base/design-system.css').readAsStringSync();
    for (final p in taskStatusPresentations.values) {
      expect(canon, contains('.status-pill--${p.pill}'), reason: 'pill variant ${p.pill} is emitted but undefined');
      expect(canon, contains('.status-dot--${p.dot}'), reason: 'dot variant ${p.dot} is emitted but undefined');
    }
  });

  test('presentation is chosen in one place, with no wildcard bypass', () {
    final source = File(
      File('packages/dartclaw_server/lib/src/templates/task_status_display.dart').existsSync()
          ? 'packages/dartclaw_server/lib/src/templates/task_status_display.dart'
          : 'lib/src/templates/task_status_display.dart',
    ).readAsStringSync();
    // Nine states plus the explicit unknown entry — no `_ =>` catch-all deciding
    // presentation behind the table's back.
    expect(RegExp(r"^\s+'[a-z]+':", multiLine: true).allMatches(source).length, expected.length + 1);
    expect(source, isNot(contains('_ =>')));
  });

  group('both consumers render the same presentation', () {
    Map<String, dynamic> task(Map<String, dynamic> overrides) => {
      'id': 't1',
      'title': 'A task',
      'type': 'coding',
      'createdAt': '2026-03-10T10:00:00Z',
      ...overrides,
    };

    test('an accepted task reads Accepted in the list and on the detail page', () {
      final list = tasksPageTemplate(
        sidebarData: sidebar,
        navItems: navItems,
        tasks: [
          task({'status': 'accepted'}),
        ],
      );
      final detail = taskDetailPageTemplate(
        sidebarData: sidebar,
        navItems: navItems,
        task: task({'status': 'accepted'}),
        artifacts: const [],
      );
      expect(list, contains('status-pill--live'));
      expect(list, contains('Accepted'));
      expect(detail, contains('Accepted'));
      expect(detail, contains('status-dot--success'));
    });

    for (final malformed in <(String name, Map<String, dynamic> overrides)>[
      ('null status', {'status': null}),
      ('absent status key', {}),
      ('empty status', {'status': ''}),
      ('unrecognised status', {'status': 'wat'}),
    ]) {
      test('${malformed.$1} shows Unknown at both consumers, never Draft', () {
        final list = tasksPageTemplate(sidebarData: sidebar, navItems: navItems, tasks: [task(malformed.$2)]);
        final detail = taskDetailPageTemplate(
          sidebarData: sidebar,
          navItems: navItems,
          task: task(malformed.$2),
          artifacts: const [],
        );
        // Scoped to the rendered status, not the whole page: the filter dropdown
        // legitimately offers a "Draft" option on every task list.
        final table = list.substring(
          list.indexOf('task-status-group'),
          list.indexOf('</table>', list.indexOf('task-status-group')),
        );
        expect(table, contains('>Unknown<'));
        expect(table, isNot(contains('>Draft<')));
        // Draft and Unknown share a pill and a dot, so the badge variant is what
        // actually distinguishes "we do not recognise this" from "it is a draft".
        expect(detail, contains('status-badge-unknown'));
        expect(detail, isNot(contains('status-badge-draft')));
        // A draft would offer this control; an unknown status must not.
        expect(detail, isNot(contains('data-task-start')));
      });
    }
  });
}
