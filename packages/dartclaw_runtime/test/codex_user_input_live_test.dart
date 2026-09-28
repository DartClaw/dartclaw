@Tags(['integration'])
library;

import 'dart:io';

import 'package:dartclaw_core/src/harness/codex_harness.dart';
import 'package:dartclaw_runtime/src/logging/log_service.dart';
import 'package:logging/logging.dart';
import 'package:test/test.dart';

void main() {
  test('authenticated Codex turn retains any native question warning and follows its real terminal event', () async {
    final sourceHome = Platform.environment['CODEX_HOME'] ?? '${Platform.environment['HOME']}/.codex';
    final sourceAuth = File('$sourceHome/auth.json');
    expect(sourceAuth.existsSync(), isTrue, reason: 'Codex subscription auth is required for this live canary');
    final directory = Directory.systemTemp.createTempSync('codex_user_input_live');
    addTearDown(() => directory.deleteSync(recursive: true));
    final home = Directory('${directory.path}/home')..createSync();
    final copiedAuth = File('${home.path}/auth.json')..writeAsBytesSync(sourceAuth.readAsBytesSync());
    addTearDown(() {
      if (copiedAuth.existsSync()) copiedAuth.deleteSync();
    });
    File('${home.path}/config.toml').writeAsStringSync('''
model = "gpt-6-sol"
model_reasoning_effort = "high"
approval_policy = "never"
sandbox_mode = "danger-full-access"
[features]
plugins = false
[tools]
experimental_request_user_input = { enabled = true }
''');
    final logFile = File('${directory.path}/dartclaw.log');
    final oldLevel = Logger.root.level;
    final logging = LogService.fromConfig(logFile: logFile.path, level: 'WARNING')..install();
    addTearDown(() async {
      await logging.dispose();
      Logger.root.level = oldLevel;
    });
    final harness = CodexHarness(
      cwd: directory.path,
      executable: 'codex',
      environment: {...Platform.environment, 'CODEX_HOME': home.path},
      turnTimeout: const Duration(seconds: 150),
    );
    addTearDown(harness.dispose);
    await harness.start();
    final result = await harness.turn(
      sessionId: 'live-question',
      messages: const [
        {
          'role': 'user',
          'content':
              'If request_user_input_async is available, call it now with exactly one optional question: '
              'Which color do you prefer? Choices Blue and Green. Do not use other tools or work on files. '
              'After the tool returns, end this turn. If the tool is unavailable, ask the color question in your final reply.',
        },
      ],
      systemPrompt: '',
    );
    await logging.dispose();
    final logs = logFile.readAsStringSync();
    final warning = logs.contains('Unsupported Codex user input');
    expect(result.stopReason, 'completed', reason: '${result.error}');
    if (warning) {
      expect(logs, contains('No answer was supplied through DartClaw'));
      expect(logs, contains('Which color'));
    } else {
      expect(result.finalText?.toLowerCase(), contains('color'));
    }
    print(
      'Codex live canary: terminal=${result.stopReason}, asyncQuestionWarning=$warning, '
      'finalReplyPresent=${result.finalText?.isNotEmpty ?? false}',
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}
