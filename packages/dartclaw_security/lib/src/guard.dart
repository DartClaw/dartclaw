import 'package:logging/logging.dart';

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

  /// Raw provider-specific tool name preserved for audit logging.
  final String? rawProviderToolName;

  /// Non-null for 'beforeToolCall' hook.
  final Map<String, dynamic>? toolInput;

  /// Non-null for 'messageReceived' and 'beforeAgentSend' hooks.
  final String? messageContent;

  /// Active agent ID when evaluating in sub-agent context (null = main agent).
  final String? agentId;

  /// Message origin: 'channel', 'web', 'cron', 'heartbeat', or null.
  final String? source;

  /// Active session ID for audit correlation.
  final String? sessionId;

  /// Peer identifier (phone number, username, etc.) for channel messages.
  final String? peerId;

  /// Time at which the guard evaluation started.
  final DateTime timestamp;

  /// Creates the immutable context shared with a guard evaluation.
  const GuardContext({
    required this.hookPoint,
    this.toolName,
    this.rawProviderToolName,
    this.toolInput,
    this.messageContent,
    this.agentId,
    this.source,
    this.sessionId,
    this.peerId,
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
  /// Stable guard identifier used in logs and audit records.
  String get name;

  /// High-level guard category such as `file`, `network`, or `command`.
  String get category;

  /// Evaluates the guard against [context] and returns a verdict.
  Future<GuardVerdict> evaluate(GuardContext context);
}

// ---------------------------------------------------------------------------
// GuardChain
// ---------------------------------------------------------------------------

/// Evaluates a list of [Guard]s in order. First block verdict wins.
/// Exceptions from individual guards are treated as block (fail-closed).
typedef GuardVerdictCallback =
    void Function(String guardName, String guardCategory, String verdict, String? message, GuardContext context);

/// Composes multiple [Guard] instances into a single ordered evaluation pipeline.
class GuardChain {
  static final _log = Logger('GuardChain');

  /// Guards evaluated in declaration order for every check.
  final List<Guard> guards;

  /// Optional callback invoked for non-pass verdicts.
  final GuardVerdictCallback? onVerdict;

  /// Whether unexpected guard failures should warn instead of block.
  final bool failOpen;

  /// Creates a guard chain with optional verdict reporting.
  GuardChain({required this.guards, this.onVerdict, this.failOpen = false});

  /// Appends [guard] after all constructor-supplied guards.
  ///
  /// Added guards are evaluated in the order they are registered and always
  /// run after the guards already present in [guards].
  void addGuard(Guard guard) {
    guards.add(guard);
    _log.info('Added guard ${guard.name} (${guard.category}) at position ${guards.length}');
  }

  /// Evaluates all guards for a 'beforeToolCall' hook point.
  Future<GuardVerdict> evaluateBeforeToolCall(
    String toolName,
    Map<dynamic, dynamic> toolInput, {
    String? sessionId,
    String? rawProviderToolName,
  }) {
    final context = GuardContext(
      hookPoint: 'beforeToolCall',
      toolName: toolName,
      rawProviderToolName: rawProviderToolName,
      toolInput: Map<String, dynamic>.from(toolInput),
      sessionId: sessionId,
      timestamp: DateTime.now(),
    );
    return _evaluate(context);
  }

  /// Evaluates all guards for a 'messageReceived' hook point.
  Future<GuardVerdict> evaluateMessageReceived(String content, {String? source, String? sessionId, String? peerId}) {
    final context = GuardContext(
      hookPoint: 'messageReceived',
      messageContent: content,
      source: source,
      sessionId: sessionId,
      peerId: peerId,
      timestamp: DateTime.now(),
    );
    return _evaluate(context);
  }

  /// Evaluates all guards for a 'beforeAgentSend' hook point.
  Future<GuardVerdict> evaluateBeforeAgentSend(String content, {String? sessionId}) {
    final context = GuardContext(
      hookPoint: 'beforeAgentSend',
      messageContent: content,
      sessionId: sessionId,
      timestamp: DateTime.now(),
    );
    return _evaluate(context);
  }

  /// Evaluates all guards against a fully-populated [GuardContext].
  Future<GuardVerdict> _evaluate(GuardContext context) async {
    GuardVerdict result = GuardVerdict.pass();

    for (final guard in guards) {
      GuardVerdict verdict;
      try {
        verdict = await guard.evaluate(context).timeout(const Duration(seconds: 5));
      } catch (e, st) {
        _log.severe('Guard ${guard.name} threw: $e', e, st);
        verdict = failOpen ? GuardVerdict.warn('Guard error (fail-open): $e') : GuardVerdict.block('Guard error: $e');
      }

      if (verdict.isBlock || verdict.isWarn) {
        onVerdict?.call(guard.name, guard.category, verdict.isBlock ? 'block' : 'warn', verdict.message, context);
      } else {
        _log.info(
          '[${guard.name}][${guard.category}][${context.hookPoint}] '
          'verdict=pass at=${context.timestamp.toIso8601String()}',
        );
      }

      if (verdict.isBlock) return verdict;
      if (verdict.isWarn && result.isPass) result = verdict;
    }

    return result;
  }
}
