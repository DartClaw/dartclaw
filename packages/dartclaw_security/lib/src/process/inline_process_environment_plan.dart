import '../safe_process.dart';

/// Value adapter exposing a caller-supplied environment overlay as a
/// [ProcessEnvironmentPlan] for [SafeProcess.git] / [SafeProcess.gitStart].
///
/// Treats `null` as the empty overlay so call sites that lack credential
/// resolution can still satisfy the required `plan` parameter without
/// reinventing a sentinel.
final class InlineProcessEnvironmentPlan implements ProcessEnvironmentPlan {
  /// Constructs an inline plan; `null` collapses to the empty overlay.
  const InlineProcessEnvironmentPlan(Map<String, String>? environment)
    : environment = environment ?? const <String, String>{};

  @override
  final Map<String, String> environment;
}

/// Canonical empty [ProcessEnvironmentPlan] — overlays no environment entries.
///
/// Use as `const EmptyProcessEnvironmentPlan()` for `SafeProcess.git` invocations
/// that need only the sanitized base environment (no credential injection).
final class EmptyProcessEnvironmentPlan implements ProcessEnvironmentPlan {
  /// Singleton-friendly const constructor; reuse `const EmptyProcessEnvironmentPlan()`.
  const EmptyProcessEnvironmentPlan();

  @override
  Map<String, String> get environment => const <String, String>{};
}
