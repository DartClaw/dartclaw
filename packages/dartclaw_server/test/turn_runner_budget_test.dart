import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late String sessionsDir;
  late String workspaceDir;
  late SessionService sessions;
  late MessageService messages;
  late _FastFakeWorker worker;
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
    worker = _FastFakeWorker();
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

  TurnRunner buildRunner({BudgetEnforcer? budgetEnforcer, _RecordingSseBroadcast? sse}) {
    return TurnRunner(
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
      final session = await sessions.getOrCreateMain();
      worker.responseText = 'done';

      final turnId = await runner.startTurn(session.id, []).timeout(const Duration(seconds: 2));
      expect(turnId, isNotEmpty);
      await runner.waitForCompletion(session.id).timeout(const Duration(seconds: 2));
    });

    test('budget allow → turn proceeds normally', () async {
      // Seed today's actual date key at 20% usage.
      final tracker = UsageTracker(dataDir: tempDir.path, kv: kvService);
      final today = DateTime.now();
      final m = today.month.toString().padLeft(2, '0');
      final d = today.day.toString().padLeft(2, '0');
      final dateKey = 'usage_daily:${today.year}-$m-$d';
      await seedTokens(dateKey, input: 100, output: 100); // 200/1000 = 20%

      final realEnforcer = BudgetEnforcer(
        usageTracker: tracker,
        config: const BudgetConfig(dailyTokens: 1000, action: BudgetAction.block),
      );

      final runner = buildRunner(budgetEnforcer: realEnforcer);
      final session = await sessions.getOrCreateMain();
      worker.responseText = 'ok';

      final turnId = await runner.startTurn(session.id, []).timeout(const Duration(seconds: 2));
      expect(turnId, isNotEmpty);
      await runner.waitForCompletion(session.id).timeout(const Duration(seconds: 2));
    });

    test('budget warn → SSE event broadcast, turn proceeds', () async {
      final sse = _RecordingSseBroadcast();
      final notifications = <(String, BudgetCheckResult)>[];
      final tracker = UsageTracker(dataDir: tempDir.path, kv: kvService);
      final today = DateTime.now();
      final m = today.month.toString().padLeft(2, '0');
      final d = today.day.toString().padLeft(2, '0');
      final dateKey = 'usage_daily:${today.year}-$m-$d';
      await seedTokens(dateKey, input: 400, output: 400); // 800/1000 = 80%

      final warnEnforcer = BudgetEnforcer(
        usageTracker: tracker,
        config: const BudgetConfig(dailyTokens: 1000, action: BudgetAction.warn),
      );

      final runner = buildRunner(budgetEnforcer: warnEnforcer, sse: sse);
      runner.budgetWarningNotifier = (sessionId, result) async {
        notifications.add((sessionId, result));
      };
      final session = await sessions.getOrCreateMain();
      worker.responseText = 'done';

      final turnId = await runner.startTurn(session.id, []).timeout(const Duration(seconds: 2));
      expect(turnId, isNotEmpty);
      expect(sse.events, contains('budget_warning'));
      expect(notifications, hasLength(1));
      expect(notifications.single.$1, session.id);
      expect(notifications.single.$2.warningIsNew, isTrue);
      await runner.waitForCompletion(session.id).timeout(const Duration(seconds: 2));
    });

    test('budget block → BudgetExhaustedException thrown, session lock NOT held', () async {
      final tracker = UsageTracker(dataDir: tempDir.path, kv: kvService);
      final today = DateTime.now();
      final m = today.month.toString().padLeft(2, '0');
      final d = today.day.toString().padLeft(2, '0');
      final dateKey = 'usage_daily:${today.year}-$m-$d';
      await seedTokens(dateKey, input: 500, output: 500); // 1000/1000 = 100%

      final blockEnforcer = BudgetEnforcer(
        usageTracker: tracker,
        config: const BudgetConfig(dailyTokens: 1000, action: BudgetAction.block),
      );

      final runner = buildRunner(budgetEnforcer: blockEnforcer);
      final session = await sessions.getOrCreateMain();

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

class _FastFakeWorker extends AgentHarness {
  String responseText = '';
  final StreamController<BridgeEvent> _eventsCtrl = StreamController.broadcast();

  @override
  PromptStrategy get promptStrategy => PromptStrategy.replace;

  @override
  WorkerState get state => WorkerState.idle;

  @override
  Stream<BridgeEvent> get events => _eventsCtrl.stream;

  @override
  Future<void> start() async {}

  @override
  Future<Map<String, dynamic>> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    Map<String, dynamic>? mcpServers,
    bool resume = false,
    String? directory,
    String? model,
    String? effort,
  }) async {
    if (responseText.isNotEmpty) {
      _eventsCtrl.add(DeltaEvent(responseText));
    }
    return <String, dynamic>{'input_tokens': 0, 'output_tokens': 0};
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    if (!_eventsCtrl.isClosed) await _eventsCtrl.close();
  }
}

class _RecordingSseBroadcast extends SseBroadcast {
  final List<String> events = [];

  @override
  void broadcast(String event, Map<String, dynamic> data) {
    events.add(event);
  }
}
