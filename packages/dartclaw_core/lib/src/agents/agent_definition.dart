/// Configuration for a sub-agent (e.g. search agent).
///
/// Defines the agent's identity, tool sandbox, spawn limits, and session
/// isolation. Serializes to the `agents` field in the initialize handshake.
class AgentDefinition {
  /// Stable agent identifier referenced by delegation tools.
  final String id;

  /// Human-readable description provided to the runtime.
  final String description;

  /// System prompt used when the agent is spawned.
  final String prompt;

  /// Explicit allowlist of tools available to the agent.
  final Set<String> allowedTools;

  /// Explicit denylist of tools blocked for the agent.
  final Set<String> deniedTools;

  /// Maximum nesting depth at which this agent may spawn children.
  final int maxSpawnDepth;

  /// Maximum number of concurrent sessions for this agent.
  final int maxConcurrent;

  /// Maximum number of direct children this agent may own.
  final int maxChildrenPerAgent;

  /// Relative session-store path used by the runtime.
  final String sessionStorePath;

  /// Maximum response size returned to the caller in bytes.
  final int maxResponseBytes;

  /// Optional model override for this agent.
  final String? model;

  /// Optional reasoning effort override for this agent.
  final String? effort;

  /// Extra initialize payload fields preserved from configuration.
  final Map<String, dynamic> extra;

  /// Creates a sub-agent definition.
  const AgentDefinition({
    required this.id,
    required this.description,
    required this.prompt,
    this.allowedTools = const {},
    this.deniedTools = const {},
    this.maxSpawnDepth = 0,
    this.maxConcurrent = 1,
    this.maxChildrenPerAgent = 0,
    this.sessionStorePath = '',
    this.maxResponseBytes = 5 * 1024 * 1024,
    this.model,
    this.effort,
    this.extra = const {},
  });

  /// Default search agent with web_search + web_fetch only.
  factory AgentDefinition.searchAgent({
    String prompt = _defaultSearchPrompt,
    int maxConcurrent = 2,
    int maxResponseBytes = 5 * 1024 * 1024,
    String model = 'haiku',
  }) {
    return AgentDefinition(
      id: 'search',
      description:
          'Web search agent with restricted tool access. '
          'Can only use web_search and web_fetch.',
      prompt: prompt,
      allowedTools: const {'WebSearch', 'WebFetch'},
      deniedTools: const {},
      maxSpawnDepth: 0,
      maxConcurrent: maxConcurrent,
      maxChildrenPerAgent: 0,
      sessionStorePath: 'agents/search/sessions',
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

    final resolvedTools = allowedTools.isEmpty && id == 'search' ? const {'WebSearch', 'WebFetch'} : allowedTools;
    if (resolvedTools.isEmpty && id != 'search') {
      warns.add('Agent "$id" has no tools configured — it will not be able to use any tools');
    }
    return AgentDefinition(
      id: id,
      description: yaml['description'] as String? ?? 'Agent: $id',
      prompt: yaml['prompt'] as String? ?? _defaultSearchPrompt,
      allowedTools: resolvedTools,
      deniedTools: deniedTools,
      maxSpawnDepth: yaml['max_spawn_depth'] as int? ?? 0,
      maxConcurrent: yaml['max_concurrent'] as int? ?? 1,
      maxChildrenPerAgent: yaml['max_children_per_agent'] as int? ?? 0,
      sessionStorePath: yaml['session_store_path'] as String? ?? 'agents/$id/sessions',
      maxResponseBytes: yaml['max_response_bytes'] as int? ?? 5 * 1024 * 1024,
      model: yaml['model'] as String?,
      effort: yaml['effort'] as String?,
      extra: _extractExtra(yaml),
    );
  }

  /// Serializes to the claude binary's `agents` initialize handshake format.
  Map<String, dynamic> toInitializePayload() {
    return {
      'description': description,
      'prompt': prompt,
      if (model != null) 'model': model,
      if (effort != null) 'effort': effort,
      if (deniedTools.isNotEmpty) 'disallowedTools': deniedTools.toList(),
      ...extra,
    };
  }

  static Map<String, dynamic> _extractExtra(Map<String, dynamic> yaml) {
    const reserved = {
      'tools',
      'denied_tools',
      'description',
      'prompt',
      'model',
      'effort',
      'max_spawn_depth',
      'max_concurrent',
      'max_children_per_agent',
      'session_store_path',
      'max_response_bytes',
    };
    final extra = <String, dynamic>{};
    for (final entry in yaml.entries) {
      if (!reserved.contains(entry.key)) {
        extra[entry.key] = entry.value;
      }
    }
    return extra;
  }

  static const _defaultSearchPrompt =
      'You are a web search assistant. Search the web for information and '
      'return well-structured, factual answers with source attribution. '
      'Summarize content concisely. Never fabricate sources or URLs.';
}
