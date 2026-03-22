/// The mechanism that triggered loop detection.
enum LoopMechanism {
  /// Consecutive agent-initiated turns exceeded the threshold.
  turnChainDepth,

  /// Token consumption velocity in the rolling window exceeded the threshold.
  tokenVelocity,

  /// Repeated identical tool calls within a single turn exceeded the threshold.
  toolFingerprint,
}

/// Result from a loop detection check.
class LoopDetection {
  /// The mechanism that identified the loop.
  final LoopMechanism mechanism;

  /// Session where the loop was detected.
  final String sessionId;

  /// Human-readable detection message suitable for logging and user display.
  final String message;

  /// Additional detection details (thresholds, counts).
  final Map<String, dynamic> detail;

  const LoopDetection({
    required this.mechanism,
    required this.sessionId,
    required this.message,
    this.detail = const {},
  });

  @override
  String toString() => 'LoopDetection($mechanism, session: $sessionId)';
}

/// Thrown when loop detection aborts a turn reservation.
///
/// Caught by [TaskExecutor] to transition the associated task to `failed`.
class LoopDetectedException implements Exception {
  /// Human-readable detection message.
  final String message;

  /// The underlying detection result.
  final LoopDetection detection;

  const LoopDetectedException(this.message, this.detection);

  @override
  String toString() => 'LoopDetectedException: $message';
}
