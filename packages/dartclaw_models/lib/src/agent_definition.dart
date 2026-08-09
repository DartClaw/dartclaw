import 'package:collection/collection.dart';

/// Configuration for a logical agent (e.g. search agent).
///
/// Defines the agent's identity, execution provider, prompt, and tool policy.
class AgentDefinition {
  /// Stable agent identifier accepted by the session tools.
  final String id;

  /// Human-readable description exposed in the spawn tool schema.
  final String description;

  /// System prompt used for this agent's turns.
  final String prompt;

  /// Optional harness provider. Null inherits the deployment's primary provider.
  final String? provider;

  /// Optional worker security profile. Null uses the provider or host default.
  final String? securityProfile;

  /// Explicit allowlist of tools available to the agent.
  final Set<String> allowedTools;

  /// Explicit denylist of tools blocked for the agent.
  final Set<String> deniedTools;

  /// Maximum response size returned to the caller in bytes.
  final int maxResponseBytes;

  /// Optional model override for this agent.
  final String? model;

  /// Optional reasoning effort override for this agent.
  final String? effort;

  /// Creates a logical-agent definition.
  const AgentDefinition({
    required this.id,
    required this.description,
    required this.prompt,
    this.provider,
    this.securityProfile,
    this.allowedTools = const {},
    this.deniedTools = const {},
    this.maxResponseBytes = 5 * 1024 * 1024,
    this.model,
    this.effort,
  });

  /// Default search agent with web_search + web_fetch only.
  factory AgentDefinition.searchAgent({
    String prompt = _defaultSearchPrompt,
    int maxResponseBytes = 5 * 1024 * 1024,
    String? model,
  }) {
    return AgentDefinition(
      id: 'search',
      description:
          'Web search agent with restricted tool access. '
          'Can only use web_search and web_fetch.',
      prompt: prompt,
      securityProfile: 'restricted',
      allowedTools: const {'web_search', 'web_fetch'},
      deniedTools: const {},
      maxResponseBytes: maxResponseBytes,
      model: model,
    );
  }

  /// Builds a config entry for `AgentDefinition.fromYaml`.
  factory AgentDefinition.fromYaml(String id, Map<String, dynamic> yaml, List<String> warns) {
    final tools = yaml['tools'];
    final allowedTools = <String>{};
    if (tools is List) {
      allowedTools.addAll(tools.whereType<String>());
    } else if (tools != null) {
      warns.add('Invalid type for agents.$id.tools: "${tools.runtimeType}" — using defaults');
    }

    final denied = yaml['denied_tools'];
    final deniedTools = <String>{};
    if (denied is List) {
      deniedTools.addAll(denied.whereType<String>());
    }

    final resolvedTools = allowedTools.isEmpty && id == 'search' ? const {'web_search', 'web_fetch'} : allowedTools;
    if (resolvedTools.isEmpty && id != 'search') {
      warns.add('Agent "$id" has no tools configured – no sandbox allowlist will be enforced');
    }
    final profile = yaml['security_profile'];
    String? securityProfile;
    if (profile == null) {
      securityProfile = id == 'search' ? 'restricted' : null;
    } else if (profile is String && const {'workspace', 'restricted'}.contains(profile)) {
      securityProfile = profile;
    } else {
      warns.add('Invalid agents.$id.security_profile: "$profile" – using the default');
      securityProfile = id == 'search' ? 'restricted' : null;
    }
    final providerValue = yaml['provider'];
    String? provider;
    if (providerValue is String && providerValue.trim().isNotEmpty) {
      provider = providerValue.trim().toLowerCase();
    } else if (providerValue != null) {
      warns.add('Invalid agents.$id.provider: "$providerValue" – using agent.provider');
    }

    return AgentDefinition(
      id: id,
      description: yaml['description'] as String? ?? 'Agent: $id',
      prompt: yaml['prompt'] as String? ?? (id == 'search' ? _defaultSearchPrompt : ''),
      allowedTools: resolvedTools,
      deniedTools: deniedTools,
      maxResponseBytes: yaml['max_response_bytes'] as int? ?? 5 * 1024 * 1024,
      model: yaml['model'] as String?,
      effort: yaml['effort'] as String?,
      provider: provider,
      securityProfile: securityProfile,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentDefinition &&
          id == other.id &&
          description == other.description &&
          prompt == other.prompt &&
          provider == other.provider &&
          securityProfile == other.securityProfile &&
          const SetEquality<String>().equals(allowedTools, other.allowedTools) &&
          const SetEquality<String>().equals(deniedTools, other.deniedTools) &&
          maxResponseBytes == other.maxResponseBytes &&
          model == other.model &&
          effort == other.effort;

  @override
  int get hashCode => Object.hash(
    id,
    description,
    prompt,
    provider,
    securityProfile,
    const SetEquality<String>().hash(allowedTools),
    const SetEquality<String>().hash(deniedTools),
    maxResponseBytes,
    model,
    effort,
  );

  static const _defaultSearchPrompt =
      'You are a web search assistant. Search the web for information and '
      'return well-structured, factual answers with source attribution. '
      'Summarize content concisely. Never fabricate sources or URLs.';
}
