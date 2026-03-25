import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/templates/canvas_task_board.dart';
import 'package:dartclaw_server/src/templates/loader.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  group('canvasTaskBoardFragment', () {
    test('renders empty board state', () {
      final html = canvasTaskBoardFragment(const []);

      expect(html, contains('canvas-task-board'));
      expect(html, contains('Queued'));
      expect(html, contains('Running'));
      expect(html, contains('Review'));
      expect(html, contains('Done'));
      expect(html, contains('No tasks yet'));
    });

    test('groups tasks into queued, running, review, done columns', () {
      final now = DateTime.now();
      final html = canvasTaskBoardFragment([
        _task(id: 't-queued', title: 'Queued', status: TaskStatus.queued, createdAt: now),
        _task(id: 't-running', title: 'Running', status: TaskStatus.running, createdAt: now, startedAt: now),
        _task(id: 't-review', title: 'Review', status: TaskStatus.review, createdAt: now, startedAt: now),
        _task(id: 't-accepted', title: 'Accepted', status: TaskStatus.accepted, createdAt: now, completedAt: now),
      ]);

      expect(html, contains('Queued'));
      expect(html, contains('Running'));
      expect(html, contains('Review'));
      expect(html, contains('Done'));
      expect(html, contains('Queued'));
      expect(html, contains('Running'));
      expect(html, contains('Review'));
      expect(html, contains('Accepted'));
    });

    test('truncates long task titles to 40 characters', () {
      const longTitle = '12345678901234567890123456789012345678901';
      final html = canvasTaskBoardFragment([
        _task(id: 't-long', title: longTitle, status: TaskStatus.queued, createdAt: DateTime.now()),
      ]);

      final hasAsciiEllipsis = html.contains('123456789012345678901234567890123456789...');
      final hasUnicodeEllipsis = html.contains('123456789012345678901234567890123456789…');
      expect(hasAsciiEllipsis || hasUnicodeEllipsis, isTrue);
    });

    test('uses System fallback when createdBy is null or blank', () {
      final html = canvasTaskBoardFragment([
        _task(
          id: 't-null',
          title: 'Null creator',
          status: TaskStatus.queued,
          createdAt: DateTime.now(),
          createdBy: null,
        ),
        _task(
          id: 't-blank',
          title: 'Blank creator',
          status: TaskStatus.queued,
          createdAt: DateTime.now(),
          createdBy: '   ',
        ),
      ]);

      expect(html, contains('System'));
    });

    test('renders relative time-in-state for cards', () {
      final now = DateTime.now();
      final html = canvasTaskBoardFragment([
        _task(
          id: 't-time',
          title: 'Time card',
          status: TaskStatus.running,
          createdAt: now.subtract(const Duration(minutes: 20)),
          startedAt: now.subtract(const Duration(minutes: 2)),
        ),
      ]);

      expect(RegExp(r'\d+m ago').hasMatch(html), isTrue);
    });

    test('done column merges terminal states and renders status icons', () {
      final now = DateTime.now();
      final html = canvasTaskBoardFragment([
        _task(id: 't-accepted', title: 'Accepted', status: TaskStatus.accepted, createdAt: now, completedAt: now),
        _task(id: 't-rejected', title: 'Rejected', status: TaskStatus.rejected, createdAt: now, completedAt: now),
        _task(id: 't-cancelled', title: 'Cancelled', status: TaskStatus.cancelled, createdAt: now, completedAt: now),
        _task(id: 't-failed', title: 'Failed', status: TaskStatus.failed, createdAt: now, completedAt: now),
      ]);

      expect(html, contains('Accepted'));
      expect(html, contains('Rejected'));
      expect(html, contains('Cancelled'));
      expect(html, contains('Failed'));
      expect(html, contains('OK'));
      expect(html, contains('NO'));
      expect(html, contains('X'));
      expect(html, contains('!'));
    });
  });
}

Task _task({
  required String id,
  required String title,
  required TaskStatus status,
  required DateTime createdAt,
  DateTime? startedAt,
  DateTime? completedAt,
  String? createdBy = 'Alice',
}) {
  return Task(
    id: id,
    title: title,
    description: title,
    type: TaskType.research,
    status: status,
    createdAt: createdAt,
    startedAt: startedAt,
    completedAt: completedAt,
    createdBy: createdBy,
  );
}
