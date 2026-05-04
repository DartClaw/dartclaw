/// Shared provider-family normalization rules.
///
/// Provider IDs encode vendor identity (`codex` needs OpenAI credentials).
/// This helper keeps family-level decisions consistent without introducing
/// a heavier abstraction.
class ProviderIdentity {
  static const String claude = 'claude';
  static const String codex = 'codex';

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
    return normalize(providerId, fallback: fallback);
  }

  /// Returns a human-readable label for [providerId].
  static String displayName(String? providerId, {String fallback = claude}) {
    return switch (family(providerId, fallback: fallback)) {
      claude => 'Claude',
      codex => 'Codex',
      final normalized => _titleCaseWords(normalized),
    };
  }

  /// Parses a `provider/model` shorthand such as `claude/opus` or
  /// `codex/gpt-5.4`.
  ///
  /// Returns `null` when [value] is not in shorthand form or when the
  /// provider prefix is not a known provider family.
  static ({String provider, String model})? parseProviderModelShorthand(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }

    final slashIndex = trimmed.indexOf('/');
    if (slashIndex <= 0 || slashIndex == trimmed.length - 1) {
      return null;
    }
    if (trimmed.indexOf('/', slashIndex + 1) != -1) {
      return null;
    }

    final providerPart = trimmed.substring(0, slashIndex).trim().toLowerCase();
    final modelPart = trimmed.substring(slashIndex + 1).trim();
    if (modelPart.isEmpty) {
      return null;
    }
    if (providerPart != claude && providerPart != codex) {
      return null;
    }

    return (provider: providerPart, model: modelPart);
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
