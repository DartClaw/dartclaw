import 'package:dartclaw_core/dartclaw_core.dart';

import '../observability/usage_tracker.dart';
import 'helpers.dart';
import 'loader.dart';

/// Renders the workshop stats-bar fragment for the canvas view.
Future<String> canvasStatsBarFragment({
  required List<Task> tasks,
  required UsageTracker usageTracker,
  required int dailyBudgetTokens,
  required DateTime serverStartTime,
}) async {
  final summary = await usageTracker.dailySummary();
  final input = _asInt(summary?['total_input_tokens']);
  final output = _asInt(summary?['total_output_tokens']);
  final usedTokens = input + output;

  final hasBudget = dailyBudgetTokens > 0;
  final budgetPercent = hasBudget ? ((usedTokens / dailyBudgetTokens) * 100).round().clamp(0, 100) : 0;
  final budgetClass = hasBudget ? _budgetClass(budgetPercent) : 'canvas-budget-disabled';
  final budgetLabel = hasBudget
      ? '${formatNumber(usedTokens)} / ${formatNumber(dailyBudgetTokens)} tokens (${budgetPercent.toInt()}%)'
      : 'Budget disabled';

  final completedCount = tasks.where((task) => task.status.terminal).length;
  final runningCount = tasks.where((task) => task.status == TaskStatus.running).length;
  final queuedCount = tasks.where((task) => task.status == TaskStatus.queued).length;
  final contributors = _topContributors(tasks);

  final elapsedSeconds = DateTime.now().difference(serverStartTime).inSeconds;
  final elapsedLabel = formatUptime(elapsedSeconds < 0 ? 0 : elapsedSeconds);

  return templateLoader.trellis.renderFragment(
    templateLoader.source('canvas_stats_bar'),
    fragment: 'statsBar',
    context: {
      'budgetClass': budgetClass,
      'budgetPercent': budgetPercent,
      'budgetLabel': budgetLabel,
      'completedCount': completedCount,
      'runningCount': runningCount,
      'queuedCount': queuedCount,
      'contributors': contributors,
      'hasContributors': contributors.isNotEmpty,
      'sessionStartIso': serverStartTime.toIso8601String(),
      'elapsedLabel': elapsedLabel,
    },
  );
}

int _asInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return 0;
}

String _budgetClass(int percent) {
  if (percent < 50) return 'canvas-budget-green';
  if (percent <= 80) return 'canvas-budget-yellow';
  return 'canvas-budget-red';
}

List<Map<String, dynamic>> _topContributors(List<Task> tasks) {
  final counts = <String, int>{};
  for (final task in tasks) {
    final contributor = (task.createdBy?.trim().isNotEmpty ?? false) ? task.createdBy!.trim() : 'System';
    counts.update(contributor, (value) => value + 1, ifAbsent: () => 1);
  }

  final entries = counts.entries.toList(growable: false)
    ..sort((a, b) {
      final countOrder = b.value.compareTo(a.value);
      if (countOrder != 0) return countOrder;
      return a.key.compareTo(b.key);
    });

  return entries.take(5).map((entry) => {'name': entry.key, 'count': entry.value}).toList(growable: false);
}
