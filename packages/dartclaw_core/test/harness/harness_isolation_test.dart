import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/src/harness/claude_code_harness.dart';
import 'package:dartclaw_core/src/harness/harness_config.dart';
import 'package:dartclaw_core/src/harness/process_types.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeProcess;
import 'package:test/test.dart';

/// Creates a [FakeProcess] with a non-broadcast stdout controller so that
/// [scheduleMicrotask] emission before subscription is still delivered.
FakeProcess _makeProcess() => FakeProcess(stdoutController: StreamController<List<int>>());

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

ClaudeCodeHarness _buildHarness({
  ProcessFactory? processFactory,
  CommandProbe? commandProbe,
  HarnessConfig harnessConfig = const HarnessConfig(),
}) {
  return ClaudeCodeHarness(
    cwd: '/tmp',
    processFactory:
        processFactory ??
        (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          final fake = _makeProcess();
          scheduleMicrotask(() {
            fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
          });
          return fake;
        },
    commandProbe: commandProbe ?? (exe, args) async => ProcessResult(0, 0, '1.0.0', ''),
    environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
    harnessConfig: harnessConfig,
  );
}

void addTeardownAsync(Future<void> Function() fn) => addTearDown(fn);

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('harness startup isolation (--setting-sources)', () {
    test('non-containerized spawn passes --setting-sources project in args', () async {
      List<String>? capturedArgs;

      final h = _buildHarness(
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          capturedArgs = args;
          final fake = _makeProcess();
          scheduleMicrotask(() {
            fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
          });
          return fake;
        },
      );
      addTeardownAsync(() => h.dispose());

      await h.start();

      expect(capturedArgs, isNotNull);
      final idx = capturedArgs!.indexOf('--setting-sources');
      expect(idx, isNot(-1), reason: '--setting-sources flag must be present');
      expect(capturedArgs![idx + 1], 'project', reason: '--setting-sources value must be "project"');
    });

    test('--setting-sources appears before --model', () async {
      List<String>? capturedArgs;

      final h = _buildHarness(
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          capturedArgs = args;
          final fake = _makeProcess();
          scheduleMicrotask(() {
            fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
          });
          return fake;
        },
      );
      addTeardownAsync(() => h.dispose());

      await h.start();

      expect(capturedArgs, isNotNull);
      final settingIdx = capturedArgs!.indexOf('--setting-sources');
      final modelIdx = capturedArgs!.indexOf('--model');
      expect(settingIdx, isNot(-1));
      expect(modelIdx, isNot(-1));
      expect(settingIdx, lessThan(modelIdx));
    });

    test('--print and --output-format stream-json are also present (baseline)', () async {
      List<String>? capturedArgs;

      final h = _buildHarness(
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          capturedArgs = args;
          final fake = _makeProcess();
          scheduleMicrotask(() {
            fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
          });
          return fake;
        },
      );
      addTeardownAsync(() => h.dispose());

      await h.start();

      expect(capturedArgs, contains('--print'));
      expect(capturedArgs, contains('--output-format'));
      expect(capturedArgs, contains('stream-json'));
    });
  });
}
