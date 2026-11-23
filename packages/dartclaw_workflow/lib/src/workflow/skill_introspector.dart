const skillIntrospectionPrompt = 'List all available skills. Respond only with a list of skill names, one per line.';

/// Runtime probe for provider-visible skill references.
abstract interface class SkillIntrospector {
  Future<Set<String>> listAvailable({
    required String provider,
    String? executable,
    Map<String, dynamic> providerOptions = const <String, dynamic>{},
  });
}

final class WorkflowPreflightException implements Exception {
  final String message;

  const new(this.message);

  @override
  String toString() => message;
}

final class WorkflowSkillPreflightConfig {
  final String? defaultProvider;
  final Map<String, String> providerExecutables;
  final Map<String, Map<String, dynamic>> providerOptions;
  final Set<String> configuredProviders;

  /// The skills a workflow step can activate when steps run in containers, or
  /// `null` when they run on the host.
  ///
  /// When set, preflight checks refs against this set instead of probing the
  /// host provider: a container never carries the operator's plugins, so a host
  /// probe would pass refs the step cannot activate.
  final Set<String>? containerVisibleSkills;

  const new({
    this.defaultProvider,
    this.providerExecutables = const <String, String>{},
    this.providerOptions = const <String, Map<String, dynamic>>{},
    this.configuredProviders = const <String>{},
    this.containerVisibleSkills,
  });

  String? executableFor(String provider) => providerExecutables[provider];

  Map<String, dynamic> optionsFor(String provider) => providerOptions[provider] ?? const <String, dynamic>{};

  bool isProviderConfigured(String provider) {
    final normalized = provider.trim();
    if (normalized.isEmpty) return false;
    final configured = configuredProviders.isEmpty
        ? {
            if (defaultProvider != null && defaultProvider!.trim().isNotEmpty) defaultProvider!.trim(),
            ...providerExecutables.keys,
          }
        : configuredProviders;
    return configured.contains(normalized);
  }
}
