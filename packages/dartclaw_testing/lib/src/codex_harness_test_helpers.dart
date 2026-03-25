import 'dart:io';

import 'package:dartclaw_core/dartclaw_core.dart';

import 'fake_codex_process.dart';

/// Creates a [ProcessResult] with the given [exitCode] and [stdout].
Future<ProcessResult> result({int exitCode = 0, String stdout = ''}) async {
  return ProcessResult(0, exitCode, stdout, '');
}

/// No-op [DelayFactory] that completes immediately.
Future<void> noOpDelay(Duration _) async {}

/// [CommandProbe] that returns a fake version string.
Future<ProcessResult> defaultCommandProbe(String exe, List<String> args) async {
  return result(exitCode: 0, stdout: '1.0.0');
}

/// Polls [FakeCodexProcess.sentMessages] until a message with the given
/// [method] appears, or throws after 50 attempts.
Future<void> waitForSentMessage(FakeCodexProcess process, String method) async {
  for (var i = 0; i < 50; i++) {
    if (process.sentMessages.any((message) => message['method'] == method)) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('Expected outbound message for $method');
}

/// Returns the `id` field of the last sent message matching [method].
Object latestRequestId(FakeCodexProcess process, String method) {
  return process.sentMessages.lastWhere(
    (message) => message['method'] == method,
  )['id']! as Object;
}

/// Performs the initialize handshake on [harness] using [process].
Future<void> startHarness(CodexHarness harness, FakeCodexProcess process) async {
  final startFuture = harness.start();
  await waitForSentMessage(process, 'initialize');
  process.emitInitializeResponse(id: latestRequestId(process, 'initialize'));
  await startFuture;
}

/// Responds to the latest `thread/start` request on [process].
Future<void> respondToLatestThreadStart(
  FakeCodexProcess process, {
  String threadId = 'thread-123',
}) async {
  await waitForSentMessage(process, 'thread/start');
  process.emitThreadStartResponse(
    id: latestRequestId(process, 'thread/start'),
    threadId: threadId,
  );
  await pumpEventLoop();
}

/// Yields to the event loop by awaiting a zero-duration delay.
Future<void> pumpEventLoop() async {
  await Future<void>.delayed(Duration.zero);
}
