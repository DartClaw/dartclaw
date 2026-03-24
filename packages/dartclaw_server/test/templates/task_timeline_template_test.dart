import 'package:dartclaw_core/dartclaw_core.dart'
    show TaskEvent, StatusChanged, ToolCalled, ArtifactCreated, PushBack, TokenUpdate, TaskErrorEvent;
import 'package:dartclaw_server/src/templates/loader.dart';
import 'package:dartclaw_server/src/templates/task_timeline.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

const _taskId = 'task-abc';
final _now = DateTime(2026, 3, 24, 10, 0, 0);

TaskEvent _statusEvent(String id, String newStatus) => TaskEvent(
  id: id,
  taskId: _taskId,
  timestamp: _now,
  kind: const StatusChanged(),
  details: {'newStatus': newStatus, 'oldStatus': 'draft'},
);

TaskEvent _toolEvent(String id, {bool success = true, String? errorType, String? context}) {
  final details = <String, dynamic>{'name': 'bash', 'success': success};
  if (errorType case final value?) {
    details['errorType'] = value;
  }
  if (context case final value?) {
    details['context'] = value;
  }
  return TaskEvent(id: id, taskId: _taskId, timestamp: _now, kind: const ToolCalled(), details: details);
}

TaskEvent _artifactEvent(String id) => TaskEvent(
  id: id,
  taskId: _taskId,
  timestamp: _now,
  kind: const ArtifactCreated(),
  details: {'name': 'output.md', 'kind': 'document'},
);

TaskEvent _pushBackEvent(String id, {String comment = 'Please fix the tests'}) =>
    TaskEvent(id: id, taskId: _taskId, timestamp: _now, kind: const PushBack(), details: {'comment': comment});

TaskEvent _tokenEvent(String id, {int input = 1000, int output = 500, int cacheRead = 0}) => TaskEvent(
  id: id,
  taskId: _taskId,
  timestamp: _now,
  kind: const TokenUpdate(),
  details: {'inputTokens': input, 'outputTokens': output, 'cacheReadTokens': cacheRead},
);

TaskEvent _errorEvent(String id, {String message = 'Something went wrong'}) =>
    TaskEvent(id: id, taskId: _taskId, timestamp: _now, kind: const TaskErrorEvent(), details: {'message': message});

