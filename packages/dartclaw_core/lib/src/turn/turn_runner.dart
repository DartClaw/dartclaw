import '../harness/agent_harness.dart';
import 'turn_outcome.dart';

/// Per-harness turn execution engine interface.
///
/// Encapsulates the turn lifecycle for a single [AgentHarness]: guard
/// evaluation, message persistence, event streaming, cost tracking, and crash
/// recovery. Multiple [TurnRunner] instances execute concurrently — one per
/// harness in the harness pool.
abstract interface class TurnRunner {
  /// Security profile this runner's harness executes in.
  String get profileId;

  /// Agent provider backing this runner's harness.
  String get providerId;

  /// The underlying harness managed by this runner.
  AgentHarness get harness;

  Iterable<String> get activeSessionIds;

  bool isActive(String sessionId);

  String? activeTurnId(String sessionId);

  bool isActiveTurn(String sessionId, String turnId);

  TurnOutcome? recentOutcome(String sessionId, String turnId);

  /// Reserves a new turn slot for [sessionId].
  ///
  /// Returns the new [turnId]. Throws [BusyTurnException] if global cap reached.
  Future<String> reserveTurn(
    String sessionId, {
    String agentName = 'main',
    String? directory,
    String? model,
    String? effort,
    int? maxTurns,
    bool isHumanInput = false,
  });

  /// Launches async execution for a previously [reserveTurn]'d turn.
  void executeTurn(
    String sessionId,
    String turnId,
    List<Map<String, dynamic>> messages, {
    String? source,
    String agentName = 'main',
    bool resume = false,
  });

  /// Rolls back a [reserveTurn] reservation without executing.
  void releaseTurn(String sessionId, String turnId);

  /// Clears runner-local and provider-side continuity for [sessionId].
  Future<void> resetSessionContinuity(String sessionId);

  Future<void> cancelTurn(String sessionId);

  Future<void> waitForCompletion(String sessionId, {Duration timeout = const Duration(seconds: 10)});

  Future<TurnOutcome> waitForOutcome(String sessionId, String turnId);

  /// Updates the per-task tool allowlist on the underlying guard.
  void setTaskToolFilter(List<String>? allowedTools);

  /// Enables or disables per-task read-only enforcement.
  void setTaskReadOnly(bool readOnly);
}
