import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/src/harness/claude_code_harness.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show CapturingFakeProcess;
import 'package:test/test.dart';

Future<ProcessResult> _defaultCommandProbe(String exe, List<String> args) async => ProcessResult(0, 0, '1.0.0', '');

Future<void> _noOpDelay(Duration _) async {}

void addTeardownAsync(Future<void> Function() fn) => addTearDown(fn);

/// Creates a [CapturingFakeProcess] with a non-broadcast stdout controller so
/// [scheduleMicrotask] emission before subscription is still delivered.
CapturingFakeProcess _makeCapturingProcess() => CapturingFakeProcess(stdoutController: StreamController<List<int>>());

// ---------------------------------------------------------------------------

void main() {
  group('PermissionDenied hook registration', () {
    test('initialize payload contains PermissionDenied hook with hook_permission_denied callback ID', () async {
      late CapturingFakeProcess fake;

      final h = ClaudeCodeHarness(
        cwd: '/tmp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          fake = _makeCapturingProcess();
          scheduleMicrotask(() {
            fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
          });
          return fake;
        },
        commandProbe: _defaultCommandProbe,
        delayFactory: _noOpDelay,
        environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
      );
      addTeardownAsync(() => h.dispose());

      await h.start();

      // Find the initialize control_request sent to stdin
      final initMsg = fake.capturedStdinJson.firstWhere(
        (msg) => msg['type'] == 'control_request' && (msg['request'] as Map?)?['subtype'] == 'initialize',
        orElse: () => <String, dynamic>{},
      );

      expect(initMsg, isNotEmpty, reason: 'Expected an initialize control_request');

      final request = initMsg['request'] as Map<String, dynamic>;
      // hooks are at request['hooks'] directly (not nested under 'initialize')
      final hooks = request['hooks'] as Map<String, dynamic>?;

      expect(hooks, isNotNull, reason: 'Expected hooks in initialize request');
      expect(hooks!.containsKey('PermissionDenied'), isTrue, reason: 'Expected PermissionDenied hook entry');

      final permDeniedHooks = hooks['PermissionDenied'] as List;
      expect(permDeniedHooks, isNotEmpty);

      final permDeniedEntry = permDeniedHooks.first as Map<String, dynamic>;
      final callbackIds = permDeniedEntry['hookCallbackIds'] as List;
      expect(callbackIds, contains('hook_permission_denied'));
    });

    test('PreToolUse entry contains if: condition with required tool names', () async {
      late CapturingFakeProcess fake;

      final h = ClaudeCodeHarness(
        cwd: '/tmp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          fake = _makeCapturingProcess();
          scheduleMicrotask(() {
            fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
          });
          return fake;
        },
        commandProbe: _defaultCommandProbe,
        delayFactory: _noOpDelay,
        environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
      );
      addTeardownAsync(() => h.dispose());

      await h.start();

      final initMsg = fake.capturedStdinJson.firstWhere(
        (msg) => msg['type'] == 'control_request' && (msg['request'] as Map?)?['subtype'] == 'initialize',
        orElse: () => <String, dynamic>{},
      );

      final request = initMsg['request'] as Map<String, dynamic>;
      final hooks = request['hooks'] as Map<String, dynamic>?;

      final preToolHooks = hooks?['PreToolUse'] as List?;
      expect(preToolHooks, isNotNull);
      expect(preToolHooks!.isNotEmpty, isTrue);

      final preToolEntry = preToolHooks.first as Map<String, dynamic>;
      expect(preToolEntry.containsKey('if'), isTrue, reason: 'Expected if: condition on PreToolUse');

      final ifCondition = preToolEntry['if'] as Map<String, dynamic>;
      final toolNameCondition = ifCondition['toolName'] as Map<String, dynamic>;
      final toolNames = (toolNameCondition[r'$in'] as List).cast<String>();

      expect(toolNames, containsAll(['Bash', 'Write', 'Edit', 'Read', 'MultiEdit']));
    });
  });

  group('PermissionDenied hook callback routing', () {
    test('PermissionDenied callback invokes onPermissionDenied with tool name and reason', () async {
      late CapturingFakeProcess fake;

      String? capturedTool;
      String? capturedReason;

      final h = ClaudeCodeHarness(
        cwd: '/tmp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          fake = _makeCapturingProcess();
          scheduleMicrotask(() {
            fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
          });
          return fake;
        },
        commandProbe: _defaultCommandProbe,
        delayFactory: _noOpDelay,
        environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
        onPermissionDenied: (toolName, reason) {
          capturedTool = toolName;
          capturedReason = reason;
        },
      );
      addTeardownAsync(() => h.dispose());

      await h.start();

      fake.emitStdout(
        jsonEncode({
          'type': 'control_request',
          'request_id': 'req-perm-denied',
          'request': {
            'subtype': 'hook_callback',
            'input': {'hook_event_name': 'PermissionDenied', 'tool_name': 'Bash', 'reason': 'Command not in allowlist'},
          },
        }),
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(capturedTool, 'Bash');
      expect(capturedReason, 'Command not in allowlist');
    });

    test('harness sends acknowledgment response for PermissionDenied callback', () async {
      late CapturingFakeProcess fake;

      final h = ClaudeCodeHarness(
        cwd: '/tmp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          fake = _makeCapturingProcess();
          scheduleMicrotask(() {
            fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
          });
          return fake;
        },
        commandProbe: _defaultCommandProbe,
        delayFactory: _noOpDelay,
        environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
      );
      addTeardownAsync(() => h.dispose());

      await h.start();
      final lineCountBeforeHook = fake.capturedStdinJson.length;

      fake.emitStdout(
        jsonEncode({
          'type': 'control_request',
          'request_id': 'req-perm-ack',
          'request': {
            'subtype': 'hook_callback',
            'input': {'hook_event_name': 'PermissionDenied', 'tool_name': 'Write'},
          },
        }),
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      // A response should have been written after the hook callback.
      // Shape: {type: control_response, response: {subtype: success, request_id: ..., response: {...}}}
      final newLines = fake.capturedStdinJson.sublist(lineCountBeforeHook);
      final response = newLines.firstWhere(
        (msg) => msg['type'] == 'control_response' && (msg['response'] as Map?)?['request_id'] == 'req-perm-ack',
        orElse: () => <String, dynamic>{},
      );
      expect(response, isNotEmpty, reason: 'Expected acknowledgment response for PermissionDenied');
    });

    test('PermissionDenied callback with null onPermissionDenied does not crash', () async {
      late CapturingFakeProcess fake;

      final h = ClaudeCodeHarness(
        cwd: '/tmp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          fake = _makeCapturingProcess();
          scheduleMicrotask(() {
            fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
          });
          return fake;
        },
        commandProbe: _defaultCommandProbe,
        delayFactory: _noOpDelay,
        environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
        // onPermissionDenied not set
      );
      addTeardownAsync(() => h.dispose());

      await h.start();

      // Simulate PermissionDenied — must not throw
      expect(() async {
        fake.emitStdout(
          jsonEncode({
            'type': 'control_request',
            'request_id': 'req-no-callback',
            'request': {
              'subtype': 'hook_callback',
              'input': {'hook_event_name': 'PermissionDenied', 'tool_name': 'Bash'},
            },
          }),
        );
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }, returnsNormally);
    });

    test('PermissionDenied callback with missing tool_name defaults to empty string', () async {
      late CapturingFakeProcess fake;

      String? capturedTool;

      final h = ClaudeCodeHarness(
        cwd: '/tmp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          fake = _makeCapturingProcess();
          scheduleMicrotask(() {
            fake.emitStdout(jsonEncode({'type': 'control_response', 'response': {}}));
          });
          return fake;
        },
        commandProbe: _defaultCommandProbe,
        delayFactory: _noOpDelay,
        environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
        onPermissionDenied: (toolName, reason) {
          capturedTool = toolName;
        },
      );
      addTeardownAsync(() => h.dispose());

      await h.start();

      fake.emitStdout(
        jsonEncode({
          'type': 'control_request',
          'request_id': 'req-no-tool',
          'request': {
            'subtype': 'hook_callback',
            'input': {'hook_event_name': 'PermissionDenied'}, // no tool_name
          },
        }),
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(capturedTool, '');
    });
  });
}
