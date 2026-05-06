import 'package:dartclaw_config/dartclaw_config.dart';
import 'package:dartclaw_core/dartclaw_core.dart';
import 'package:logging/logging.dart';

import 'api/sse_broadcast.dart';
import 'governance/budget_enforcer.dart';
import 'governance/budget_exhausted_exception.dart';

/// Handles turn governance checks for budgets, rate limits, and loop detection.
class TurnGovernanceEnforcer {
  static final _log = Logger('TurnGovernanceEnforcer');

  final BudgetEnforcer? _budgetEnforcer;
  final SlidingWindowRateLimiter? _globalRateLimiter;
  final LoopDetector? _loopDetector;
  final LoopAction? _loopAction;
  final SseBroadcast? _sseBroadcast;
  final EventBus? _eventBus;
  Future<void> Function(String sessionId, BudgetCheckResult result)? _budgetWarningNotifier;
  Future<void> Function(String sessionId, LoopDetection detection, String action)? _loopDetectionNotifier;
  bool _rateLimitWarningEmitted = false;

  TurnGovernanceEnforcer({
    required BudgetEnforcer? budgetEnforcer,
    required SlidingWindowRateLimiter? globalRateLimiter,
    required LoopDetector? loopDetector,
    required LoopAction? loopAction,
    required SseBroadcast? sseBroadcast,
    required EventBus? eventBus,
    Future<void> Function(String sessionId, BudgetCheckResult result)? budgetWarningNotifier,
    Future<void> Function(String sessionId, LoopDetection detection, String action)? loopDetectionNotifier,
  }) : _budgetEnforcer = budgetEnforcer,
       _globalRateLimiter = globalRateLimiter,
       _loopDetector = loopDetector,
       _loopAction = loopAction,
       _sseBroadcast = sseBroadcast,
       _eventBus = eventBus,
       _budgetWarningNotifier = budgetWarningNotifier,
       _loopDetectionNotifier = loopDetectionNotifier;

  set budgetWarningNotifier(Future<void> Function(String sessionId, BudgetCheckResult result)? notifier) {
    _budgetWarningNotifier = notifier;
  }

  set loopDetectionNotifier(Future<void> Function(String sessionId, LoopDetection detection, String action)? notifier) {
    _loopDetectionNotifier = notifier;
  }

  /// Checks the daily token budget before reserving a turn.
  Future<void> checkBudget(String sessionId) async {
    final enforcer = _budgetEnforcer;
    if (enforcer == null) return;

    final result = await enforcer.check();

    if (result.warningIsNew && result.decision != BudgetDecision.allow) {
      _log.warning(
        'Daily token budget at ${result.percentage}% '
        '(${result.tokensUsed}/${result.budget} tokens)',
      );
      _sseBroadcast?.broadcast('budget_warning', {
        'tokens_used': result.tokensUsed,
        'budget': result.budget,
        'percentage': result.percentage,
        'action': result.decision == BudgetDecision.block ? 'block' : 'warn',
      });

      final notifier = _budgetWarningNotifier;
      if (notifier != null) {
        try {
          await notifier(sessionId, result);
        } catch (error, stackTrace) {
          _log.warning('Failed to deliver channel budget warning for $sessionId', error, stackTrace);
        }
      }
    }

    if (result.decision == BudgetDecision.block) {
      throw BudgetExhaustedException(tokensUsed: result.tokensUsed, budget: result.budget);
    }
  }

  /// Performs pre-turn loop detection checks.
  Future<void> checkLoopPreTurn(String sessionId, {required bool isHumanInput}) async {
    final detector = _loopDetector;
    if (detector == null || !detector.enabled) return;

    if (isHumanInput) {
      detector.resetTurnChain(sessionId);
    }

    final chainDetection = isHumanInput ? null : detector.recordTurnStart(sessionId);
    if (chainDetection != null) {
      _handleLoopDetection(chainDetection, sessionId);
      if (_loopAction == LoopAction.abort) {
        throw LoopDetectedException(chainDetection.message, chainDetection);
      }
    }

    try {
      final velDetection = detector.checkTokenVelocity(sessionId);
      if (velDetection != null) {
        _handleLoopDetection(velDetection, sessionId);
        if (_loopAction == LoopAction.abort) {
          throw LoopDetectedException(velDetection.message, velDetection);
        }
      }
    } catch (e) {
      if (e is LoopDetectedException) rethrow;
      _log.fine('Loop velocity pre-check failed (non-fatal): $e');
    }
  }

  /// Handles a loop detection result and emits the relevant notifications.
  void _handleLoopDetection(LoopDetection detection, String sessionId) {
    _log.warning('Loop detected: ${detection.message}');
    final action = _loopAction == LoopAction.abort ? 'abort' : 'warn';
    _eventBus?.fire(
      LoopDetectedEvent(
        sessionId: sessionId,
        mechanism: detection.mechanism.name,
        message: detection.message,
        action: action,
        detail: detection.detail,
        timestamp: DateTime.now(),
      ),
    );
    if (_eventBus == null) {
      _sseBroadcast?.broadcast('loop_detected', {
        'sessionId': sessionId,
        'mechanism': detection.mechanism.name,
        'message': detection.message,
        'action': action,
        ...detection.detail,
      });
    }

    final notifier = _loopDetectionNotifier;
    if (notifier != null) {
      notifier(sessionId, detection, action).catchError((Object error, StackTrace stackTrace) {
        _log.warning('Failed to deliver loop detection notification for $sessionId', error, stackTrace);
      });
    }
  }

  /// Defers until global turn rate limit capacity opens.
  Future<void> awaitRateLimitWindow() async {
    final limiter = _globalRateLimiter;
    if (limiter == null) return;

    if (limiter.usage('global') >= 0.8 && !_rateLimitWarningEmitted) {
      _rateLimitWarningEmitted = true;
      _log.warning('Global turn rate at ${(limiter.usage('global') * 100).round()}% of limit');
      _sseBroadcast?.broadcast('rate_limit_warning', {
        'type': 'global_turn',
        'usage': limiter.usage('global'),
        'message': 'Global turn rate approaching limit (80%)',
      });
    }

    while (!limiter.check('global')) {
      _log.info('Global turn rate limit reached — deferring turn reservation');
      await Future.delayed(const Duration(seconds: 1));
    }

    if (limiter.usage('global') < 0.6) {
      _rateLimitWarningEmitted = false;
    }
  }

  /// Records a tool call and emits loop-detection side effects if needed.
  LoopDetection? recordToolCall(String turnId, String sessionId, String toolName, Map<String, dynamic> args) {
    final detector = _loopDetector;
    if (detector == null) return null;
    final detection = detector.recordToolCall(turnId, sessionId, toolName, args);
    if (detection != null) {
      _handleLoopDetection(detection, sessionId);
    }
    return detection;
  }

  /// Records token usage and checks velocity loop detection.
  LoopDetection? recordTokensAndCheckVelocity(String sessionId, int tokens) {
    final detector = _loopDetector;
    if (detector == null) return null;

    detector.recordTokens(sessionId, tokens);
    final detection = detector.checkTokenVelocity(sessionId);
    if (detection != null) {
      _handleLoopDetection(detection, sessionId);
    }
    return detection;
  }

  /// Cleans up per-turn loop detection state.
  void cleanupTurn(String turnId) {
    _loopDetector?.cleanupTurn(turnId);
  }
}
