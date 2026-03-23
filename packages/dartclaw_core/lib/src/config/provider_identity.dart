/// Shared provider-family normalization rules.
///
/// Provider IDs encode both vendor identity (`codex` needs OpenAI credentials)
/// and harness mode identity (`codex-exec` vs `codex`). This helper keeps
/// family-level decisions consistent without introducing a heavier abstraction.
class ProviderIdentity {
  static const String claude = 'claude';
  static const String codex = 'codex';
  static const String codexExec = 'codex-exec';

  /// Returns the normalized provider ID, falling back to [fallback].
  static String normalize(String? providerId, {String fallback = claude}) {
    final trimmed = providerId?.trim().toLowerCase();
    if (trimmed == null || trimmed.isEmpty) {
      final normalizedFallback = fallback.trim().toLowerCase();
      return normalizedFallback.isEmpty ? claude : normalizedFallback;
    }
    return trimmed;
  }

  /// Returns the credential/vendor family used by [providerId].
  static String family(String? providerId, {String fallback = claude}) {
    return switch (normalize(providerId, fallback: fallback)) {
      codexExec => codex,
      final normalized => normalized,
    };
  }

  /// Returns a human-readable label for [providerId].
  static String displayName(String? providerId, {String fallback = claude}) {
    return switch (family(providerId, fallback: fallback)) {
      claude => 'Claude',
      codex => 'Codex',
      final normalized => _titleCaseWords(normalized),
    };
  }

  static String _titleCaseWords(String value) {
    return value
        .split(RegExp(r'[_\-\s]+'))
        .where((segment) => segment.isNotEmpty)
        .map((segment) {
          final lower = segment.toLowerCase();
          return '${lower[0].toUpperCase()}${lower.substring(1)}';
        })
        .join(' ');
  }
}
