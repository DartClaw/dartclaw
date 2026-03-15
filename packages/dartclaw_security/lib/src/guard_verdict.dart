/// Sealed class representing the outcome of a guard evaluation.
sealed class GuardVerdict {
  const GuardVerdict();

  /// Creates a successful guard verdict.
  factory GuardVerdict.pass() = GuardPass;

  /// Creates a warning verdict that allows execution to continue.
  factory GuardVerdict.warn(String message) = GuardWarn;

  /// Creates a blocking verdict that denies execution.
  factory GuardVerdict.block(String reason) = GuardBlock;

  /// Whether this verdict is a [GuardPass].
  bool get isPass => this is GuardPass;

  /// Whether this verdict is a [GuardWarn].
  bool get isWarn => this is GuardWarn;

  /// Whether this verdict is a [GuardBlock].
  bool get isBlock => this is GuardBlock;

  /// Explanatory message for warning/block verdicts, or `null` for pass.
  String? get message;
}

/// Successful guard verdict with no explanatory message.
final class GuardPass extends GuardVerdict {
  const GuardPass();

  @override
  String? get message => null;

  @override
  String toString() => 'GuardVerdict.pass()';
}

/// Non-blocking guard verdict with an explanatory message.
final class GuardWarn extends GuardVerdict {
  @override
  /// Warning message returned by the guard.
  final String message;

  const GuardWarn(this.message);

  @override
  String toString() => 'GuardVerdict.warn($message)';
}

/// Blocking guard verdict with an explanatory message.
final class GuardBlock extends GuardVerdict {
  @override
  /// Block reason returned by the guard.
  final String message;

  const GuardBlock(this.message);

  @override
  String toString() => 'GuardVerdict.block($message)';
}
