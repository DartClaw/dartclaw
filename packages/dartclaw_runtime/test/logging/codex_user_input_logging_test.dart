import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/src/harness/codex_harness.dart';
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/src/logging/log_redactor.dart';
import 'package:dartclaw_runtime/src/logging/log_service.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

import '../test_utils.dart';

Future<void> _emitHostedQuestion(String format, String logPath) async {
  final service = LogService.fromConfig(
    format: format,
    logFile: logPath,
    level: 'WARNING',
    redactor: LogRedactor(redactor: MessageRedactor(extraPatterns: ['CUSTOM_SENTINEL'])),
  )..install();
  final process = FakeCodexProcess(completeExitOnKill: true);
  final harness = CodexHarness(
    cwd: Directory.current.path,
    processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async => process,
    commandProbe: defaultCommandProbe,
    delayFactory: noOpDelay,
    environment: const {'OPENAI_API_KEY': 'sk-test-key'},
  );
  try {
    await startHarness(harness, process);
    final turn = harness.turn(
      sessionId: 'hosted',
      messages: const [
        {'role': 'user', 'content': 'ask'},
      ],
      systemPrompt: '',
    );
    await respondToLatestThreadStart(process);
    harness.handleProcessStdoutLine(
      jsonEncode({
        'method': 'turn/started',
        'params': {
          'threadId': 'thread-123',
          'turn': {'id': 'turn-1'},
        },
      }),
    );
    harness.handleProcessStdoutLine(
      jsonEncode({
        'method': 'item/completed',
        'params': {
          'threadId': 'thread-123',
          'turnId': 'turn-1',
          'item': {
            'type': 'agentMessage',
            'id': 'question-1',
            'phase': 'commentary',
            'questions': [
              {
                'title': 'Choose sk_test_ABCSECRET\nCUSTOM_SENTINEL?',
                'options': ['Blue', 'Green'],
              },
            ],
          },
        },
      }),
    );
    harness.handleProcessStdoutLine(
      jsonEncode({
        'method': 'turn/completed',
        'params': {
          'threadId': 'thread-123',
          'turn': {
            'id': 'turn-1',
            'status': 'completed',
            'items': [
              {'type': 'agentMessage', 'phase': 'final_answer', 'text': 'Done.'},
            ],
          },
        },
      }),
    );
    if ((await turn).finalText != 'Done.') throw StateError('Provider final reply changed');
  } finally {
    await harness.dispose();
    await service.dispose();
  }
}

Future<void> main() async {
  final capturePath = Platform.environment['DARTCLAW_CODEX_LOG_CAPTURE'];
  if (capturePath != null) {
    await _emitHostedQuestion(Platform.environment['DARTCLAW_CODEX_LOG_FORMAT'] ?? 'human', capturePath);
    return;
  }
  for (final format in ['human', 'json']) {
    test('hosted $format logging retains real redacted question on stderr and file after final answer', () async {
      final directory = Directory.systemTemp.createTempSync('codex_user_input_logging');
      addTearDown(() => directory.deleteSync(recursive: true));
      final logFile = File('${directory.path}/harness.log');
      final file = await resolveServerPackagePath('test', 'logging', 'codex_user_input_logging_test.dart');
      final packageConfig = await resolveWorkspacePath('.dart_tool', 'package_config.json');
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['--packages=$packageConfig', file],
        environment: {
          ...Platform.environment,
          'DARTCLAW_CODEX_LOG_CAPTURE': logFile.path,
          'DARTCLAW_CODEX_LOG_FORMAT': format,
        },
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      for (final content in [result.stderr as String, logFile.readAsStringSync()]) {
        expect('Unsupported Codex user input'.allMatches(content), hasLength(1));
        expect(content, contains('Blue'));
        expect(content, isNot(contains('sk_test_ABCSECRET')));
        expect(content, isNot(contains('CUSTOM_SENTINEL')));
        expect(content.split('\n').where((line) => line.trim().isNotEmpty), hasLength(1));
      }
    });
  }
}
