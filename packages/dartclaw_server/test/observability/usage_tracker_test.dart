import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/src/observability/usage_tracker.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late KvService kvService;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('usage_tracker_test_');
    kvService = KvService(filePath: '${tempDir.path}/kv.json');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  UsageEvent makeEvent({
    String sessionId = 'sess-1',
    String agentName = 'main',
    String? model = 'sonnet',
    int inputTokens = 100,
    int outputTokens = 50,
    int durationMs = 1200,
    DateTime? timestamp,
  }) {
    return UsageEvent(
      timestamp: timestamp ?? DateTime.now(),
      sessionId: sessionId,
      agentName: agentName,
      model: model,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      durationMs: durationMs,
    );
  }

  group('UsageEvent', () {
    test('toJson serializes all fields', () {
      final now = DateTime.now();
      final event = UsageEvent(
        timestamp: now,
        sessionId: 'sess-1',
        agentName: 'main',
        model: 'sonnet',
        inputTokens: 100,
        outputTokens: 50,
        durationMs: 1200,
      );

      final json = event.toJson();
      expect(json['timestamp'], now.toIso8601String());
      expect(json['session_id'], 'sess-1');
      expect(json['agent_name'], 'main');
      expect(json['model'], 'sonnet');
      expect(json['input_tokens'], 100);
      expect(json['output_tokens'], 50);
      expect(json['duration_ms'], 1200);
    });

    test('toJson omits null model', () {
      final event = UsageEvent(
        timestamp: DateTime.now(),
        sessionId: 'sess-1',
        agentName: 'main',
        inputTokens: 100,
        outputTokens: 50,
        durationMs: 1200,
      );

      final json = event.toJson();
      expect(json.containsKey('model'), isFalse);
    });
  });

  group('UsageTracker', () {
    test('record appends NDJSON line to usage.jsonl', () async {
      final tracker = UsageTracker(dataDir: tempDir.path, kv: kvService);
      await tracker.record(makeEvent());

      final file = File(tracker.usageFilePath);
      expect(file.existsSync(), isTrue);

      final lines = file.readAsLinesSync().where((l) => l.isNotEmpty).toList();
      expect(lines, hasLength(1));

      final parsed = jsonDecode(lines[0]) as Map<String, dynamic>;
      expect(parsed['session_id'], 'sess-1');
      expect(parsed['agent_name'], 'main');
      expect(parsed['input_tokens'], 100);
      expect(parsed['output_tokens'], 50);
    });

    test('record appends multiple events', () async {
      final tracker = UsageTracker(dataDir: tempDir.path, kv: kvService);
      await tracker.record(makeEvent(agentName: 'main'));
      await tracker.record(makeEvent(agentName: 'search'));
      await tracker.record(makeEvent(agentName: 'heartbeat'));

      final lines = File(tracker.usageFilePath).readAsLinesSync().where((l) => l.isNotEmpty).toList();
      expect(lines, hasLength(3));
    });

    test('record updates daily KV aggregate', () async {
      final tracker = UsageTracker(dataDir: tempDir.path, kv: kvService);
      await tracker.record(makeEvent(inputTokens: 100, outputTokens: 50));
      await tracker.record(makeEvent(inputTokens: 200, outputTokens: 100));

      final summary = await tracker.dailySummary();
      expect(summary, isNotNull);
      expect(summary!['total_input_tokens'], 300);
      expect(summary['total_output_tokens'], 150);
    });

    test('daily aggregate tracks per-agent breakdown', () async {
      final tracker = UsageTracker(dataDir: tempDir.path, kv: kvService);
      await tracker.record(makeEvent(agentName: 'main', inputTokens: 100, outputTokens: 50));
      await tracker.record(makeEvent(agentName: 'search', inputTokens: 200, outputTokens: 100));
      await tracker.record(makeEvent(agentName: 'main', inputTokens: 50, outputTokens: 25));

      final summary = await tracker.dailySummary();
      expect(summary, isNotNull);

      final byAgent = summary!['by_agent'] as Map<String, dynamic>;
      final mainAgent = byAgent['main'] as Map<String, dynamic>;
      expect(mainAgent['input'], 150);
      expect(mainAgent['output'], 75);
      expect(mainAgent['turns'], 2);

      final searchAgent = byAgent['search'] as Map<String, dynamic>;
      expect(searchAgent['input'], 200);
      expect(searchAgent['output'], 100);
      expect(searchAgent['turns'], 1);
    });

    test('budget warning logged when threshold exceeded', () async {
      final warnings = <String>[];
      Logger.root.level = Level.ALL;
      final sub = Logger('UsageTracker').onRecord.listen((r) {
        if (r.level == Level.WARNING) warnings.add(r.message);
      });

      final tracker = UsageTracker(dataDir: tempDir.path, kv: kvService, budgetWarningTokens: 100);
      await tracker.record(makeEvent(inputTokens: 60, outputTokens: 50));

      await sub.cancel();

      expect(warnings, anyElement(contains('Daily token budget warning')));
      expect(warnings, anyElement(contains('110 tokens')));
    });

    test('no budget warning when under threshold', () async {
      final warnings = <String>[];
      Logger.root.level = Level.ALL;
      final sub = Logger('UsageTracker').onRecord.listen((r) {
        if (r.level == Level.WARNING) warnings.add(r.message);
      });

      final tracker = UsageTracker(dataDir: tempDir.path, kv: kvService, budgetWarningTokens: 1000);
      await tracker.record(makeEvent(inputTokens: 50, outputTokens: 30));

      await sub.cancel();

      expect(warnings.where((w) => w.contains('budget')), isEmpty);
    });

    test('no budget warning when threshold is null', () async {
      final warnings = <String>[];
      Logger.root.level = Level.ALL;
      final sub = Logger('UsageTracker').onRecord.listen((r) {
        if (r.level == Level.WARNING) warnings.add(r.message);
      });

      final tracker = UsageTracker(dataDir: tempDir.path, kv: kvService);
      await tracker.record(makeEvent(inputTokens: 999999, outputTokens: 999999));

      await sub.cancel();

      expect(warnings.where((w) => w.contains('budget')), isEmpty);
    });

    test('file rotation when exceeding maxFileSizeBytes', () async {
      final tracker = UsageTracker(
        dataDir: tempDir.path,
        kv: kvService,
        maxFileSizeBytes: 200, // very small threshold for testing
      );

      // Write enough events to exceed 200 bytes
      for (var i = 0; i < 5; i++) {
        await tracker.record(makeEvent(sessionId: 'session-$i'));
      }

      final backupFile = File('${tracker.usageFilePath}.1');
      expect(backupFile.existsSync(), isTrue);
    });

    test('dailySummary returns null when KV is null', () async {
      final tracker = UsageTracker(dataDir: tempDir.path);
      final summary = await tracker.dailySummary();
      expect(summary, isNull);
    });

    test('dailySummary returns null when no events recorded', () async {
      final tracker = UsageTracker(dataDir: tempDir.path, kv: kvService);
      final summary = await tracker.dailySummary();
      expect(summary, isNull);
    });

    test('record does not throw on file write failure', () async {
      // Use a non-writable path
      final tracker = UsageTracker(dataDir: '/nonexistent/deeply/nested/path');
      // Should complete without throwing
      await tracker.record(makeEvent());
    });

    test('record does not throw on KV failure', () async {
      // Use a tracker with a KV service pointing to a non-writable path
      final badKv = KvService(filePath: '/nonexistent/deeply/nested/kv.json');
      final tracker = UsageTracker(dataDir: tempDir.path, kv: badKv);
      // Should complete without throwing
      await tracker.record(makeEvent());
    });

    test('cron agent name tracked correctly', () async {
      final tracker = UsageTracker(dataDir: tempDir.path, kv: kvService);
      await tracker.record(makeEvent(agentName: 'cron:daily-report'));

      final summary = await tracker.dailySummary();
      final byAgent = summary!['by_agent'] as Map<String, dynamic>;
      expect(byAgent.containsKey('cron:daily-report'), isTrue);
      final cronAgent = byAgent['cron:daily-report'] as Map<String, dynamic>;
      expect(cronAgent['turns'], 1);
    });
  });
}
