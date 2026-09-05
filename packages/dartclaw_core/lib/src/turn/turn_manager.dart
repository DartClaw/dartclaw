import 'package:dartclaw_kernel/dartclaw_kernel.dart';

import 'turn_outcome.dart';

/// Manages agent turn lifecycle: start, stream, cancel, and drain.
///
/// Host-owned agent turn lifecycle boundary.
abstract interface class TurnManager {
  /// Number of runners currently available to accept a new task.
  int get availableRunnerCount;

  Iterable<String> get activeSessionIds;

  bool isActive(String sessionId);

  String? activeTurnId(String sessionId);

  bool isActiveTurn(String sessionId, String turnId);

  TurnOutcome? recentOutcome(String sessionId, String turnId);

  /// Reserves a new turn slot for [sessionId]; [workerPolicy] overrides the
  /// execution placement otherwise derived from the session's pinned routing.
  Future<String> reserveTurn(
    String sessionId, {
    String agentName = 'main',
    String? directory,
    String? model,
    String? effort,
    String? systemPromptOverride,
    ExecutionPolicy? workerPolicy,
    int? maxTurns,
    Map<String, dynamic>? outputSchema,
    String? providerSessionId,
    bool requestProviderSessionResume = false,
    String? taskId,
    Duration? turnTimeout,
    bool isHumanInput = false,
    PromptScope? promptScope,
    TurnOrigin? origin,
  });

  void executeTurn(
    String sessionId,
    String turnId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
  });

  void releaseTurn(String sessionId, String turnId);

  /// Clears runner-local and provider-side continuity for [sessionId].
  Future<void> resetSessionContinuity(String sessionId);

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
    Duration? turnTimeout,
    bool isHumanInput = false,
    List<String>? allowedTools,
    bool readOnly = false,
    PromptScope? promptScope,
    TurnOrigin? origin,
  });

  Future<void> cancelTurn(String sessionId);

  Future<void> waitForCompletion(String sessionId, {Duration timeout = const Duration(seconds: 10)});

  Future<TurnOutcome> waitForOutcome(String sessionId, String turnId);

  Future<List<String>> detectAndCleanOrphanedTurns();

  bool consumeRecoveryNotice(String sessionId);

  void setTaskToolFilter(List<String>? allowedTools);

  void setTaskReadOnly(bool readOnly);
}
