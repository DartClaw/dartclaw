import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/src/harness/claude_code_harness.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart';
import 'package:test/test.dart';

ProcessResult _result({int exitCode = 0, String stdout = ''}) => ProcessResult(0, exitCode, stdout, '');

ClaudeCodeHarness _buildHarness({required void Function(List<String> args) onSpawn}) {
  final process = FakeProcess();

  return ClaudeCodeHarness(
    cwd: '/tmp',
    processFactory: (executable, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
      onSpawn(List<String>.unmodifiable(args));
      Future<void>.delayed(const Duration(milliseconds: 1), () {
        process.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
      });
      return process;
    },
    commandProbe: (executable, args) async => _result(exitCode: 0, stdout: '1.0.0'),
    delayFactory: (duration) async {},
    environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
  );
}

void main() {
  group('ClaudeCodeHarness permission optimization', () {
    test('uses --dangerously-skip-permissions when spawning claude', () async {
      List<String>? capturedArgs;
      final harness = _buildHarness(
        onSpawn: (args) {
          capturedArgs = args;
        },
      );
      addTearDown(() async => harness.dispose());

      await harness.start();

      expect(capturedArgs, isNotNull);
      expect(capturedArgs!, contains('--dangerously-skip-permissions'));
    });

    test('does not pass --permission-prompt-tool stdio when spawning claude', () async {
      List<String>? capturedArgs;
      final harness = _buildHarness(
        onSpawn: (args) {
          capturedArgs = args;
        },
      );
      addTearDown(() async => harness.dispose());

      await harness.start();

      expect(capturedArgs, isNotNull);
      expect(capturedArgs!, isNot(contains('--permission-prompt-tool')));
      expect(capturedArgs!, isNot(contains('stdio')));
    });

    test('unexpected can_use_tool while permissions are skipped is denied', () async {
      late CapturingFakeProcess fake;

      final harness = ClaudeCodeHarness(
        cwd: '/tmp',
        processFactory: (executable, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          fake = CapturingFakeProcess();
          Future<void>.delayed(const Duration(milliseconds: 1), () {
            fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
          });
          return fake;
        },
        commandProbe: (executable, args) async => _result(exitCode: 0, stdout: '1.0.0'),
        delayFactory: (duration) async {},
        environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
      );
      addTearDown(() async => harness.dispose());

      await harness.start();
      fake.emitStdout(
        jsonEncode({
          'type': 'control_request',
          'request_id': 'req-can-use-tool',
          'request': {'subtype': 'can_use_tool', 'tool_name': 'Bash', 'tool_use_id': 'tool-123'},
        }),
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      final response = fake.capturedStdinJson.lastWhere(
        (line) => (line['response'] as Map<String, dynamic>)['request_id'] == 'req-can-use-tool',
      );
      expect(response, {
        'type': 'control_response',
        'response': {
          'subtype': 'success',
          'request_id': 'req-can-use-tool',
          'response': {'behavior': 'deny', 'toolUseID': 'tool-123'},
        },
      });
    });
  });
}
