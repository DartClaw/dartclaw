@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_server/src/turn_governance_enforcer.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late KvService kvService;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('turn_governance_integration_test_');
    kvService = KvService(filePath: '${tempDir.path}/kv.json');
  });

  tearDown(() async {
    await kvService.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  BudgetEnforcer buildBudgetEnforcer({int dailyTokens = 1000, BudgetAction action = BudgetAction.block}) {
    final tracker = UsageTracker(dataDir: tempDir.path, kv: kvService);
    return BudgetEnforcer(
      usageTracker: tracker,
      config: BudgetConfig(dailyTokens: dailyTokens, action: action, timezone: 'UTC'),
    );
  }

  Future<void> seedTokens(String dateKey, {required int input, required int output}) async {
    final aggregate = {'total_input_tokens': input, 'total_output_tokens': output, 'by_agent': <String, dynamic>{}};
    await kvService.set(dateKey, jsonEncode(aggregate));
  }

  LoopDetector buildLoopDetector({int maxConsecutiveTurns = 3}) {
    return LoopDetector(
      config: LoopDetectionConfig(
        enabled: true,
        maxConsecutiveTurns: maxConsecutiveTurns,
        maxTokensPerMinute: 0, // disabled
        velocityWindowMinutes: 2,
        maxConsecutiveIdenticalToolCalls: 0, // disabled
        action: LoopAction.abort,
      ),
    );
  }

  TurnGovernanceEnforcer buildEnforcer({
    BudgetEnforcer? budgetEnforcer,
    SlidingWindowRateLimiter? rateLimiter,
    LoopDetector? loopDetector,
    _RecordingSseBroadcast? sse,
  }) {
    return TurnGovernanceEnforcer(
      budgetEnforcer: budgetEnforcer,
      globalRateLimiter: rateLimiter,
      loopDetector: loopDetector,
      loopAction: loopDetector != null ? LoopAction.abort : null,
      sseBroadcast: sse,
      eventBus: null,
    );
  }

  // ---------------------------------------------------------------------------
  // Test 1: awaitRateLimitWindow() returns immediately when under limit
  // ---------------------------------------------------------------------------

  group('TurnGovernanceEnforcer — rate limit (under limit)', () {
    test('awaitRateLimitWindow() completes immediately when capacity is available', () async {
      final limiter = SlidingWindowRateLimiter(limit: 5, window: const Duration(minutes: 1));
      final enforcer = buildEnforcer(rateLimiter: limiter);

      // Should complete without delay — limiter has full capacity
      await expectLater(enforcer.awaitRateLimitWindow(), completes);
    });
  });

  // ---------------------------------------------------------------------------
  // Test 2: awaitRateLimitWindow() defers until limit opens
  // ---------------------------------------------------------------------------

  group('TurnGovernanceEnforcer — rate limit (deferred)', () {
    test(
      'awaitRateLimitWindow() eventually completes after window expires',
      timeout: const Timeout(Duration(seconds: 10)),
      () async {
        // Use a tight window: 200ms. The production loop delays 1s between retries,
        // so by the time the first retry fires, the 200ms window will have expired.
        final limiter = SlidingWindowRateLimiter(limit: 2, window: const Duration(milliseconds: 200));

        // Fill the limiter to capacity
        limiter.check('global');
        limiter.check('global');
        // Verify the limiter is now at its limit
        expect(limiter.check('global'), isFalse);

        final enforcer = buildEnforcer(rateLimiter: limiter);

        // awaitRateLimitWindow() should eventually complete once the 200ms window expires.
        // The production code retries every 1s — within ~1.5s the window will have expired.
        await expectLater(enforcer.awaitRateLimitWindow(), completes);
      },
    );
  });

  // ---------------------------------------------------------------------------
  // Test 3: checkBudget() throws BudgetExhaustedException when tokens ≥ daily limit
  // ---------------------------------------------------------------------------

  group('TurnGovernanceEnforcer — budget enforcement', () {
    test('checkBudget() throws BudgetExhaustedException when tokens exhausted', () async {
      final today = DateTime.now().toUtc();
      final dateKey = BudgetEnforcer.dateKeyForTime(today);
      // Seed 600 input + 400 output = 1000 tokens (100% of 1000 limit → blocked)
      await seedTokens(dateKey, input: 600, output: 400);

      final enforcer = buildEnforcer(budgetEnforcer: buildBudgetEnforcer(dailyTokens: 1000));

      await expectLater(enforcer.checkBudget('session-1'), throwsA(isA<BudgetExhaustedException>()));
    });

    test('checkBudget() broadcasts budget_warning when warn threshold is crossed', () async {
      final today = DateTime.now().toUtc();
      final dateKey = BudgetEnforcer.dateKeyForTime(today);
      final sse = _RecordingSseBroadcast();

      // Seed 500 input + 300 output = 800 tokens (80% of 1000 limit → warn)
      await seedTokens(dateKey, input: 500, output: 300);

      final enforcer = buildEnforcer(
        budgetEnforcer: buildBudgetEnforcer(dailyTokens: 1000, action: BudgetAction.warn),
        sse: sse,
      );

      await expectLater(enforcer.checkBudget('session-warn'), completes);
      expect(sse.events, contains('budget_warning'));
    });
  });

  // ---------------------------------------------------------------------------
  // Test 4: checkLoopPreTurn() throws LoopDetectedException after exceeding maxConsecutiveTurns
  // ---------------------------------------------------------------------------

  group('TurnGovernanceEnforcer — loop detection', () {
    test('checkLoopPreTurn() throws LoopDetectedException on 4th consecutive non-human turn', () async {
      final loopDetector = buildLoopDetector(maxConsecutiveTurns: 3);
      final enforcer = buildEnforcer(loopDetector: loopDetector);

      const sessionId = 'session-loop';

      // Turns 1–3: depth 1, 2, 3 — at or below threshold, no exception
      await enforcer.checkLoopPreTurn(sessionId, isHumanInput: false);
      await enforcer.checkLoopPreTurn(sessionId, isHumanInput: false);
      await enforcer.checkLoopPreTurn(sessionId, isHumanInput: false);

      // Turn 4: depth 4 > maxConsecutiveTurns 3 → LoopDetectedException
      await expectLater(
        enforcer.checkLoopPreTurn(sessionId, isHumanInput: false),
        throwsA(isA<LoopDetectedException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Test 5: All three checks pass for a clean turn
  // ---------------------------------------------------------------------------

  group('TurnGovernanceEnforcer — clean turn (all checks pass)', () {
    test('checkBudget, awaitRateLimitWindow, and checkLoopPreTurn all succeed', () async {
      final today = DateTime.now().toUtc();
      final dateKey = BudgetEnforcer.dateKeyForTime(today);
      // Seed 200 input + 100 output = 300 tokens (30% of 1000 limit → well under budget)
      await seedTokens(dateKey, input: 200, output: 100);

      final limiter = SlidingWindowRateLimiter(limit: 10, window: const Duration(minutes: 1));
      final loopDetector = buildLoopDetector(maxConsecutiveTurns: 5);
      final enforcer = buildEnforcer(
        budgetEnforcer: buildBudgetEnforcer(dailyTokens: 1000),
        rateLimiter: limiter,
        loopDetector: loopDetector,
      );

      const sessionId = 'session-clean';

      // All three checks should complete without throwing
      await expectLater(enforcer.checkBudget(sessionId), completes);
      await expectLater(enforcer.awaitRateLimitWindow(), completes);
      await expectLater(enforcer.checkLoopPreTurn(sessionId, isHumanInput: false), completes);
    });
  });
}

class _RecordingSseBroadcast extends SseBroadcast {
  final List<String> events = [];

  @override
  void broadcast(String event, Map<String, dynamic> data) {
    events.add(event);
  }
}
