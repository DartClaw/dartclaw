import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';

import '../storage/kv_service.dart';

// ---------------------------------------------------------------------------
// UsageEvent
// ---------------------------------------------------------------------------

/// A single LLM usage event with agent attribution.
class UsageEvent {
  final DateTime timestamp;
  final String sessionId;
  final String agentName; // 'main' | 'search' | 'heartbeat' | 'cron:<jobId>'
  final String? model;
  final int inputTokens;
  final int outputTokens;
  final int durationMs;

  const UsageEvent({
    required this.timestamp,
    required this.sessionId,
    required this.agentName,
    this.model,
    required this.inputTokens,
    required this.outputTokens,
    required this.durationMs,
  });

  Map<String, dynamic> toJson() => {
    'timestamp': timestamp.toIso8601String(),
    'session_id': sessionId,
    'agent_name': agentName,
    if (model != null) 'model': model,
    'input_tokens': inputTokens,
    'output_tokens': outputTokens,
    'duration_ms': durationMs,
  };
}

// ---------------------------------------------------------------------------
// UsageTracker
// ---------------------------------------------------------------------------

/// Appends [UsageEvent] records to `usage.jsonl` and maintains daily KV
/// aggregates with per-agent token breakdowns.
///
/// All operations are fire-and-forget -- errors are logged, never thrown.
class UsageTracker {
  static final _log = Logger('UsageTracker');

  final String dataDir;
  final KvService? _kv;
  final int? budgetWarningTokens;
  final int maxFileSizeBytes;

  UsageTracker({
    required this.dataDir,
    KvService? kv,
    this.budgetWarningTokens,
    this.maxFileSizeBytes = 10 * 1024 * 1024,
  }) : _kv = kv;

  String get usageFilePath => '$dataDir/usage.jsonl';

  /// Records a usage event: appends to JSONL, updates daily KV aggregate,
  /// checks file rotation and budget warning.
  Future<void> record(UsageEvent event) async {
    try {
      await _appendEvent(event);
    } catch (e) {
      _log.warning('Failed to append usage event: $e');
    }

    try {
      await _updateDailyAggregate(event);
    } catch (e) {
      _log.warning('Failed to update daily aggregate: $e');
    }

    try {
      await _rotateIfNeeded();
    } catch (e) {
      _log.warning('Failed to rotate usage file: $e');
    }

    try {
      await _checkBudgetWarning(event.timestamp);
    } catch (e) {
      _log.warning('Failed to check budget warning: $e');
    }
  }

  /// Returns today's daily usage aggregate from KV, or null if unavailable.
  Future<Map<String, dynamic>?> dailySummary() async {
    final kv = _kv;
    if (kv == null) return null;

    final key = _dailyKey(DateTime.now());
    final raw = await kv.get(key);
    if (raw == null) return null;

    return jsonDecode(raw) as Map<String, dynamic>;
  }

  // ---------------------------------------------------------------------------
  // Internal
  // ---------------------------------------------------------------------------

  Future<void> _appendEvent(UsageEvent event) async {
    final file = File(usageFilePath);
    final dir = file.parent;
    if (!dir.existsSync()) await dir.create(recursive: true);
    final line = jsonEncode(event.toJson());
    await file.writeAsString('$line\n', mode: FileMode.append);
  }

  Future<void> _updateDailyAggregate(UsageEvent event) async {
    final kv = _kv;
    if (kv == null) return;

    final key = _dailyKey(event.timestamp);
    final existing = await kv.get(key);

    Map<String, dynamic> aggregate;
    if (existing != null) {
      aggregate = jsonDecode(existing) as Map<String, dynamic>;
    } else {
      aggregate = {
        'total_input_tokens': 0,
        'total_output_tokens': 0,
        'by_agent': <String, dynamic>{},
      };
    }

    aggregate['total_input_tokens'] =
        (aggregate['total_input_tokens'] as int) + event.inputTokens;
    aggregate['total_output_tokens'] =
        (aggregate['total_output_tokens'] as int) + event.outputTokens;

    final byAgent = aggregate['by_agent'] as Map<String, dynamic>;
    final agentData = byAgent[event.agentName] as Map<String, dynamic>? ??
        {'input': 0, 'output': 0, 'turns': 0};

    agentData['input'] = (agentData['input'] as int) + event.inputTokens;
    agentData['output'] = (agentData['output'] as int) + event.outputTokens;
    agentData['turns'] = (agentData['turns'] as int) + 1;
    byAgent[event.agentName] = agentData;

    await kv.set(key, jsonEncode(aggregate));
  }

  Future<void> _rotateIfNeeded() async {
    final file = File(usageFilePath);
    if (!file.existsSync()) return;

    final size = await file.length();
    if (size <= maxFileSizeBytes) return;

    final backup = File('$usageFilePath.1');
    if (backup.existsSync()) await backup.delete();
    await file.rename(backup.path);
    _log.info('Rotated usage.jsonl (${size ~/ 1024}KB) -> usage.jsonl.1');
  }

  Future<void> _checkBudgetWarning(DateTime timestamp) async {
    final threshold = budgetWarningTokens;
    if (threshold == null) return;

    final kv = _kv;
    if (kv == null) return;

    final key = _dailyKey(timestamp);
    final raw = await kv.get(key);
    if (raw == null) return;

    final aggregate = jsonDecode(raw) as Map<String, dynamic>;
    final totalInput = aggregate['total_input_tokens'] as int;
    final totalOutput = aggregate['total_output_tokens'] as int;
    final totalTokens = totalInput + totalOutput;

    if (totalTokens >= threshold) {
      _log.warning(
        'Daily token budget warning: $totalTokens tokens used '
        '(threshold: $threshold)',
      );
    }
  }

  static String _dailyKey(DateTime timestamp) {
    final m = timestamp.month.toString().padLeft(2, '0');
    final d = timestamp.day.toString().padLeft(2, '0');
    return 'usage_daily:${timestamp.year}-$m-$d';
  }
}
