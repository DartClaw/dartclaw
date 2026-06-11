// Shared support doubles for the TurnRunner governance suites
// (turn_runner_budget/loop_detection/rate_limit + the governance integration
// test) plus the TurnRunner-subclass fakes used by agent_routes/agent_observer.
// SseBroadcast and TurnRunner are dartclaw_server-owned, so this lives
// package-local rather than in the dartclaw_testing barrel.
import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner;
import 'package:dartclaw_server/dartclaw_server.dart' hide TurnRunner;
import 'package:dartclaw_server/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:test/test.dart';

/// Capture-only [SseBroadcast] that records the names of broadcast events.
///
/// Used by the TurnRunner governance suites to assert which SSE events a guarded
/// turn emitted (e.g. budget/rate-limit/loop-detection signals) without wiring
/// real SSE clients.
class RecordingSseBroadcast extends SseBroadcast {
  final List<String> events = [];

  @override
  void broadcast(String event, Map<String, dynamic> data) {
    events.add(event);
  }
}

/// Minimal real-[TurnRunner] subclass with no-op collaborators, for tests that
/// only need a `TurnRunner` instance (e.g. harness-pool metrics / agent routes).
///
/// [providerId] defaults to `claude`; pass another to exercise per-provider
/// metric grouping.
class FakeTurnRunner extends TurnRunner {
  FakeTurnRunner({super.providerId = 'claude'})
    : super(
        harness: MinimalHarness(),
        messages: NoOpMessages(),
        behavior: BehaviorFileService(workspaceDir: '/tmp/dartclaw-turn-runner-test'),
        sessions: NoOpSessions(),
      );
}

/// Inert [AgentHarness] whose [turn] returns an empty map; declares full
/// capability support so wiring code that probes the flags is satisfied.
class MinimalHarness implements AgentHarness {
  @override
  String skillActivationLine(String skill) => "Use the '$skill' skill.";

  @override
  bool get supportsCostReporting => true;

  @override
  bool get supportsToolApproval => true;

  @override
  bool get supportsStreaming => true;

  @override
  bool get supportsCachedTokens => false;

  @override
  bool get supportsSessionContinuity => false;

  @override
  bool get supportsPreCompactHook => false;

  @override
  PromptStrategy get promptStrategy => PromptStrategy.replace;
  @override
  WorkerState get state => WorkerState.idle;
  @override
  Stream<BridgeEvent> get events => const Stream.empty();
  @override
  Future<void> start() async {}
  @override
  Future<Map<String, dynamic>> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    Map<String, dynamic>? mcpServers,
    bool resume = false,
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
  }) async => {};
  @override
  Future<void> resetSessionContinuity(String sessionId) async {}

  @override
  Future<void> cancel() async {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

/// No-op [MessageService] for tests that never read messages.
class NoOpMessages implements MessageService {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// No-op [SessionService] for tests that never touch sessions.
class NoOpSessions implements SessionService {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

Map<String, dynamic> turnResult({
  int inputTokens = 0,
  int outputTokens = 0,
  double? totalCostUsd,
  int? cachedInputTokens,
  int? cacheWriteTokens,
}) {
  final result = <String, dynamic>{'input_tokens': inputTokens, 'output_tokens': outputTokens};
  if (totalCostUsd != null) {
    result['total_cost_usd'] = totalCostUsd;
  }
  if (cachedInputTokens != null) {
    result['cache_read_tokens'] = cachedInputTokens;
  }
  if (cacheWriteTokens != null) {
    result['cache_write_tokens'] = cacheWriteTokens;
  }
  return result;
}

void scheduleTurnCompletion(
  FakeAgentHarness worker, {
  String responseText = '',
  Duration delay = Duration.zero,
  Map<String, dynamic>? result,
  Object? error,
}) {
  unawaited(() async {
    await worker.turnInvoked;
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    if (error != null) {
      worker.completeError(error);
      return;
    }
    if (responseText.isNotEmpty) {
      worker.emit(DeltaEvent(responseText));
    }
    worker.completeSuccess(result ?? turnResult());
  }());
}

Future<Map<String, dynamic>> readSessionCost(KvService kvService, String sessionId) async {
  final raw = await kvService.get('session_cost:$sessionId');
  expect(raw, isNotNull);
  return jsonDecode(raw!) as Map<String, dynamic>;
}

class RecordingSessionResetService extends SessionResetService {
  final List<String> touchedSessions = [];

  RecordingSessionResetService({required super.sessions, required super.messages});

  @override
  void touchActivity(String sessionId) {
    touchedSessions.add(sessionId);
  }
}

class DelayedCancelHarness extends FakeAgentHarness {
  final cancelStarted = Completer<void>();
  final allowCancelReturn = Completer<void>();

  DelayedCancelHarness() : super(promptStrategy: PromptStrategy.append);

  @override
  Future<void> cancel() async {
    cancelCalled = true;
    if (!cancelStarted.isCompleted) cancelStarted.complete();
    await allowCancelReturn.future;
  }
}

class FailingCancelCleanupHarness extends FakeAgentHarness {
  FailingCancelCleanupHarness() : super(promptStrategy: PromptStrategy.append);

  int remainingStopFailures = 1;
  int stopCalls = 0;

  @override
  Future<void> stop() async {
    stopCalls += 1;
    stopCalled = true;
    if (remainingStopFailures > 0) {
      remainingStopFailures -= 1;
      throw StateError('stop failed');
    }
  }
}

class FailingStartAfterCancelHarness extends FakeAgentHarness {
  FailingStartAfterCancelHarness() : super(promptStrategy: PromptStrategy.append);

  @override
  Future<void> cancel() async {
    cancelCalled = true;
  }

  @override
  Future<void> start() async {
    startCalled = true;
    throw StateError('start failed');
  }
}

class HangingCancelHarness extends FakeAgentHarness {
  HangingCancelHarness() : super(promptStrategy: PromptStrategy.append);

  final cancelStarted = Completer<void>();
  final cancelCompleter = Completer<void>();

  @override
  Future<void> cancel() async {
    cancelCalled = true;
    if (!cancelStarted.isCompleted) cancelStarted.complete();
    await cancelCompleter.future;
  }
}
