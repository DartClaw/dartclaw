import 'dart:collection';

import '../config/governance_config.dart';
import 'loop_detection.dart';

/// Detects agent loop patterns using three independent mechanisms.
///
/// Injected into `TurnRunner`. All state is in-memory — resets on restart.
/// Each mechanism is independently disableable by setting its threshold to 0.
/// The detector returns [LoopDetection] results — callers decide the action.
class LoopDetector {
  final LoopDetectionConfig _config;

  /// Per-session consecutive autonomous turn count, reset on human input.
  final Map<String, int> _turnChainDepth = {};

  /// Per-session rolling window of (timestamp, tokens) for velocity tracking.
  final Map<String, List<({DateTime timestamp, int tokens})>> _tokenVelocityWindow = {};

  /// Per-turn consecutive identical tool call tracking.
  /// Value: last fingerprint and its consecutive count.
  final Map<String, ({String fingerprint, int count})> _consecutiveToolCalls = {};

  LoopDetector({required LoopDetectionConfig config}) : _config = config;

  /// Whether loop detection is globally enabled.
  bool get enabled => _config.enabled;

  // ── Turn chain depth (Mechanism 1) ──

  /// Increments the consecutive turn chain depth for [sessionId].
  ///
  /// Returns a [LoopDetection] if the depth exceeds [LoopDetectionConfig.maxConsecutiveTurns].
  LoopDetection? recordTurnStart(String sessionId) {
    if (!_config.enabled || _config.maxConsecutiveTurns <= 0) return null;
    final depth = (_turnChainDepth[sessionId] ?? 0) + 1;
    _turnChainDepth[sessionId] = depth;
    if (depth > _config.maxConsecutiveTurns) {
      return LoopDetection(
        mechanism: LoopMechanism.turnChainDepth,
        sessionId: sessionId,
        message: 'Consecutive turn chain depth $depth exceeds '
            'threshold ${_config.maxConsecutiveTurns}',
        detail: {'depth': depth, 'threshold': _config.maxConsecutiveTurns},
      );
    }
    return null;
  }

  /// Resets the consecutive turn chain depth for [sessionId].
  ///
  /// Call when a human-initiated turn arrives to clear the autonomous chain.
  void resetTurnChain(String sessionId) {
    _turnChainDepth.remove(sessionId);
  }

  // ── Token velocity (Mechanism 2) ──

  /// Records token consumption for velocity tracking.
  ///
  /// Adds an entry to the rolling window and lazily evicts expired entries.
  void recordTokens(String sessionId, int tokens, {DateTime? now}) {
    if (!_config.enabled || _config.maxTokensPerMinute <= 0) return;
    final timestamp = now ?? DateTime.now();
    final events = _tokenVelocityWindow.putIfAbsent(sessionId, () => []);
    events.add((timestamp: timestamp, tokens: tokens));
    // Lazy eviction of entries older than the window.
    final cutoff = timestamp.subtract(Duration(minutes: _config.velocityWindowMinutes));
    events.removeWhere((e) => e.timestamp.isBefore(cutoff));
  }

  /// Checks if token velocity exceeds the threshold for [sessionId].
  ///
  /// Returns a [LoopDetection] if tokens consumed in the rolling window exceed
  /// [LoopDetectionConfig.maxTokensPerMinute] * [LoopDetectionConfig.velocityWindowMinutes].
  LoopDetection? checkTokenVelocity(String sessionId, {DateTime? now}) {
    if (!_config.enabled || _config.maxTokensPerMinute <= 0) return null;
    final timestamp = now ?? DateTime.now();
    final events = _tokenVelocityWindow[sessionId];
    if (events == null || events.isEmpty) return null;

    final cutoff = timestamp.subtract(Duration(minutes: _config.velocityWindowMinutes));
    events.removeWhere((e) => e.timestamp.isBefore(cutoff));

    final totalTokens = events.fold<int>(0, (sum, e) => sum + e.tokens);
    final windowMinutes = _config.velocityWindowMinutes;
    final maxTokensInWindow = _config.maxTokensPerMinute * windowMinutes;

    if (totalTokens > maxTokensInWindow) {
      return LoopDetection(
        mechanism: LoopMechanism.tokenVelocity,
        sessionId: sessionId,
        message: 'Token velocity $totalTokens tokens in '
            '${windowMinutes}min window exceeds threshold '
            '$maxTokensInWindow',
        detail: {
          'tokensInWindow': totalTokens,
          'maxTokensInWindow': maxTokensInWindow,
          'windowMinutes': windowMinutes,
        },
      );
    }
    return null;
  }

