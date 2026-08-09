import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/src/harness/claude_code_harness.dart';
import 'package:dartclaw_security/dartclaw_security.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show CapturingFakeProcess;
import 'package:test/test.dart';

Future<ProcessResult> _observerProbe(String exe, List<String> args) async => ProcessResult(0, 0, '1.0.0', '');

Future<void> _observerDelay(Duration _) async {}

Future<(ClaudeCodeHarness, CapturingFakeProcess)> _startHarness({
  GuardAuditLogger? auditLogger,
  void Function(String, String?)? onPermissionDenied,
}) async {
  late CapturingFakeProcess process;
  final harness = ClaudeCodeHarness(
    cwd: '/tmp',
    processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
      process = CapturingFakeProcess(stdoutController: StreamController<List<int>>(), completeExitOnKill: true);
      scheduleMicrotask(() => process.emitStdout(jsonEncode({'type': 'control_response', 'response': {}})));
      return process;
    },
    commandProbe: _observerProbe,
    delayFactory: _observerDelay,
    environment: const {'ANTHROPIC_API_KEY': 'sk-test-key'},
    auditLogger: auditLogger,
    onPermissionDenied: onPermissionDenied,
  );
  addTearDown(harness.dispose);
  await harness.start();
  return (harness, process);
}

void _emitHook(CapturingFakeProcess process, String requestId, Map<String, dynamic> input) {
  process.emitStdout(
    jsonEncode({
      'type': 'control_request',
      'request_id': requestId,
      'request': {'subtype': 'hook_callback', 'input': input},
    }),
  );
}

Iterable<Map<String, dynamic>> _responses(CapturingFakeProcess process, String requestId) =>
    process.capturedStdinJson.where((message) => (message['response'] as Map?)?['request_id'] == requestId);

void main() {
  test('PreCompact observer failure still acknowledges this and the next callback exactly once', () async {
    final (harness, process) = await _startHarness();
    harness.onCompactionStarting = (_, _) => throw StateError('observer failed');

    _emitHook(process, 'compact-fail', {'hook_event_name': 'PreCompact', 'session_id': 's1', 'trigger': 'auto'});
    _emitHook(process, 'compact-next', {'hook_event_name': 'PreCompact', 'session_id': 's1', 'trigger': 'manual'});
    await pumpEventQueue();

    expect(_responses(process, 'compact-fail'), hasLength(1));
    expect(_responses(process, 'compact-next'), hasLength(1));
  });

  test('PermissionDenied observer failure still acknowledges this and the next callback exactly once', () async {
    final (_, process) = await _startHarness(onPermissionDenied: (_, _) => throw StateError('observer failed'));

    _emitHook(process, 'permission-fail', {'hook_event_name': 'PermissionDenied', 'tool_name': 'Bash'});
    _emitHook(process, 'permission-next', {'hook_event_name': 'PermissionDenied', 'tool_name': 'Read'});
    await pumpEventQueue();

    expect(_responses(process, 'permission-fail'), hasLength(1));
    expect(_responses(process, 'permission-next'), hasLength(1));
  });

  test('PostToolUse audit failure still acknowledges this and the next callback exactly once', () async {
    final (_, process) = await _startHarness(auditLogger: _ThrowingPostToolUseAuditLogger());

    _emitHook(process, 'post-fail', {
      'hook_event_name': 'PostToolUse',
      'tool_name': 'Bash',
      'tool_response': {'result': 'ok'},
    });
    _emitHook(process, 'post-next', {
      'hook_event_name': 'PostToolUse',
      'tool_name': 'Read',
      'tool_response': {'result': 'ok'},
    });
    await pumpEventQueue();

    expect(_responses(process, 'post-fail'), hasLength(1));
    expect(_responses(process, 'post-next'), hasLength(1));
  });
}

final class _ThrowingPostToolUseAuditLogger extends GuardAuditLogger {
  @override
  void logPostToolUse({required String toolName, required bool success, required Map<String, dynamic> response}) {
    throw StateError('audit failed');
  }
}
