import '../harness/harness_pool.dart';
import 'package:dartclaw_config/dartclaw_config.dart' show PromptScope;
import 'turn_outcome.dart';

/// Manages agent turn lifecycle: start, stream, cancel, and drain.
///
/// Uses [HarnessPool.primary] for ordinary sessions and provider-matched task
/// runners for sessions pinned to a specific provider.
abstract interface class TurnManager {
  /// The pool backing this manager.
  HarnessPool get pool;

  /// Number of runners currently available to accept a new task.
  int get availableRunnerCount;

  Iterable<String> get activeSessionIds;

  bool isActive(String sessionId);

  String? activeTurnId(String sessionId);

  bool isActiveTurn(String sessionId, String turnId);

  TurnOutcome? recentOutcome(String sessionId, String turnId);

  Future<String> reserveTurn(
    String sessionId, {
    String agentName = 'main',
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
    String? taskId,
    bool isHumanInput = false,
    PromptScope? promptScope,
  });

  void executeTurn(
    String sessionId,
    String turnId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
    bool resume = false,
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
    int? maxTurns,
    String? taskId,
    bool isHumanInput = false,
    List<String>? allowedTools,
    bool readOnly = false,
  });

  Future<void> cancelTurn(String sessionId);

  Future<void> waitForCompletion(String sessionId, {Duration timeout = const Duration(seconds: 10)});

  Future<TurnOutcome> waitForOutcome(String sessionId, String turnId);

  Future<List<String>> detectAndCleanOrphanedTurns();

  bool consumeRecoveryNotice(String sessionId);

  void setTaskToolFilter(List<String>? allowedTools);

  void setTaskReadOnly(bool readOnly);
}
