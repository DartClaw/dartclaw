/// Sealed class representing the outcome of a guard evaluation.
sealed class GuardVerdict {
  const GuardVerdict();

  factory GuardVerdict.pass() = GuardPass;
  factory GuardVerdict.warn(String message) = GuardWarn;
  factory GuardVerdict.block(String reason) = GuardBlock;

  bool get isPass => this is GuardPass;
  bool get isWarn => this is GuardWarn;
  bool get isBlock => this is GuardBlock;

  /// Non-null for [warn] and [block]; null for [pass].
  String? get message;
}

final class GuardPass extends GuardVerdict {
  const GuardPass();

  @override
  String? get message => null;

  @override
  String toString() => 'GuardVerdict.pass()';
}

final class GuardWarn extends GuardVerdict {
  @override
  final String message;

  const GuardWarn(this.message);

  @override
  String toString() => 'GuardVerdict.warn($message)';
}

final class GuardBlock extends GuardVerdict {
  @override
  final String message;

  const GuardBlock(this.message);

  @override
  String toString() => 'GuardVerdict.block($message)';
}
