import 'dart:convert';

import 'package:dartclaw_cli/src/commands/config_loader.dart';
import 'package:dartclaw_cli/src/commands/workflow/standalone_lifecycle_support.dart';
import 'package:dartclaw_core/src/harness/codex_harness.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';

Future<void> main(List<String> arguments) async {
  final logFile = arguments[0];
  final format = arguments[1];
  final config = loadCliConfig(
    configPath: '/tmp/dartclaw.yaml',
    env: const {'HOME': '/home/testuser'},
    fileReader: (_) =>
        '''
logging:
  level: WARNING
  format: $format
  file: $logFile
  redact_patterns:
    - CUSTOM_SENTINEL
''',
  );
  final logging = installStandaloneLogging(config);
  final process = FakeCodexProcess(completeExitOnKill: true);
  final harness = CodexHarness(
    cwd: '/tmp',
    processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async => process,
    commandProbe: defaultCommandProbe,
    delayFactory: noOpDelay,
    environment: const {'OPENAI_API_KEY': 'sk-test-key'},
  );
  await startHarness(harness, process);
  final turn = harness.turn(
    sessionId: 'standalone',
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
              'options': ['Blue'],
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
  await turn;
  await harness.dispose();
  await logging.dispose();
}
