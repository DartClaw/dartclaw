import 'package:dartclaw_core/dartclaw_core.dart' show TaskEvent, TaskEventKind;
import 'package:dartclaw_runtime/src/templates/loader.dart';
import 'package:dartclaw_runtime/src/templates/task_timeline.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

const _taskId = 'task-abc';
final _now = DateTime(2026, 3, 24, 10, 0, 0);

TaskEvent _statusEvent(String id, String newStatus) => TaskEvent(
  id: id,
  taskId: _taskId,
  timestamp: _now,
  kind: TaskEventKind.statusChanged,
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
  return TaskEvent(id: id, taskId: _taskId, timestamp: _now, kind: TaskEventKind.toolCalled, details: details);
}

TaskEvent _artifactEvent(String id) => TaskEvent(
  id: id,
  taskId: _taskId,
  timestamp: _now,
  kind: TaskEventKind.artifactCreated,
  details: {'name': 'output.md', 'kind': 'document'},
);

TaskEvent _pushBackEvent(String id, {String comment = 'Please fix the tests'}) =>
    TaskEvent(id: id, taskId: _taskId, timestamp: _now, kind: TaskEventKind.pushBack, details: {'comment': comment});

TaskEvent _tokenEvent(String id, {int input = 1000, int output = 500, int cacheRead = 0}) => TaskEvent(
  id: id,
  taskId: _taskId,
  timestamp: _now,
  kind: TaskEventKind.tokenUpdate,
  details: {'inputTokens': input, 'outputTokens': output, 'cacheReadTokens': cacheRead},
);

TaskEvent _errorEvent(String id, {String message = 'Something went wrong'}) =>
    TaskEvent(id: id, taskId: _taskId, timestamp: _now, kind: TaskEventKind.taskError, details: {'message': message});

TaskEvent _structuredOutputFailureEvent(String id, TaskEventKind kind, {String? outputKey, String? failureReason}) {
  final details = <String, dynamic>{};
  if (outputKey case final value?) {
    details['outputKey'] = value;
  }
  if (failureReason case final value?) {
    details['failureReason'] = value;
  }
  return TaskEvent(id: id, taskId: _taskId, timestamp: _now, kind: kind, details: details);
}

