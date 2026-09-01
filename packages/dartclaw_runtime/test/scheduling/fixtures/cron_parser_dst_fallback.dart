import 'dart:convert';

import 'package:dartclaw_runtime/dartclaw_runtime.dart';

void main() {
  final cron = CronExpression.parse('* * * * *');
  final beforeFallback = DateTime.fromMillisecondsSinceEpoch(
    DateTime.utc(2026, 11, 1, 5, 59, 30).millisecondsSinceEpoch,
  );
  final occurrences = [beforeFallback];
  for (var i = 0; i < 61; i++) {
    occurrences.add(cron.nextFrom(occurrences.last));
  }

  print(
    jsonEncode([
      for (final occurrence in occurrences)
        {'local': occurrence.toIso8601String(), 'utc': occurrence.toUtc().toIso8601String()},
    ]),
  );
}