void main() {
  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  group('taskTimelineHtml — filter bar', () {
    test('all filter is active when no filter param', () {
      final html = taskTimelineHtml(events: const [], taskId: _taskId, taskStatus: 'running');
      expect(html, contains('tl-filter-link active'));
      expect(html, contains('href="/tasks/$_taskId"'));
    });

    test('status filter is active when filter=status', () {
      final html = taskTimelineHtml(events: const [], taskId: _taskId, taskStatus: 'completed', activeFilter: 'status');
      // The active link href must be the status filter href.
      final activeIdx = html.indexOf('tl-filter-link active');
      expect(activeIdx, isNot(-1));
      // Find the href on the same link element (search forward for href).
      final hrefIdx = html.indexOf('href=', activeIdx);
      expect(hrefIdx, isNot(-1));
      final hrefSlice = html.substring(hrefIdx, hrefIdx + 60);
      expect(hrefSlice, contains('filter=status'));
    });

    test('filter bar contains all five filter hrefs', () {
      final html = taskTimelineHtml(events: const [], taskId: _taskId, taskStatus: 'draft');
      expect(html, contains('/tasks/$_taskId'));
      expect(html, contains('filter=status'));
      expect(html, contains('filter=tools'));
      expect(html, contains('filter=artifacts'));
      expect(html, contains('filter=errors'));
    });
  });

  group('taskTimelineHtml — empty state', () {
    test('shows empty state message when no events', () {
      final html = taskTimelineHtml(events: const [], taskId: _taskId, taskStatus: 'draft');
      expect(html, contains('No timeline events yet'));
    });

    test('empty state absent when events present', () {
      final html = taskTimelineHtml(events: [_statusEvent('e1', 'running')], taskId: _taskId, taskStatus: 'running');
      expect(html, isNot(contains('No timeline events yet')));
    });
  });

  group('taskTimelineHtml — auto-scroll', () {
    test('sets data-auto-scroll when task is running', () {
      final html = taskTimelineHtml(events: const [], taskId: _taskId, taskStatus: 'running');
      expect(html, contains('data-auto-scroll="true"'));
    });

    test('does not set data-auto-scroll for non-running status', () {
      for (final status in ['draft', 'completed', 'failed', 'review']) {
        final html = taskTimelineHtml(events: const [], taskId: _taskId, taskStatus: status);
        expect(html, isNot(contains('data-auto-scroll="true"')), reason: 'status=$status should not have auto-scroll');
      }
    });
  });

  group('taskTimelineHtml — StatusChanged event', () {
    test('renders status badge with correct class and label', () {
      final html = taskTimelineHtml(events: [_statusEvent('e1', 'running')], taskId: _taskId, taskStatus: 'running');
      expect(html, contains('status-badge'));
      expect(html, contains('status-badge-running'));
      expect(html, contains('Running'));
    });

    test('completed status uses circle-check icon', () {
      final html = taskTimelineHtml(
        events: [_statusEvent('e1', 'completed')],
        taskId: _taskId,
        taskStatus: 'completed',
      );
      expect(html, contains('icon-circle-check'));
    });

    test('failed status uses circle-x icon', () {
      final html = taskTimelineHtml(events: [_statusEvent('e1', 'failed')], taskId: _taskId, taskStatus: 'failed');
      expect(html, contains('icon-circle-x'));
    });
  });

  group('taskTimelineHtml — ToolCalled event', () {
    test('renders tool name as label', () {
      final html = taskTimelineHtml(events: [_toolEvent('e1')], taskId: _taskId, taskStatus: 'running');
      expect(html, contains('bash'));
      expect(html, contains('icon-wrench'));
      expect(html, contains('tl-event-tool'));
    });

    test('failed tool renders error class', () {
      final html = taskTimelineHtml(
        events: [_toolEvent('e1', success: false, errorType: 'PermissionDenied')],
        taskId: _taskId,
        taskStatus: 'running',
      );
      expect(html, contains('tl-event-error'));
      expect(html, contains('PermissionDenied'));
    });

    test('renders tool context in the label', () {
      final html = taskTimelineHtml(
        events: [_toolEvent('e1', context: 'src/auth/login.dart')],
        taskId: _taskId,
        taskStatus: 'running',
      );

      expect(html, contains('bash src/auth/login.dart'));
    });
  });

  group('taskTimelineHtml — ArtifactCreated event', () {
    test('renders artifact name and kind badge', () {
      final html = taskTimelineHtml(events: [_artifactEvent('e1')], taskId: _taskId, taskStatus: 'completed');
      expect(html, contains('output.md'));
      expect(html, contains('Document'));
      expect(html, contains('type-badge-document'));
      expect(html, contains('icon-file-text'));
      expect(html, contains('tl-event-artifact'));
    });
  });

  group('taskTimelineHtml — PushBack event', () {
    test('renders push-back label and comment detail', () {
      final html = taskTimelineHtml(events: [_pushBackEvent('e1')], taskId: _taskId, taskStatus: 'review');
      expect(html, contains('Push-back'));
      expect(html, contains('Please fix the tests'));
      expect(html, contains('icon-message-circle'));
      expect(html, contains('tl-event-pushback'));
    });
  });

  group('taskTimelineHtml — TokenUpdate event', () {
    test('renders formatted token counts', () {
      final html = taskTimelineHtml(
        events: [_tokenEvent('e1', input: 1000, output: 500)],
        taskId: _taskId,
        taskStatus: 'running',
      );
      expect(html, contains('1,000 in'));
      expect(html, contains('500 out'));
      expect(html, contains('icon-gauge'));
      expect(html, contains('tl-event-token'));
    });

    test('renders cache read detail when non-zero', () {
      final html = taskTimelineHtml(
        events: [_tokenEvent('e1', input: 1000, output: 500, cacheRead: 2500)],
        taskId: _taskId,
        taskStatus: 'running',
      );
      expect(html, contains('2,500 cache read'));
    });

    test('no cache detail when cache read is zero', () {
      final html = taskTimelineHtml(
        events: [_tokenEvent('e1', input: 1000, output: 500)],
        taskId: _taskId,
        taskStatus: 'running',
      );
      expect(html, isNot(contains('cache read')));
    });
  });

  group('taskTimelineHtml — TaskErrorEvent event', () {
    test('renders error label and message', () {
      final html = taskTimelineHtml(events: [_errorEvent('e1')], taskId: _taskId, taskStatus: 'failed');
      expect(html, contains('Error'));
      expect(html, contains('Something went wrong'));
      expect(html, contains('icon-triangle-alert'));
      expect(html, contains('tl-event-error'));
    });
  });

  group('taskTimelineHtml — filtering', () {
    final allEvents = [
      _statusEvent('e1', 'running'),
      _toolEvent('e2'),
      _artifactEvent('e3'),
      _pushBackEvent('e4'),
      _tokenEvent('e5'),
      _errorEvent('e6'),
    ];

    test('filter=tools shows only tool events', () {
      final html = taskTimelineHtml(events: allEvents, taskId: _taskId, taskStatus: 'running', activeFilter: 'tools');
      expect(html, contains('bash'));
      expect(html, isNot(contains('output.md')));
      expect(html, isNot(contains('Push-back')));
      expect(html, isNot(contains('tl-event-error')));
    });

    test('filter=artifacts shows only artifact events', () {
      final html = taskTimelineHtml(
        events: allEvents,
        taskId: _taskId,
        taskStatus: 'running',
        activeFilter: 'artifacts',
      );
      expect(html, contains('output.md'));
      expect(html, isNot(contains('bash')));
    });

    test('filter=errors shows only error events', () {
      final html = taskTimelineHtml(events: allEvents, taskId: _taskId, taskStatus: 'failed', activeFilter: 'errors');
      expect(html, contains('Something went wrong'));
      expect(html, isNot(contains('bash')));
      expect(html, isNot(contains('output.md')));
    });

    test('filter=status shows StatusChanged, PushBack, TokenUpdate', () {
      final html = taskTimelineHtml(events: allEvents, taskId: _taskId, taskStatus: 'running', activeFilter: 'status');
      expect(html, contains('status-badge-running'));
      expect(html, contains('Push-back'));
      expect(html, contains('1,000 in'));
      expect(html, isNot(contains('bash')));
      expect(html, isNot(contains('output.md')));
    });

    test('filter=all (or none) shows everything', () {
      final html = taskTimelineHtml(events: allEvents, taskId: _taskId, taskStatus: 'running');
      expect(html, contains('status-badge-running'));
      expect(html, contains('bash'));
      expect(html, contains('output.md'));
      expect(html, contains('Push-back'));
      expect(html, contains('1,000 in'));
      expect(html, contains('Something went wrong'));
    });
  });

  group('taskTimelineHtml — text truncation', () {
    test('long push-back comment is truncated', () {
      final long = 'a' * 200;
      final html = taskTimelineHtml(
        events: [_pushBackEvent('e1', comment: long)],
        taskId: _taskId,
        taskStatus: 'review',
      );
      // The rendered detail should not contain the full 200-char string.
      expect(html, isNot(contains('a' * 121)));
      expect(html, contains('\u2026')); // ellipsis character
    });
  });

  group('timelineEventItemHtml — single event fragment', () {
    test('renders a single tl-event div for a status event', () {
      final html = timelineEventItemHtml(_statusEvent('ev1', 'completed'));
      expect(html, contains('tl-event'));
      expect(html, contains('status-badge-completed'));
      expect(html, contains('data-event-id="ev1"'));
    });

    test('renders a tool event without the outer timeline wrapper', () {
      final html = timelineEventItemHtml(_toolEvent('ev2'));
      expect(html, contains('bash'));
      expect(html, isNot(contains('tl-filter-bar')));
      expect(html, isNot(contains('timeline-events')));
    });
  });

  group('eventMatchesFilter', () {
    test('null filter matches all kinds', () {
      expect(eventMatchesFilter(const StatusChanged(), null), isTrue);
      expect(eventMatchesFilter(const ToolCalled(), null), isTrue);
    });

    test('filter=all matches all kinds', () {
      expect(eventMatchesFilter(const ArtifactCreated(), 'all'), isTrue);
    });

    test('filter=tools only matches ToolCalled', () {
      expect(eventMatchesFilter(const ToolCalled(), 'tools'), isTrue);
      expect(eventMatchesFilter(const StatusChanged(), 'tools'), isFalse);
    });

    test('filter=artifacts only matches ArtifactCreated', () {
      expect(eventMatchesFilter(const ArtifactCreated(), 'artifacts'), isTrue);
      expect(eventMatchesFilter(const ToolCalled(), 'artifacts'), isFalse);
    });

    test('filter=errors only matches TaskErrorEvent', () {
      expect(eventMatchesFilter(const TaskErrorEvent(), 'errors'), isTrue);
      expect(eventMatchesFilter(const PushBack(), 'errors'), isFalse);
    });

    test('filter=status matches StatusChanged, PushBack, TokenUpdate', () {
      expect(eventMatchesFilter(const StatusChanged(), 'status'), isTrue);
      expect(eventMatchesFilter(const PushBack(), 'status'), isTrue);
      expect(eventMatchesFilter(const TokenUpdate(), 'status'), isTrue);
      expect(eventMatchesFilter(const ToolCalled(), 'status'), isFalse);
      expect(eventMatchesFilter(const ArtifactCreated(), 'status'), isFalse);
    });
  });
}
