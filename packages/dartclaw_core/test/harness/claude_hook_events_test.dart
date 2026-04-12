import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartclaw_core/src/harness/claude_code_harness.dart';
import 'package:dartclaw_testing/dartclaw_testing.dart' show NullIoSink;
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// Shared test infrastructure (mirrors claude_code_harness_test.dart pattern)
// ---------------------------------------------------------------------------

class FakeProcess implements Process {
  final StreamController<List<int>> _stdoutCtrl = StreamController<List<int>>();
  final StreamController<List<int>> _stderrCtrl = StreamController<List<int>>();
  final Completer<int> _exitCodeCompleter = Completer<int>();

  @override
  int get pid => 42;

  @override
  IOSink get stdin => NullIoSink();

  @override
  Stream<List<int>> get stdout => _stdoutCtrl.stream;

  @override
  Stream<List<int>> get stderr => _stderrCtrl.stream;

  @override
  Future<int> get exitCode => _exitCodeCompleter.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exitCodeCompleter.isCompleted) _exitCodeCompleter.complete(0);
    return true;
  }

  void emitStdout(String line) {
    _stdoutCtrl.add(utf8.encode('$line\n'));
  }
}

class CapturingFakeProcess extends FakeProcess {
  final List<Map<String, dynamic>> _captured;

  CapturingFakeProcess(this._captured);

  @override
  IOSink get stdin => _CapturingIOSink(_captured);
}

class _CapturingIOSink extends NullIoSink {
  final List<Map<String, dynamic>> _captured;
  _CapturingIOSink(this._captured);

  @override
  void add(List<int> data) {
    final line = utf8.decode(data).trim();
    if (line.isNotEmpty) {
      try {
        _captured.add(jsonDecode(line) as Map<String, dynamic>);
      } catch (_) {}
    }
  }
}

ProcessResult _result({int exitCode = 0, String stdout = ''}) => ProcessResult(0, exitCode, stdout, '');

Future<ProcessResult> _defaultCommandProbe(String exe, List<String> args) async =>
    _result(exitCode: 0, stdout: '1.0.0');

Future<void> _noOpDelay(Duration _) async {}

/// Registers async teardown — shorthand for [addTearDown] with async closures.
void addTeardownAsync(Future<void> Function() fn) => addTearDown(fn);

// ---------------------------------------------------------------------------

void main() {
  group('PermissionDenied hook registration', () {
    test('initialize payload contains PermissionDenied hook with hook_permission_denied callback ID', () async {
      final stdinLines = <Map<String, dynamic>>[];
      late CapturingFakeProcess fake;

      final h = ClaudeCodeHarness(
        cwd: '/tmp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          fake = CapturingFakeProcess(stdinLines);
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
      final initMsg = stdinLines.firstWhere(
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
      final stdinLines = <Map<String, dynamic>>[];
      late CapturingFakeProcess fake;

      final h = ClaudeCodeHarness(
        cwd: '/tmp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          fake = CapturingFakeProcess(stdinLines);
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

      final initMsg = stdinLines.firstWhere(
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
      final stdinLines = <Map<String, dynamic>>[];
      late CapturingFakeProcess fake;

      String? capturedTool;
      String? capturedReason;

      final h = ClaudeCodeHarness(
        cwd: '/tmp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          fake = CapturingFakeProcess(stdinLines);
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
      final stdinLines = <Map<String, dynamic>>[];
      late CapturingFakeProcess fake;

      final h = ClaudeCodeHarness(
        cwd: '/tmp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          fake = CapturingFakeProcess(stdinLines);
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
      final lineCountBeforeHook = stdinLines.length;

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
      final newLines = stdinLines.sublist(lineCountBeforeHook);
      final response = newLines.firstWhere(
        (msg) => msg['type'] == 'control_response' && (msg['response'] as Map?)?['request_id'] == 'req-perm-ack',
        orElse: () => <String, dynamic>{},
      );
      expect(response, isNotEmpty, reason: 'Expected acknowledgment response for PermissionDenied');
    });

    test('PermissionDenied callback with null onPermissionDenied does not crash', () async {
      late CapturingFakeProcess fake;
      final stdinLines = <Map<String, dynamic>>[];

      final h = ClaudeCodeHarness(
        cwd: '/tmp',
        processFactory: (exe, args, {workingDirectory, environment, includeParentEnvironment = true}) async {
          fake = CapturingFakeProcess(stdinLines);
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
          fake = CapturingFakeProcess([]);
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
