part of 'codex_cli_provider.dart';

final class _CodexSandboxDecision {
  static const _rankBySandbox = <String, int>{'read-only': 0, 'workspace-write': 1, 'danger-full-access': 2};

  final String? sandbox;
  final bool hasExplicitSandbox;

  factory _CodexSandboxDecision({String? defaultSandbox, String? sandboxOverride}) {
    final normalizedDefault = _normalize(defaultSandbox);
    final normalizedOverride = _normalize(sandboxOverride);
    final resolvedSandbox = _resolve(normalizedDefault, normalizedOverride);
    assert(
      normalizedDefault == null ||
          normalizedOverride == null ||
          resolvedSandbox == _stricter(normalizedDefault, normalizedOverride),
      'Codex sandbox resolution must preserve the stricter authored sandbox value.',
    );
    return _CodexSandboxDecision._(resolvedSandbox);
  }

  const _CodexSandboxDecision._(this.sandbox) : hasExplicitSandbox = sandbox != null;

  static String? _normalize(String? raw) {
    if (raw == null) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static String? _resolve(String? defaultSandbox, String? sandboxOverride) {
    if (sandboxOverride == null) return defaultSandbox;
    if (defaultSandbox == null) return sandboxOverride;
    return _stricter(defaultSandbox, sandboxOverride);
  }

  static String _stricter(String left, String right) {
    if (left == right) return left;
    final leftRank = _rankBySandbox[left];
    final rightRank = _rankBySandbox[right];
    if (leftRank == null || rightRank == null) {
      throw StateError(
        'Unsupported Codex sandbox combination: default="$left", override="$right". '
        'Update _CodexSandboxDecision before adding new sandbox names.',
      );
    }
    return leftRank <= rightRank ? left : right;
  }
}
