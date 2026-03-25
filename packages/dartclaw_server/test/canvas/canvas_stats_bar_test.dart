import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/observability/usage_tracker.dart';
import 'package:dartclaw_server/src/templates/canvas_stats_bar.dart';
import 'package:dartclaw_server/src/templates/loader.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

void main() {
  setUpAll(() => initTemplates(resolveTemplatesDir()));
  tearDownAll(() => resetTemplates());

  group('canvasStatsBarFragment', () {
    test('renders budget usage label and percentage', () async {
      final usage = _FakeUsageTracker(summary: {'total_input_tokens': 300, 'total_output_tokens': 200});
      final html = await canvasStatsBarFragment(
        tasks: const [],
        usageTracker: usage,
        dailyBudgetTokens: 1000,
        serverStartTime: DateTime.now(),
      );

      expect(html, contains('500 / 1,000 tokens (50%)'));
      expect(html, contains('canvas-budget-yellow'));
    });

    test('uses green, yellow, red thresholds', () async {
      final green = await canvasStatsBarFragment(
        tasks: const [],
        usageTracker: _FakeUsageTracker(summary: {'total_input_tokens': 400, 'total_output_tokens': 0}),
        dailyBudgetTokens: 1000,
        serverStartTime: DateTime.now(),
      );
      final yellow = await canvasStatsBarFragment(
        tasks: const [],
        usageTracker: _FakeUsageTracker(summary: {'total_input_tokens': 750, 'total_output_tokens': 0}),
        dailyBudgetTokens: 1000,
        serverStartTime: DateTime.now(),
      );
      final red = await canvasStatsBarFragment(
        tasks: const [],
        usageTracker: _FakeUsageTracker(summary: {'total_input_tokens': 950, 'total_output_tokens': 0}),
        dailyBudgetTokens: 1000,
        serverStartTime: DateTime.now(),
      );

      expect(green, contains('canvas-budget-green'));
      expect(yellow, contains('canvas-budget-yellow'));
      expect(red, contains('canvas-budget-red'));
    });

    test('handles null usage summary gracefully', () async {
      final html = await canvasStatsBarFragment(
        tasks: const [],
        usageTracker: _FakeUsageTracker(summary: null),
        dailyBudgetTokens: 1000,
        serverStartTime: DateTime.now(),
      );

      expect(html, contains('0 / 1,000 tokens (0%)'));
      expect(html, contains('canvas-budget-green'));
    });

    test('renders disabled budget state when daily budget is zero', () async {
      final html = await canvasStatsBarFragment(
        tasks: const [],
        usageTracker: _FakeUsageTracker(summary: {'total_input_tokens': 200, 'total_output_tokens': 100}),
        dailyBudgetTokens: 0,
        serverStartTime: DateTime.now(),
      );

      expect(html, contains('Budget disabled'));
      expect(html, contains('canvas-budget-disabled'));
    });

    test('renders completed running and queued counters', () async {
      final now = DateTime.now();
      final html = await canvasStatsBarFragment(
        tasks: [
          _task(id: 'queued', title: 'Queued', status: TaskStatus.queued, createdAt: now),
          _task(id: 'running', title: 'Running', status: TaskStatus.running, createdAt: now),
          _task(id: 'accepted', title: 'Accepted', status: TaskStatus.accepted, createdAt: now),
          _task(id: 'failed', title: 'Failed', status: TaskStatus.failed, createdAt: now),
        ],
        usageTracker: _FakeUsageTracker(summary: null),
        dailyBudgetTokens: 1000,
        serverStartTime: now,
      );

      expect(html, contains('Done'));
      expect(html, contains('Running'));
      expect(html, contains('Queued'));
      expect(html, contains('2'));
      expect(html, contains('1'));
    });

    test('sorts leaderboard by count and uses System fallback', () async {
      final now = DateTime.now();
      final html = await canvasStatsBarFragment(
        tasks: [
          _task(id: 'a1', title: 'A1', status: TaskStatus.queued, createdAt: now, createdBy: 'Alice'),
          _task(id: 'a2', title: 'A2', status: TaskStatus.queued, createdAt: now, createdBy: 'Alice'),
          _task(id: 's1', title: 'S1', status: TaskStatus.queued, createdAt: now, createdBy: null),
          _task(id: 'b1', title: 'B1', status: TaskStatus.queued, createdAt: now, createdBy: 'Bob'),
        ],
        usageTracker: _FakeUsageTracker(summary: null),
        dailyBudgetTokens: 1000,
        serverStartTime: now,
      );

      final aliceIndex = html.indexOf('Alice');
      final bobIndex = html.indexOf('Bob');
      final systemIndex = html.indexOf('System');

      expect(aliceIndex, greaterThanOrEqualTo(0));
      expect(bobIndex, greaterThanOrEqualTo(0));
      expect(systemIndex, greaterThanOrEqualTo(0));
      expect(aliceIndex < bobIndex, isTrue);
      expect(aliceIndex < systemIndex, isTrue);
    });

    test('renders elapsed time and data-start-time attribute', () async {
      final start = DateTime.now().subtract(const Duration(hours: 1, minutes: 5));
      final html = await canvasStatsBarFragment(
        tasks: const [],
        usageTracker: _FakeUsageTracker(summary: null),
        dailyBudgetTokens: 1000,
        serverStartTime: start,
      );

      expect(html, contains('data-start-time='));
      expect(html, contains('1h 5m'));
    });
  });
}

class _FakeUsageTracker extends UsageTracker {
  final Map<String, dynamic>? summary;

  _FakeUsageTracker({required this.summary}) : super(dataDir: '/tmp');

  @override
  Future<Map<String, dynamic>?> dailySummary() async => summary;
}

Task _task({
  required String id,
  required String title,
  required TaskStatus status,
  required DateTime createdAt,
  String? createdBy = 'Alice',
}) {
  return Task(
    id: id,
    title: title,
    description: title,
    type: TaskType.research,
    status: status,
    createdAt: createdAt,
    createdBy: createdBy,
  );
}
