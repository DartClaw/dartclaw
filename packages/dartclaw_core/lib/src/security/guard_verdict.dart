/// Sealed class representing the outcome of a guard evaluation.
sealed class GuardVerdict {
  const GuardVerdict();

  factory GuardVerdict.pass() = _Pass;
  factory GuardVerdict.warn(String message) = _Warn;
  factory GuardVerdict.block(String reason) = _Block;

  bool get isPass => this is _Pass;
  bool get isWarn => this is _Warn;
  bool get isBlock => this is _Block;

  /// Non-null for [warn] and [block]; null for [pass].
  String? get message;
}

final class _Pass extends GuardVerdict {
  const _Pass();

  @override
  String? get message => null;

  @override
  String toString() => 'GuardVerdict.pass()';
}

final class _Warn extends GuardVerdict {
  @override
  final String message;

  const _Warn(this.message);

  @override
  String toString() => 'GuardVerdict.warn($message)';
}

final class _Block extends GuardVerdict {
  @override
  final String message;

  const _Block(this.message);

  @override
  String toString() => 'GuardVerdict.block($message)';
}
