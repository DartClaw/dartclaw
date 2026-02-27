import 'package:logging/logging.dart';

import 'guard_audit.dart';
import 'guard_verdict.dart';

// ---------------------------------------------------------------------------
// GuardContext
// ---------------------------------------------------------------------------

/// Context passed to every [Guard.evaluate] call.
class GuardContext {
  /// One of: 'beforeToolCall', 'messageReceived', 'beforeAgentSend'.
  final String hookPoint;

  /// Non-null for 'beforeToolCall' hook.
  final String? toolName;

  /// Non-null for 'beforeToolCall' hook.
  final Map<String, dynamic>? toolInput;

  /// Non-null for 'messageReceived' and 'beforeAgentSend' hooks.
  final String? messageContent;

  /// Active agent ID when evaluating in sub-agent context (null = main agent).
  final String? agentId;

  final DateTime timestamp;

  const GuardContext({
    required this.hookPoint,
    this.toolName,
    this.toolInput,
    this.messageContent,
    this.agentId,
    required this.timestamp,
  });
}

// ---------------------------------------------------------------------------
// Guard
// ---------------------------------------------------------------------------

/// Abstract base class for all DartClaw security guards.
///
/// Concrete guards (CommandGuard, FileGuard, etc.) extend this class.
/// Guards must NOT throw from [evaluate] — catch internally and return block.
abstract class Guard {
  String get name;
  String get category;

  Future<GuardVerdict> evaluate(GuardContext context);
}

// ---------------------------------------------------------------------------
// GuardChain
// ---------------------------------------------------------------------------

/// Evaluates a list of [Guard]s in order. First block verdict wins.
/// Exceptions from individual guards are treated as block (fail-closed).
class GuardChain {
  static final _log = Logger('GuardChain');

  final List<Guard> guards;
  final GuardAuditLogger auditLogger;
  final bool failOpen;

  GuardChain({required this.guards, required this.auditLogger, this.failOpen = false});

  /// Evaluates all guards for a 'beforeToolCall' hook point.
  Future<GuardVerdict> evaluateBeforeToolCall(String toolName, Map<String, dynamic> toolInput) {
    final context = GuardContext(
      hookPoint: 'beforeToolCall',
      toolName: toolName,
      toolInput: toolInput,
      timestamp: DateTime.now(),
    );
    return _evaluate(context);
  }

  /// Evaluates all guards for a 'messageReceived' hook point.
  Future<GuardVerdict> evaluateMessageReceived(String content) {
    final context = GuardContext(
      hookPoint: 'messageReceived',
      messageContent: content,
      timestamp: DateTime.now(),
    );
    return _evaluate(context);
  }

  /// Evaluates all guards for a 'beforeAgentSend' hook point.
  Future<GuardVerdict> evaluateBeforeAgentSend(String content) {
    final context = GuardContext(
      hookPoint: 'beforeAgentSend',
      messageContent: content,
      timestamp: DateTime.now(),
    );
    return _evaluate(context);
  }

  Future<GuardVerdict> _evaluate(GuardContext context) async {
    GuardVerdict result = GuardVerdict.pass();

    for (final guard in guards) {
      GuardVerdict verdict;
      try {
        verdict = await guard.evaluate(context).timeout(const Duration(seconds: 5));
      } catch (e, st) {
        _log.severe('Guard ${guard.name} threw: $e', e, st);
        verdict = failOpen
            ? GuardVerdict.warn('Guard error (fail-open): $e')
            : GuardVerdict.block('Guard error: $e');
      }

      auditLogger.logVerdict(
        verdict: verdict,
        guardName: guard.name,
        guardCategory: guard.category,
        hookPoint: context.hookPoint,
        timestamp: context.timestamp,
      );

      if (verdict.isBlock) return verdict;
      if (verdict.isWarn && result.isPass) result = verdict;
    }

    return result;
  }
}
