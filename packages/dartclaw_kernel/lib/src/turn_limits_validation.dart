import 'duration_parser.dart';

/// Parsed turn-limit durations or one field-specific validation error.
typedef TurnLimitsValidation = ({
  Duration? stallTimeout,
  Duration? turnTimeout,
  String? errorField,
  String? errorMessage,
});

/// Parses both turn-limit values and enforces their enabled ordering relation.
TurnLimitsValidation validateTurnLimitDurations({
  required Object? stallTimeout,
  required Object? turnTimeout,
  required Duration fallbackStallTimeout,
  required Duration fallbackTurnTimeout,
}) {
  final parsedStallTimeout = stallTimeout == null ? fallbackStallTimeout : tryParseDuration(stallTimeout);
  if (parsedStallTimeout == null || parsedStallTimeout < Duration.zero) {
    return (
      stallTimeout: null,
      turnTimeout: null,
      errorField: 'governance.turn_limits.stall_timeout',
      errorMessage: 'governance.turn_limits.stall_timeout must be a non-negative duration.',
    );
  }

  final parsedTurnTimeout = turnTimeout == null ? fallbackTurnTimeout : tryParseDuration(turnTimeout);
  if (parsedTurnTimeout == null || parsedTurnTimeout < Duration.zero) {
    return (
      stallTimeout: null,
      turnTimeout: null,
      errorField: 'governance.turn_limits.turn_timeout',
      errorMessage: 'governance.turn_limits.turn_timeout must be a non-negative duration.',
    );
  }

  if (parsedStallTimeout > Duration.zero &&
      parsedTurnTimeout > Duration.zero &&
      parsedStallTimeout >= parsedTurnTimeout) {
    return (
      stallTimeout: null,
      turnTimeout: null,
      errorField: 'governance.turn_limits.stall_timeout',
      errorMessage:
          'governance.turn_limits.stall_timeout must be less than governance.turn_limits.turn_timeout when both '
          'limits are enabled.',
    );
  }

  return (stallTimeout: parsedStallTimeout, turnTimeout: parsedTurnTimeout, errorField: null, errorMessage: null);
}
