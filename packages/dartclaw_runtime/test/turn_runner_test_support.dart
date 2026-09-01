// Shared support doubles for the TurnRunner governance suites
// (turn_runner_budget/loop_detection/rate_limit + the governance integration
// test) plus the TurnRunner-subclass fakes used by runner_routes/runner_observer,
// and the daily-log entry reader shared by the two daily-log suites.
// SseBroadcast and TurnRunner are dartclaw_runtime-owned, so this lives
// package-local rather than in the dartclaw_testing barrel.
import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'dart:async';
import 'dart:convert';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnRunner;
import 'package:dartclaw_runtime/dartclaw_runtime.dart' hide TurnRunner;
import 'package:dartclaw_runtime/src/turn_runner.dart' show TurnRunner;
import 'package:dartclaw_testing/dartclaw_testing.dart' show FakeAgentHarness;
import 'package:test/test.dart';

/// Every `**Tools**` summary in a daily log, decoded back out of the entry's
/// JSON array so assertions read as the summaries themselves rather than as
/// their escaping.
List<String> dailyLogToolSummaries(String content) => [
  for (final line in const LineSplitter().convert(content))
    if (line.startsWith('**Tools**: ')) ...(jsonDecode(line.substring('**Tools**: '.length)) as List).cast<String>(),
];

/// Capture-only [SseBroadcast] that records the names of broadcast events.
///
/// Used by the TurnRunner governance suites to assert which SSE events a guarded
/// turn emitted (e.g. budget/rate-limit/loop-detection signals) without wiring
/// real SSE clients.
class RecordingSseBroadcast extends SseBroadcast {
  final List<String> events = [];
  final List<(String, Map<String, dynamic>)> payloads = [];

  @override
  void broadcast(String event, Map<String, dynamic> data) {
    events.add(event);
    payloads.add((event, data));
  }

  Map<String, dynamic> payloadFor(String event) => payloads.firstWhere((entry) => entry.$1 == event).$2;
}

/// Immediate harness used by governance suites that exercise the runner rather
/// than harness scheduling.
class FastFakeWorker extends AgentHarness {
  String responseText = '';
  final StreamController<BridgeEvent> _events = StreamController.broadcast();

  @override
  PromptStrategy get promptStrategy => PromptStrategy.replace;

  @override
  WorkerState get state => WorkerState.idle;

  @override
  bool get isRootProcessTerminationConfirmed => true;

  @override
  Stream<BridgeEvent> get events => _events.stream;

  @override
  Future<void> start() async {}

  @override
  Future<TurnResult> turn({
    required String sessionId,
    required List<Map<String, dynamic>> messages,
    required String systemPrompt,
    String? agentId,
    Map<String, dynamic>? mcpServers,
    String? providerSessionId,
    bool requestProviderSessionResume = false,
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
    Map<String, dynamic>? outputSchema,
  }) async {
    if (responseText.isNotEmpty) {
      _events.add(DeltaEvent(responseText));
    }
    return const TurnResult();
  }

  @override
  Future<void> cancel() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> dispose() async {
    if (!_events.isClosed) await _events.close();
  }
}

/// Minimal real-[TurnRunner] subclass with no-op collaborators, for tests that
/// only need a `TurnRunner` instance (e.g. runner metrics / agent routes).
///
/// [providerId] defaults to `claude`; pass another to exercise per-provider
/// metric grouping.
class FakeTurnRunner extends TurnRunner {
  new({
    super.providerId = 'claude',
    super.executionPolicy = const ExecutionPolicy.host(),
    bool supportsCachedTokens = false,
  }) : super(
         turnLimits: const TurnLimitsConfig.defaults(),
         harness: FakeAgentHarness(autoTransitionState: false, supportsCachedTokens: supportsCachedTokens),
         messages: NoOpMessages(),
         behavior: BehaviorFileService(workspaceDir: '/tmp/dartclaw-turn-runner-test'),
         sessions: NoOpSessions(),
       );
}

/// No-op [MessageService] for tests that never read messages.
class NoOpMessages implements MessageService {
  @override
  Future<Message> insertMessage({
    required String sessionId,
    required String role,
    required String content,
    String? metadata,
  }) async => Message(
    cursor: 1,
    id: 'message',
    sessionId: sessionId,
    role: role,
    content: content,
    metadata: metadata,
    createdAt: DateTime.now(),
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// No-op [SessionService] for tests that never touch sessions.
class NoOpSessions implements SessionService {
  @override
  Future<void> touchUpdatedAt(String id) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

TurnResult turnResult({
  int inputTokens = 0,
  int outputTokens = 0,
  double? totalCostUsd,
  int? cachedInputTokens,
  int? cacheWriteTokens,
  String? stopReason,
  String? error,
  String? sessionTitle,
}) => TurnResult(
  stopReason: stopReason,
  error: error,
  sessionTitle: sessionTitle,
  inputTokens: inputTokens,
  outputTokens: outputTokens,
  costUsd: totalCostUsd,
  cacheReadTokens: cachedInputTokens ?? 0,
  cacheWriteTokens: cacheWriteTokens ?? 0,
);

void scheduleTurnCompletion(
  FakeAgentHarness worker, {
  String responseText = '',
  Future<void>? waitUntil,
  TurnResult? result,
  Object? error,
}) {
  unawaited(() async {
    await worker.turnInvoked;
    if (waitUntil != null) {
      await waitUntil;
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

  new({required super.sessions, required super.messages});

  @override
  void touchActivity(String sessionId) {
    touchedSessions.add(sessionId);
  }
}

class DelayedCancelHarness extends FakeAgentHarness {
  final cancelStarted = Completer<void>();
  final allowCancelReturn = Completer<void>();

  new() : super(promptStrategy: PromptStrategy.append);

  @override
  Future<void> cancel() async {
    cancelCalled = true;
    if (!cancelStarted.isCompleted) cancelStarted.complete();
    await allowCancelReturn.future;
  }
}

class FailingCancelCleanupHarness extends FakeAgentHarness {
  new() : super(promptStrategy: PromptStrategy.append);

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
  new() : super(promptStrategy: PromptStrategy.append);

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

class IdleAfterFailedCancelRecoveryHarness extends FakeAgentHarness {
  new({this.terminationConfirmed = true}) : super(promptStrategy: PromptStrategy.append);

  final bool terminationConfirmed;

  @override
  bool get isRootProcessTerminationConfirmed => terminationConfirmed;

  @override
  Future<void> cancel() async {
    cancelCalled = true;
    throw StateError('cancel failed');
  }
}

class HangingCancelHarness extends FakeAgentHarness {
  new() : super(promptStrategy: PromptStrategy.append);

  final cancelStarted = Completer<void>();
  final cancelCompleter = Completer<void>();

  @override
  Future<void> cancel() async {
    cancelCalled = true;
    if (!cancelStarted.isCompleted) cancelStarted.complete();
    await cancelCompleter.future;
  }
}
