import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnRunner;
import 'package:dartclaw_runtime/src/turn_runner.dart' show TurnRunner;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

import 'turn_runner_test_support.dart';

void main() {
  late Directory tempDir;
  late String sessionsDir;
  late String workspaceDir;
  late SessionService sessions;
  late MessageService messages;
  late FastFakeWorker worker;
  late Database turnStateDb;
  late TurnStateStore turnState;
  late KvService kvService;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('turn_runner_budget_test_');
    sessionsDir = p.join(tempDir.path, 'sessions');
    workspaceDir = p.join(tempDir.path, 'workspace');
    Directory(sessionsDir).createSync(recursive: true);
    Directory(workspaceDir).createSync(recursive: true);

    sessions = SessionService(baseDir: sessionsDir);
    messages = MessageService(baseDir: sessionsDir);
    worker = FastFakeWorker();
    turnStateDb = sqlite3.openInMemory();
    turnState = TurnStateStore(turnStateDb);
    kvService = KvService(filePath: p.join(tempDir.path, 'kv.json'));
  });

  tearDown(() async {
    await messages.dispose();
    await worker.dispose();
    await turnState.dispose();
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  Future<void> seedTokens(String dateKey, {required int input, required int output}) async {
    final aggregate = {'total_input_tokens': input, 'total_output_tokens': output, 'by_agent': <String, dynamic>{}};
    await kvService.set(dateKey, jsonEncode(aggregate));
  }

  TurnRunner buildRunner({BudgetEnforcer? budgetEnforcer, RecordingSseBroadcast? sse}) {
    return TurnRunner(
      turnLimits: const TurnLimitsConfig.defaults(),
      harness: worker,
      messages: messages,
      behavior: BehaviorFileService(workspaceDir: workspaceDir),
      sessions: sessions,
      turnState: turnState,
      budgetEnforcer: budgetEnforcer,
      sseBroadcast: sse,
    );
  }

  group('TurnRunner — budget enforcement', () {
    test('no budget enforcer → no budget check (backward compat)', () async {
      final runner = buildRunner(); // no budgetEnforcer
      final session = await sessions.getOrCreateMainSession();
      worker.responseText = 'done';

      final turnId = await runner.startTurn(session.id, []).timeout(const Duration(seconds: 2));
      expect(turnId, isNotEmpty);
      await runner.waitForCompletion(session.id).timeout(const Duration(seconds: 2));
    });

    test('budget allow → turn proceeds normally', () async {
      // Seed today's actual date key at 20% usage.
      final tracker = UsageTracker(dataDir: tempDir.path, kv: kvService);
      final today = DateTime.now().toUtc();
      final m = today.month.toString().padLeft(2, '0');
      final d = today.day.toString().padLeft(2, '0');
      final dateKey = 'usage_daily:${today.year}-$m-$d';
      await seedTokens(dateKey, input: 100, output: 100); // 200/1000 = 20%

      final realEnforcer = BudgetEnforcer(
        usageTracker: tracker,
        config: const BudgetConfig(dailyTokens: 1000, action: BudgetAction.block),
      );

      final runner = buildRunner(budgetEnforcer: realEnforcer);
      final session = await sessions.getOrCreateMainSession();
      worker.responseText = 'ok';

      final turnId = await runner.startTurn(session.id, []).timeout(const Duration(seconds: 2));
      expect(turnId, isNotEmpty);
      await runner.waitForCompletion(session.id).timeout(const Duration(seconds: 2));
    });

    test('budget warn → SSE event broadcast, turn proceeds', () async {
      final sse = RecordingSseBroadcast();
      final notifications = <(String, BudgetEvaluation, bool)>[];
      final tracker = UsageTracker(dataDir: tempDir.path, kv: kvService);
      final today = DateTime.now().toUtc();
      final m = today.month.toString().padLeft(2, '0');
      final d = today.day.toString().padLeft(2, '0');
      final dateKey = 'usage_daily:${today.year}-$m-$d';
      await seedTokens(dateKey, input: 400, output: 400); // 800/1000 = 80%

      final warnEnforcer = BudgetEnforcer(
        usageTracker: tracker,
        config: const BudgetConfig(dailyTokens: 1000, action: BudgetAction.warn),
      );

      final runner = buildRunner(budgetEnforcer: warnEnforcer, sse: sse);
      runner.budgetWarningNotifier = (sessionId, result, {required blocking}) async {
        notifications.add((sessionId, result, blocking));
      };
      final session = await sessions.getOrCreateMainSession();
      worker.responseText = 'done';

      final turnId = await runner.startTurn(session.id, []).timeout(const Duration(seconds: 2));
      expect(turnId, isNotEmpty);
      expect(sse.payloadFor('budget_warning'), {
        'tokens_used': 800,
        'budget': 1000,
        'percentage': 80,
        'action': 'warn',
      });
      expect(notifications, hasLength(1));
      expect(notifications.single.$1, session.id);
      expect(notifications.single.$2.warningIsNew, isTrue);
      // warn action at 80%: the operator is told, the turn is not blocked.
      expect(notifications.single.$3, isFalse);
      await runner.waitForCompletion(session.id).timeout(const Duration(seconds: 2));
    });

    test('budget block at 100% → budget_warning names block, notifier told, then exception', () async {
      final sse = RecordingSseBroadcast();
      final notifications = <(String, BudgetEvaluation, bool)>[];
      final tracker = UsageTracker(dataDir: tempDir.path, kv: kvService);
      final today = DateTime.now().toUtc();
      final m = today.month.toString().padLeft(2, '0');
      final d = today.day.toString().padLeft(2, '0');
      final dateKey = 'usage_daily:${today.year}-$m-$d';
      await seedTokens(dateKey, input: 500, output: 500); // 1000/1000 = 100%

      final runner = buildRunner(
        budgetEnforcer: BudgetEnforcer(
          usageTracker: tracker,
          config: const BudgetConfig(dailyTokens: 1000, action: BudgetAction.block),
        ),
        sse: sse,
      );
      runner.budgetWarningNotifier = (sessionId, result, {required blocking}) async {
        notifications.add((sessionId, result, blocking));
      };
      final session = await sessions.getOrCreateMainSession();

      await expectLater(runner.reserveTurn(session.id), throwsA(isA<BudgetExhaustedException>()));

      expect(sse.payloadFor('budget_warning'), {
        'tokens_used': 1000,
        'budget': 1000,
        'percentage': 100,
        'action': 'block',
      });
      expect(notifications.single.$3, isTrue);
      expect(notifications.single.$2.outcome, BudgetOutcome.exceeded);
    });

    test('budget block → BudgetExhaustedException thrown, session lock NOT held', () async {
      final tracker = UsageTracker(dataDir: tempDir.path, kv: kvService);
      final today = DateTime.now().toUtc();
      final m = today.month.toString().padLeft(2, '0');
      final d = today.day.toString().padLeft(2, '0');
      final dateKey = 'usage_daily:${today.year}-$m-$d';
      await seedTokens(dateKey, input: 500, output: 500); // 1000/1000 = 100%

      final blockEnforcer = BudgetEnforcer(
        usageTracker: tracker,
        config: const BudgetConfig(dailyTokens: 1000, action: BudgetAction.block),
      );

      final runner = buildRunner(budgetEnforcer: blockEnforcer);
      final session = await sessions.getOrCreateMainSession();

      // Should throw BudgetExhaustedException (reserveTurn throws before executeTurn).
      await expectLater(runner.reserveTurn(session.id), throwsA(isA<BudgetExhaustedException>()));

      // Session lock must NOT be held after rejection —
      // verified by starting a turn on the same session with a null enforcer.
      final unlockRunner = buildRunner(); // no budget enforcer
      worker.responseText = 'done';
      final turnId = await unlockRunner.startTurn(session.id, []).timeout(const Duration(seconds: 2));
      expect(turnId, isNotEmpty);
      await unlockRunner.waitForCompletion(session.id).timeout(const Duration(seconds: 2));
    });
  });
}
