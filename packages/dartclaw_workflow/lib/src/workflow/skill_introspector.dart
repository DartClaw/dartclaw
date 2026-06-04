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

  const WorkflowPreflightException(this.message);

  @override
  String toString() => message;
}

final class WorkflowSkillPreflightConfig {
  final String? defaultProvider;
  final Map<String, String> providerExecutables;
  final Map<String, Map<String, dynamic>> providerOptions;
  final Set<String> configuredProviders;

  const WorkflowSkillPreflightConfig({
    this.defaultProvider,
    this.providerExecutables = const <String, String>{},
    this.providerOptions = const <String, Map<String, dynamic>>{},
    this.configuredProviders = const <String>{},
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