void main() {
  setUpAll(() async => initTemplates(await resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  group('taskTimelineHtml — filter chips', () {
    test('all filter is pressed when no filter param', () {
      final html = taskTimelineHtml(events: [_toolEvent('e1')], taskId: _taskId, taskStatus: 'running');
      final firstChip = html.indexOf('<button');
      expect(firstChip, isNot(-1));
      expect(html.substring(firstChip, firstChip + 200), contains('aria-pressed="true"'));
      expect(html, contains('hx-get="/tasks/$_taskId"'));
    });

    test('status filter is pressed when filter=status', () {
      final html = taskTimelineHtml(
        events: [_statusEvent('e1', 'running')],
        taskId: _taskId,
        taskStatus: 'completed',
        activeFilter: 'status',
      );
      // Exactly one chip is pressed, and it is the one targeting filter=status.
      expect('aria-pressed="true"'.allMatches(html).length, 1);
      final pressedIdx = html.indexOf('aria-pressed="true"');
      expect(html.substring(pressedIdx, pressedIdx + 80), contains('filter=status'));
    });

    test('chip row offers all five buckets', () {
      final html = taskTimelineHtml(events: [_toolEvent('e1')], taskId: _taskId, taskStatus: 'draft');
      expect(html, contains('chip-row'));
      expect('<button'.allMatches(html).length, 5);
      expect(html, contains('/tasks/$_taskId'));
      for (final filter in ['status', 'tools', 'artifacts', 'errors']) {
        expect(html, contains('filter=$filter'));
      }
    });

    test('counts come from the unfiltered list, not the active filter', () {
      // Three tools, two status. Under filter=tools the other buckets must still
      // report what they hold, or the chips stop being a way back.
      final events = [
        _toolEvent('t1'),
        _toolEvent('t2'),
        _toolEvent('t3'),
        _statusEvent('s1', 'running'),
        _statusEvent('s2', 'review'),
      ];
      final html = taskTimelineHtml(events: events, taskId: _taskId, taskStatus: 'running', activeFilter: 'tools');
      final counts = RegExp(r'chip-meta">(\d+)<').allMatches(html).map((m) => m.group(1)).toList();
      // Order is All, Status, Tools, Artifacts, Errors.
      expect(counts, ['5', '2', '3', '0', '0']);
    });
  });

  group('taskTimelineHtml — empty cases', () {
    test('a task with no events at all emits no timeline panel', () {
      // The caller keys `hasTimeline` off this being empty, so the whole panel —
      // chips included — is suppressed rather than rendered around nothing.
      final html = taskTimelineHtml(events: const [], taskId: _taskId, taskStatus: 'draft');
      expect(html, isEmpty);
    });

    test('a filter matching nothing still renders the panel and its chips', () {
      // Suppressing here would strand the operator on a URL they must hand-edit,
      // because the chip row is the only control that returns them to All.
      final html = taskTimelineHtml(
        events: [_toolEvent('e1')],
        taskId: _taskId,
        taskStatus: 'running',
        activeFilter: 'errors',
      );
      expect(html, contains('chip-row'));
      expect(html, contains('task-timeline'));
      expect(html, contains('No matching events'));
      expect(html, contains('empty-state-title'));
    });

    test('empty state absent when the active filter matches', () {
      final html = taskTimelineHtml(events: [_statusEvent('e1', 'running')], taskId: _taskId, taskStatus: 'running');
      expect(html, isNot(contains('No matching events')));
    });
  });

  group('taskTimelineHtml — auto-scroll', () {
    test('sets data-auto-scroll when task is running', () {
      final html = taskTimelineHtml(events: [_toolEvent('e1')], taskId: _taskId, taskStatus: 'running');
      expect(html, contains('data-auto-scroll="true"'));
    });

    test('does not set data-auto-scroll for non-running status', () {
      for (final status in ['draft', 'completed', 'failed', 'review']) {
        final html = taskTimelineHtml(events: [_toolEvent('e1')], taskId: _taskId, taskStatus: status);
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

  group('taskTimelineHtml — structured output failures', () {
    test('fallback includes the output key and failure reason', () {
      final html = taskTimelineHtml(
        events: [
          _structuredOutputFailureEvent(
            'e1',
            TaskEventKind.structuredOutputFallbackUsed,
            outputKey: 'review',
            failureReason: 'invalid JSON',
          ),
        ],
        taskId: _taskId,
        taskStatus: 'completed',
      );

      expect(html, contains('review (invalid JSON)'));
    });

    test('validation failure includes the output key without an absent reason', () {
      final html = taskTimelineHtml(
        events: [
          _structuredOutputFailureEvent('e1', TaskEventKind.structuredOutputValidationFailed, outputKey: 'result'),
        ],
        taskId: _taskId,
        taskStatus: 'failed',
      );

      expect(html, contains('result'));
      expect(html, isNot(contains('result (')));
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
      expect(eventMatchesFilter(TaskEventKind.statusChanged, null), isTrue);
      expect(eventMatchesFilter(TaskEventKind.toolCalled, null), isTrue);
    });

    test('filter=all matches all kinds', () {
      expect(eventMatchesFilter(TaskEventKind.artifactCreated, 'all'), isTrue);
    });

    test('filter=tools only matches toolCalled', () {
      expect(eventMatchesFilter(TaskEventKind.toolCalled, 'tools'), isTrue);
      expect(eventMatchesFilter(TaskEventKind.statusChanged, 'tools'), isFalse);
    });

    test('filter=artifacts only matches artifactCreated', () {
      expect(eventMatchesFilter(TaskEventKind.artifactCreated, 'artifacts'), isTrue);
      expect(eventMatchesFilter(TaskEventKind.toolCalled, 'artifacts'), isFalse);
    });

    test('filter=errors only matches taskError', () {
      expect(eventMatchesFilter(TaskEventKind.taskError, 'errors'), isTrue);
      expect(eventMatchesFilter(TaskEventKind.pushBack, 'errors'), isFalse);
    });

    test('filter=status matches statusChanged, pushBack, tokenUpdate', () {
      expect(eventMatchesFilter(TaskEventKind.statusChanged, 'status'), isTrue);
      expect(eventMatchesFilter(TaskEventKind.pushBack, 'status'), isTrue);
      expect(eventMatchesFilter(TaskEventKind.tokenUpdate, 'status'), isTrue);
      expect(eventMatchesFilter(TaskEventKind.toolCalled, 'status'), isFalse);
      expect(eventMatchesFilter(TaskEventKind.artifactCreated, 'status'), isFalse);
    });
  });
}
