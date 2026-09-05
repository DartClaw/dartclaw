import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/src/harness/claude_code_harness.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show CapturingFakeProcess;
import 'package:test/test.dart';

Future<ProcessResult> _commandProbe(String exe, List<String> args) async => ProcessResult(0, 0, '1.0.0', '');

Future<void> _noOpDelay(Duration _) async {}

/// Starts a harness on a capturing fake process, sends one Bash `PreToolUse`
/// hook callback carrying [env], and returns the `env` map of the hook
/// response the harness wrote back for it.
Future<Map<String, dynamic>> _hookResponseEnv(Map<String, String> env) async {
  late CapturingFakeProcess fake;
  final harness = ClaudeCodeHarness(
    cwd: '/tmp',
    processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
      fake = CapturingFakeProcess(stdoutController: StreamController<List<int>>(), completeExitOnKill: true);
      scheduleMicrotask(() => fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}})));
      return fake;
    },
    commandProbe: _commandProbe,
    delayFactory: _noOpDelay,
    environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
  );
  addTearDown(harness.dispose);
  await harness.start();

  const requestId = 'req-bash-env';
  fake.emitStdout(
    jsonEncode({
      'type': 'control_request',
      'request_id': requestId,
      'request': {
        'subtype': 'hook_callback',
        'input': {
          'hook_event_name': 'PreToolUse',
          'tool_name': 'Bash',
          'tool_input': {'command': 'env', 'env': env},
        },
      },
    }),
  );
  await Future<void>.delayed(const Duration(milliseconds: 10));

  final responses = fake.capturedStdinJson
      .where((msg) => msg['type'] == 'control_response' && (msg['response'] as Map?)?['request_id'] == requestId)
      .toList();
  expect(responses, hasLength(1), reason: 'exactly one hook response per callback');
  final body = (responses.single['response'] as Map)['response'] as Map;
  final hookOutput = body['hookSpecificOutput'] as Map?;
  expect(
    hookOutput?['updatedInput'],
    isNotNull,
    reason: 'a credential strip answers with updatedInput, not a bare allow',
  );
  final updatedInput = hookOutput!['updatedInput'] as Map;
  expect(updatedInput['command'], 'env', reason: 'the rest of the tool input passes through unchanged');
  return Map<String, dynamic>.from(updatedInput['env'] as Map);
}

void main() {
  group('Bash env credential strip', () {
    test('removes ANTHROPIC_API_KEY and keeps the rest of the map', () async {
      final env = await _hookResponseEnv({'ANTHROPIC_API_KEY': 'sk-injected', 'PATH': '/usr/bin'});
      expect(env, {'PATH': '/usr/bin'});
    });

    test('removes CLAUDE_CODE_OAUTH_TOKEN, the credential a subscription-auth host deployment carries', () async {
      final env = await _hookResponseEnv({'CLAUDE_CODE_OAUTH_TOKEN': 'sk-ant-oat01-injected', 'PATH': '/usr/bin'});
      expect(env, {'PATH': '/usr/bin'});
    });

    test('removes both credentials in one response', () async {
      final env = await _hookResponseEnv({
        'ANTHROPIC_API_KEY': 'sk-injected',
        'CLAUDE_CODE_OAUTH_TOKEN': 'sk-ant-oat01-injected',
        'PATH': '/usr/bin',
      });
      expect(env, {'PATH': '/usr/bin'});
    });
  });
}
