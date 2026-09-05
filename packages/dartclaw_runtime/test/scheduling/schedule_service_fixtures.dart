import 'dart:async';

import 'package:dartclaw_core/dartclaw_core.dart' hide TurnManager, TurnRunner;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';
import 'package:dartclaw_runtime/dartclaw_runtime.dart';

/// Shared fixtures for the `ScheduleService` suites.
///
/// `schedule_service_test.dart` and `schedule_service_once_test.dart` drive the
/// same service through the same fakes; keeping one copy is what stops the two
/// suites from drifting into two different notions of a fired job.
ScheduledJob cronJob(String id, String expression) =>
    ScheduledJob.fromConfig({'id': id, 'prompt': 'Run $id', 'schedule': expression, 'delivery': 'none'});

/// A runtime-registered job: never config-declared, so a live application must
/// leave it exactly where it is.
ScheduledJob builtInJob(String id) =>
    ScheduledJob(id: id, scheduleType: ScheduleType.interval, intervalMinutes: 30, onExecute: () async => 'done');

/// Configurable fake for execution tests.
class ConfigurableTurnManager implements TurnManager {
  int startTurnCallCount = 0;
  List<Map<String, dynamic>>? lastMessages;
  bool shouldFail = false;
  bool returnFailedOutcome = false;
  String responseText = 'simulated assistant output';

  /// Captured model/effort from the most recent startTurn call.
  String? lastModel;
  String? lastEffort;
  List<String>? lastAllowedTools;
  String? lastPrompt;

  /// Optional hook called inside startTurn — use to block execution for concurrency tests.
  Future<void> Function(String sessionId)? onStartTurn;

  final Map<String, Completer<TurnOutcome>> _pending = {};

  @override
  Future<String> startTurn(
    String sessionId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
    String? model,
    String? effort,
    String? systemPromptOverride,
    int? maxTurns,
    Map<String, dynamic>? outputSchema,
    String? providerSessionId,
    bool requestProviderSessionResume = false,
    String? taskId,
    bool isHumanInput = false,
    List<String>? allowedTools,
    bool readOnly = false,
    PromptScope? promptScope,
    Duration? turnTimeout,
    TurnOrigin? origin,
  }) async {
    startTurnCallCount++;
    lastMessages = messages;
    lastModel = model;
    lastEffort = effort;
    lastAllowedTools = allowedTools;
    lastPrompt = messages.single['content'] as String?;
    final turnId = 'fake-turn-$startTurnCallCount';

    if (shouldFail) {
      throw Exception('Simulated startTurn failure');
    }

    if (onStartTurn != null) {
      await onStartTurn!(sessionId);
    }

    final completer = Completer<TurnOutcome>();
    _pending[turnId] = completer;

    final status = returnFailedOutcome ? TurnStatus.failed : TurnStatus.completed;
    final outcome = TurnOutcome(
      turnId: turnId,
      sessionId: sessionId,
      status: status,
      errorMessage: returnFailedOutcome ? 'simulated failure' : null,
      responseText: returnFailedOutcome ? null : responseText,
      completedAt: DateTime.now(),
    );
    completer.complete(outcome);

    return turnId;
  }

  @override
  Future<TurnOutcome> waitForOutcome(String sessionId, String turnId) async {
    final c = _pending[turnId];
    if (c == null) throw ArgumentError('Unknown turnId: $turnId');
    return c.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class FakeSessionService implements SessionService {
  final Map<String, Session> keyedSessions = {};

  @override
  Future<Session> getOrCreateByKey(
    String key, {
    SessionType type = SessionType.user,
    String? provider,
    String? securityProfile,
    ExecutionMode? executionMode,
  }) async {
    return keyedSessions.putIfAbsent(
      key,
      () => Session(
        id: 'fake-uuid-for-$key',
        type: type,
        provider: provider,
        securityProfile: securityProfile,
        executionMode: executionMode,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class ManualTimer implements Timer {
  final Duration duration;
  final void Function() _callback;
  var _isActive = true;

  new(this.duration, this._callback);

  void fire() {
    if (!_isActive) return;
    _isActive = false;
    _callback();
  }

  @override
  bool get isActive => _isActive;

  @override
  int get tick => _isActive ? 0 : 1;

  @override
  void cancel() {
    _isActive = false;
  }
}
