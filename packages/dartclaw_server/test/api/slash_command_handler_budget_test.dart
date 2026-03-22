import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:dartclaw_google_chat/dartclaw_google_chat.dart';
import 'package:dartclaw_server/dartclaw_server.dart';
import 'package:dartclaw_storage/dartclaw_storage.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late KvService kvService;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('slash_cmd_budget_test_');
    kvService = KvService(filePath: '${tempDir.path}/kv.json');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  BudgetEnforcer buildEnforcer({
    required int dailyTokens,
    BudgetAction action = BudgetAction.warn,
    String timezone = 'UTC',
  }) {
    final tracker = UsageTracker(dataDir: tempDir.path, kv: kvService);
    return BudgetEnforcer(
      usageTracker: tracker,
      config: BudgetConfig(dailyTokens: dailyTokens, action: action, timezone: timezone),
    );
  }

  SlashCommandHandler buildHandler({BudgetEnforcer? budgetEnforcer}) {
    final eventBus = EventBus();
    final tasks = TaskService(SqliteTaskRepository(openTaskDbInMemory()), eventBus: eventBus);
    return SlashCommandHandler(
      taskService: tasks,
      budgetEnforcer: budgetEnforcer,
    );
  }

  Future<void> seedTokens(String dateKey, {required int input, required int output}) async {
    final aggregate = {
      'total_input_tokens': input,
      'total_output_tokens': output,
      'by_agent': <String, dynamic>{},
    };
    await kvService.set(dateKey, jsonEncode(aggregate));
  }

  // ---------------------------------------------------------------------------
  // /status budget section tests
  // ---------------------------------------------------------------------------

  group('SlashCommandHandler /status — budget section', () {
    test('no budget enforcer → no "Token Budget" section', () async {
      final handler = buildHandler(); // no budgetEnforcer
      final response = await handler.handle(
        const SlashCommand(name: 'status', arguments: ''),
        spaceName: 'spaces/AAAA',
        senderJid: 'users/123',
      );
      final body = response.toString();
      expect(body, isNot(contains('Token Budget')));
    });

    test('budget enforcer with dailyTokens: 0 → no "Token Budget" section (disabled)', () async {
      final tracker = UsageTracker(dataDir: tempDir.path, kv: kvService);
      final disabledEnforcer = BudgetEnforcer(
        usageTracker: tracker,
        config: const BudgetConfig.defaults(), // dailyTokens: 0
      );
      final handler = buildHandler(budgetEnforcer: disabledEnforcer);
      final response = await handler.handle(
        const SlashCommand(name: 'status', arguments: ''),
        spaceName: 'spaces/AAAA',
        senderJid: 'users/123',
      );
      final body = response.toString();
      expect(body, isNot(contains('Token Budget')));
    });

    test('budget enabled → response includes "Token Budget" section with usage data', () async {
      final today = BudgetEnforcer.dateKeyForTime(DateTime.now());
      await seedTokens(today, input: 300, output: 200); // 500/1000 = 50%

      final enforcer = buildEnforcer(dailyTokens: 1000, action: BudgetAction.warn);
      final handler = buildHandler(budgetEnforcer: enforcer);

      final response = await handler.handle(
        const SlashCommand(name: 'status', arguments: ''),
        spaceName: 'spaces/AAAA',
        senderJid: 'users/123',
      );

      final body = response.toString();
      expect(body, contains('Token Budget'));
      expect(body, contains('50%'));
      expect(body, contains('Action at Limit'));
      expect(body, contains('Warn only'));
    });

    test('budget exhausted (block mode) → section still shows, no crash', () async {
      final today = BudgetEnforcer.dateKeyForTime(DateTime.now());
      await seedTokens(today, input: 600, output: 400); // 100%

      final enforcer = buildEnforcer(dailyTokens: 1000, action: BudgetAction.block);
      final handler = buildHandler(budgetEnforcer: enforcer);

      final response = await handler.handle(
        const SlashCommand(name: 'status', arguments: ''),
        spaceName: 'spaces/AAAA',
        senderJid: 'users/123',
      );

      final body = response.toString();
      expect(body, contains('Token Budget'));
      expect(body, contains('100%'));
      expect(body, contains('Action at Limit'));
      expect(body, contains('Block new turns'));
    });
  });
}