  // ── Tool-call fingerprinting (Mechanism 3) ──

  /// Records a tool call and checks for consecutive identical calls.
  ///
  /// Returns a [LoopDetection] if the same tool is called with identical
  /// arguments [LoopDetectionConfig.maxConsecutiveIdenticalToolCalls] or more times
  /// consecutively within [turnId].
  LoopDetection? recordToolCall(
    String turnId,
    String sessionId,
    String toolName,
    Map<String, dynamic> args,
  ) {
    if (!_config.enabled || _config.maxConsecutiveIdenticalToolCalls <= 0) {
      return null;
    }

    final fingerprint = _computeFingerprint(toolName, args);
    final current = _consecutiveToolCalls[turnId];

    if (current != null && current.fingerprint == fingerprint) {
      final newCount = current.count + 1;
      _consecutiveToolCalls[turnId] = (fingerprint: fingerprint, count: newCount);
      if (newCount >= _config.maxConsecutiveIdenticalToolCalls) {
        return LoopDetection(
          mechanism: LoopMechanism.toolFingerprint,
          sessionId: sessionId,
          message: 'Tool "$toolName" called $newCount consecutive times '
              'with identical arguments '
              '(threshold: ${_config.maxConsecutiveIdenticalToolCalls})',
          detail: {
            'toolName': toolName,
            'consecutiveCount': newCount,
            'threshold': _config.maxConsecutiveIdenticalToolCalls,
          },
        );
      }
    } else {
      _consecutiveToolCalls[turnId] = (fingerprint: fingerprint, count: 1);
    }
    return null;
  }

  /// Cleans up per-turn tracking state for [turnId].
  ///
  /// Must be called in the `finally` block of turn execution to prevent leaks.
  void cleanupTurn(String turnId) {
    _consecutiveToolCalls.remove(turnId);
  }

  /// Cleans up all per-session tracking state for [sessionId].
  void cleanupSession(String sessionId) {
    _turnChainDepth.remove(sessionId);
    _tokenVelocityWindow.remove(sessionId);
  }

  /// Resets all internal state.
  void reset() {
    _turnChainDepth.clear();
    _tokenVelocityWindow.clear();
    _consecutiveToolCalls.clear();
  }

  // ── Internal helpers ──

  /// Computes a deterministic fingerprint for a tool call.
  ///
  /// Uses canonical JSON encoding (sorted keys) to ensure identical args
  /// produce the same fingerprint regardless of map insertion order.
  static String _computeFingerprint(String toolName, Map<String, dynamic> args) {
    final canonical = _canonicalJson(args);
    return '$toolName:$canonical';
  }

  /// Produces a canonical JSON string with keys sorted lexicographically.
  static String _canonicalJson(dynamic value) {
    if (value is Map<String, dynamic>) {
      final sorted = SplayTreeMap<String, dynamic>.from(value);
      final entries = sorted.entries
          .map((e) => '"${_escapeJson(e.key)}":${_canonicalJson(e.value)}');
      return '{${entries.join(',')}}';
    }
    if (value is List) {
      return '[${value.map(_canonicalJson).join(',')}]';
    }
    if (value is String) {
      return '"${_escapeJson(value)}"';
    }
    if (value == null) return 'null';
    return value.toString(); // int, double, bool
  }

  static String _escapeJson(String s) =>
      s.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
}
