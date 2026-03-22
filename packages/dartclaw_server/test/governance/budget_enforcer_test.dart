import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late KvService kvService;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('budget_enforcer_test_');
    kvService = KvService(filePath: '${tempDir.path}/kv.json');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  BudgetEnforcer buildEnforcer({
    int dailyTokens = 1000,
    BudgetAction action = BudgetAction.block,
    String timezone = 'UTC',
  }) {
    final tracker = UsageTracker(dataDir: tempDir.path, kv: kvService);
    return BudgetEnforcer(
      usageTracker: tracker,
      config: BudgetConfig(dailyTokens: dailyTokens, action: action, timezone: timezone),
    );
  }

  /// Seeds KV with a daily aggregate for the given date key.
  Future<void> seedTokens(String dateKey, {required int input, required int output}) async {
    final aggregate = {'total_input_tokens': input, 'total_output_tokens': output, 'by_agent': <String, dynamic>{}};
    await kvService.set(dateKey, jsonEncode(aggregate));
  }

  // ---------------------------------------------------------------------------
  // Static helpers (Layer 1 — unit)
  // ---------------------------------------------------------------------------

  group('BudgetEnforcer.resolveTimezoneOffset', () {
    test('UTC → zero offset', () {
      expect(BudgetEnforcer.resolveTimezoneOffset('UTC'), Duration.zero);
    });

    test('GMT → zero offset', () {
      expect(BudgetEnforcer.resolveTimezoneOffset('GMT'), Duration.zero);
    });

    test('UTC+5 → +5 hours', () {
      expect(BudgetEnforcer.resolveTimezoneOffset('UTC+5'), const Duration(hours: 5));
    });

    test('UTC-3 → -3 hours', () {
      expect(BudgetEnforcer.resolveTimezoneOffset('UTC-3'), const Duration(hours: -3));
    });

    test('UTC+12 → +12 hours', () {
      expect(BudgetEnforcer.resolveTimezoneOffset('UTC+12'), const Duration(hours: 12));
    });

    test('invalid timezone (named IANA) → UTC with warning', () {
      final logs = <LogRecord>[];
      final sub = Logger.root.onRecord.listen(logs.add);
      addTearDown(sub.cancel);

      final offset = BudgetEnforcer.resolveTimezoneOffset('America/New_York');
      expect(offset, Duration.zero);
      expect(logs.any((r) => r.message.contains('Unrecognized timezone')), isTrue);
    });

    test('completely invalid string → UTC with warning', () {
      final logs = <LogRecord>[];
      final sub = Logger.root.onRecord.listen(logs.add);
      addTearDown(sub.cancel);

      final offset = BudgetEnforcer.resolveTimezoneOffset('bogus');
      expect(offset, Duration.zero);
      expect(logs.any((r) => r.message.contains('Unrecognized timezone')), isTrue);
    });
  });

  group('BudgetEnforcer.dateKeyForTime', () {
    test('produces usage_daily:YYYY-MM-DD format', () {
      final t = DateTime(2026, 3, 15);
      expect(BudgetEnforcer.dateKeyForTime(t), 'usage_daily:2026-03-15');
    });

    test('pads month and day with leading zeros', () {
      final t = DateTime(2026, 1, 5);
      expect(BudgetEnforcer.dateKeyForTime(t), 'usage_daily:2026-01-05');
    });
  });

  // ---------------------------------------------------------------------------
  // BudgetEnforcer.check — disabled budget
  // ---------------------------------------------------------------------------

  group('BudgetEnforcer.check — disabled', () {
    test('dailyTokens == 0 → always allow, enabled == false', () async {
      final tracker = UsageTracker(dataDir: tempDir.path, kv: kvService);
      final enforcer = BudgetEnforcer(
        usageTracker: tracker,
        config: const BudgetConfig.defaults(), // dailyTokens: 0
      );
      final result = await enforcer.check();
      expect(result.decision, BudgetDecision.allow);
    });
  });

  // ---------------------------------------------------------------------------
  // BudgetEnforcer.check — enforcement logic
  // ---------------------------------------------------------------------------

  group('BudgetEnforcer.check — enforcement', () {
    final t0 = DateTime(2026, 3, 15, 12, 0); // 2026-03-15 12:00 UTC

    test('no data in KV (fresh day) → allow with 0 tokens', () async {
      final enforcer = buildEnforcer(dailyTokens: 1000);
      final result = await enforcer.check(now: t0);
      expect(result.decision, BudgetDecision.allow);
      expect(result.tokensUsed, 0);
      expect(result.budget, 1000);
      expect(result.percentage, 0);
    });

    test('under 80% → allow', () async {
      await seedTokens('usage_daily:2026-03-15', input: 300, output: 200); // 500/1000 = 50%
      final enforcer = buildEnforcer(dailyTokens: 1000);
      final result = await enforcer.check(now: t0);
      expect(result.decision, BudgetDecision.allow);
      expect(result.tokensUsed, 500);
      expect(result.percentage, 50);
    });

    test('exactly at 80% → warn (first time)', () async {
      await seedTokens('usage_daily:2026-03-15', input: 480, output: 320); // 800/1000 = 80%
      final enforcer = buildEnforcer(dailyTokens: 1000);
      final result = await enforcer.check(now: t0);
      expect(result.decision, BudgetDecision.warn);
      expect(result.warningIsNew, isTrue);
      expect(result.percentage, 80);
    });

    test('at 80% → warn once, then allow (no repeat)', () async {
      await seedTokens('usage_daily:2026-03-15', input: 480, output: 320); // 800/1000 = 80%
      final enforcer = buildEnforcer(dailyTokens: 1000);

      final first = await enforcer.check(now: t0);
      expect(first.decision, BudgetDecision.warn);
      expect(first.warningIsNew, isTrue);

      final second = await enforcer.check(now: t0);
      expect(second.decision, BudgetDecision.allow);
      expect(second.warningIsNew, isFalse);
    });

    test('warning dedup survives enforcer restart via persisted daily aggregate marker', () async {
      await seedTokens('usage_daily:2026-03-15', input: 480, output: 320); // 800/1000 = 80%

      final firstEnforcer = buildEnforcer(dailyTokens: 1000);
      final first = await firstEnforcer.check(now: t0);
      expect(first.decision, BudgetDecision.warn);
      expect(first.warningIsNew, isTrue);

      final secondEnforcer = buildEnforcer(dailyTokens: 1000);
      final second = await secondEnforcer.check(now: t0);
      expect(second.decision, BudgetDecision.allow);
      expect(second.warningIsNew, isFalse);
    });

    test('at 100% with block action → block', () async {
      await seedTokens('usage_daily:2026-03-15', input: 600, output: 400); // 1000/1000 = 100%
      final enforcer = buildEnforcer(dailyTokens: 1000, action: BudgetAction.block);
      final result = await enforcer.check(now: t0);
      expect(result.decision, BudgetDecision.block);
      expect(result.percentage, 100);
    });

    test('at 100% with warn action → warn (first time), then allow', () async {
      await seedTokens('usage_daily:2026-03-15', input: 600, output: 400); // 1000/1000 = 100%
      final enforcer = buildEnforcer(dailyTokens: 1000, action: BudgetAction.warn);

      final first = await enforcer.check(now: t0);
      expect(first.decision, BudgetDecision.warn);
      expect(first.warningIsNew, isTrue);

      final second = await enforcer.check(now: t0);
      expect(second.decision, BudgetDecision.allow);
      expect(second.warningIsNew, isFalse);
    });

    test('over 100% with block action → block', () async {
      await seedTokens('usage_daily:2026-03-15', input: 700, output: 500); // 1200/1000 = 120%
      final enforcer = buildEnforcer(dailyTokens: 1000, action: BudgetAction.block);
      final result = await enforcer.check(now: t0);
      expect(result.decision, BudgetDecision.block);
      expect(result.percentage, 120);
    });

    test('warning resets on day rollover', () async {
      await seedTokens('usage_daily:2026-03-15', input: 480, output: 320); // 80% on day 1
      await seedTokens('usage_daily:2026-03-16', input: 480, output: 320); // 80% on day 2

      final enforcer = buildEnforcer(dailyTokens: 1000);

      final day1 = await enforcer.check(now: DateTime(2026, 3, 15, 12, 0));
      expect(day1.decision, BudgetDecision.warn);
      expect(day1.warningIsNew, isTrue);

      // Second check same day: no repeat
      final day1b = await enforcer.check(now: DateTime(2026, 3, 15, 14, 0));
      expect(day1b.decision, BudgetDecision.allow);

      // Day 2: warning resets (different date key)
      final day2 = await enforcer.check(now: DateTime(2026, 3, 16, 12, 0));
      expect(day2.decision, BudgetDecision.warn);
      expect(day2.warningIsNew, isTrue);
    });

    test('timezone offset shifts "today" boundary — UTC+12 near midnight', () async {
      // At 2026-03-15 13:00 UTC, UTC+12 is 2026-03-16 01:00 → "today" is 2026-03-16
      await seedTokens('usage_daily:2026-03-16', input: 600, output: 400); // 100% on local day
      final enforcer = buildEnforcer(dailyTokens: 1000, action: BudgetAction.block, timezone: 'UTC+12');
      final utcTime = DateTime(2026, 3, 15, 13, 0); // UTC time
      final result = await enforcer.check(now: utcTime);
      expect(result.decision, BudgetDecision.block);
    });

    test('config change (higher dailyTokens) → previously blocked turns now allowed', () async {
      await seedTokens('usage_daily:2026-03-15', input: 600, output: 400); // 1000 tokens used

      // Old config: 1000 → blocked
      final oldEnforcer = buildEnforcer(dailyTokens: 1000, action: BudgetAction.block);
      final blocked = await oldEnforcer.check(now: t0);
      expect(blocked.decision, BudgetDecision.block);

      // New config (restart with increased budget): 2000 → 50% → allowed
      final tracker = UsageTracker(dataDir: tempDir.path, kv: kvService);
      final newEnforcer = BudgetEnforcer(
        usageTracker: tracker,
        config: BudgetConfig(dailyTokens: 2000, action: BudgetAction.block),
      );
      final allowed = await newEnforcer.check(now: t0);
      expect(allowed.decision, BudgetDecision.allow);
    });
  });

  // ---------------------------------------------------------------------------
  // BudgetEnforcer.status
  // ---------------------------------------------------------------------------

  group('BudgetEnforcer.status', () {
    test('disabled → enabled: false', () async {
      final tracker = UsageTracker(dataDir: tempDir.path, kv: kvService);
      final enforcer = BudgetEnforcer(usageTracker: tracker, config: const BudgetConfig.defaults());
      final status = await enforcer.status();
      expect(status.enabled, isFalse);
    });

    test('enabled → returns correct usage data', () async {
      await seedTokens('usage_daily:2026-03-15', input: 300, output: 100);
      final enforcer = buildEnforcer(dailyTokens: 1000, action: BudgetAction.warn, timezone: 'UTC');
      final status = await enforcer.status(now: DateTime(2026, 3, 15, 12, 0));

      expect(status.enabled, isTrue);
      expect(status.tokensUsed, 400);
      expect(status.budget, 1000);
      expect(status.percentage, 40);
      expect(status.action, BudgetAction.warn);
      expect(status.timezone, 'UTC');
    });

    test('no data → tokensUsed: 0, percentage: 0', () async {
      final enforcer = buildEnforcer(dailyTokens: 1000);
      final status = await enforcer.status(now: DateTime(2026, 3, 15, 12, 0));
      expect(status.tokensUsed, 0);
      expect(status.percentage, 0);
    });

    test('percentage rounds correctly', () async {
      await seedTokens('usage_daily:2026-03-15', input: 100, output: 250); // 350/1000 = 35%
      final enforcer = buildEnforcer(dailyTokens: 1000);
      final status = await enforcer.status(now: DateTime(2026, 3, 15, 12, 0));
      expect(status.percentage, 35);
    });
  });
}
