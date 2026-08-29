import 'package:collection/collection.dart';

import 'execution_policy.dart';
import 'output_schema.dart';

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
  ///
  /// Describes container posture only; it never selects host or container
  /// placement. See [execution].
  final String? securityProfile;

  /// Whether [securityProfile] was configured by the operator for this agent
  /// rather than supplied as a built-in default.
  ///
  /// A host execution mode the agent inherits may drop a default profile, but
  /// never a configured one — that combination is rejected as contradictory.
  final bool profileIsOperatorConfigured;

  /// Optional explicit execution mode. Null inherits the primary agent's mode.
  final ExecutionMode? execution;

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

  /// Optional deep-closed output schema the agent's result must conform to.
  ///
  /// Null leaves the agent's output unconstrained. When set, it is the enforced
  /// form produced by [parseOutputSchema] — every object level already carries
  /// `additionalProperties: false` — and a result that does not conform fails
  /// the turn rather than being repaired or truncated.
  final Map<String, dynamic>? outputSchema;

  /// Creates a logical-agent definition.
  const new({
    required this.id,
    required this.description,
    required this.prompt,
    this.provider,
    this.securityProfile,
    this.profileIsOperatorConfigured = false,
    this.execution,
    this.allowedTools = const {},
    this.deniedTools = const {},
    this.maxResponseBytes = 5 * 1024 * 1024,
    this.model,
    this.effort,
    this.outputSchema,
  });

  /// Default search agent with web_search + web_fetch only.
  factory searchAgent({String prompt = _defaultSearchPrompt, int maxResponseBytes = 5 * 1024 * 1024, String? model}) {
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
  factory fromYaml(String id, Map<String, dynamic> yaml, List<String> warns) {
    const removedKeys = {
      'max_spawn_depth': 'nested logical-agent execution is bounded by shared worker capacity',
      'max_children_per_agent': 'nested logical-agent execution is bounded by shared worker capacity',
      'max_concurrent': 'configure worker capacity with providers.<id>.pool_size',
      'session_store_path': 'logical-agent session storage is host-owned',
    };
    for (final entry in removedKeys.entries) {
      if (yaml.containsKey(entry.key)) {
        warns.add('Ignoring removed agent.agents.$id.${entry.key}; ${entry.value}.');
      }
    }

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
    final defaultProfile = id == 'search' ? 'restricted' : null;
    String? securityProfile;
    var profileIsOperatorConfigured = false;
    if (profile == null) {
      securityProfile = defaultProfile;
    } else if (profile is String && const {'workspace', 'restricted'}.contains(profile)) {
      securityProfile = profile;
      profileIsOperatorConfigured = true;
    } else {
      warns.add('Invalid agents.$id.security_profile: "$profile" – using the default');
      securityProfile = defaultProfile;
    }

    final execution = _parseExecutionMode(yaml['execution'], 'agent.agents.$id.execution');
    if (execution == ExecutionMode.host && profileIsOperatorConfigured) {
      throw FormatException(
        'agent.agents.$id.execution: host contradicts agent.agents.$id.security_profile: "$securityProfile". '
        'Container profiles are valid only for container execution — remove the profile or select '
        'execution: container.',
      );
    }
    final outputSchema = yaml.containsKey('output_schema')
        ? parseOutputSchema(yaml['output_schema'], yamlPath: 'agent.agents.$id.output_schema')
        : null;

    final providerValue = yaml['provider'];
    String? provider;
    if (providerValue is String) {
      final normalizedProvider = providerValue.trim().toLowerCase();
      if (normalizedProvider.isEmpty) {
        throw FormatException('agents.$id.provider must not be blank');
      }
      provider = normalizedProvider;
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
      profileIsOperatorConfigured: profileIsOperatorConfigured,
      execution: execution,
      outputSchema: outputSchema,
    );
  }

  /// System prompt actually sent to the worker, including the output contract.
  ///
  /// Equals [prompt] when no [outputSchema] is declared. With one, the rendered
  /// contract is appended — or is the whole persona when [prompt] is blank.
  String get personaPrompt {
    final schema = outputSchema;
    if (schema == null) return prompt;
    final contract = renderOutputSchemaContract(schema);
    return prompt.trim().isEmpty ? contract : '$prompt\n\n$contract';
  }

  /// Parses an `execution:` scalar at [yamlPath], rejecting unknown values.
  ///
  /// Returns `null` when the key is absent. Throws [FormatException] naming
  /// [yamlPath] and the accepted values otherwise.
  static ExecutionMode? parseExecutionMode(Object? value, String yamlPath) => _parseExecutionMode(value, yamlPath);

  static ExecutionMode? _parseExecutionMode(Object? value, String yamlPath) {
    if (value == null) return null;
    final mode = value is String ? ExecutionMode.fromYaml(value) : null;
    if (mode == null) {
      throw FormatException(
        '$yamlPath: "$value" is not a valid execution mode. '
        'Accepted values: ${ExecutionMode.acceptedYamlValues.join(', ')}.',
      );
    }
    return mode;
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
          profileIsOperatorConfigured == other.profileIsOperatorConfigured &&
          execution == other.execution &&
          const SetEquality<String>().equals(allowedTools, other.allowedTools) &&
          const SetEquality<String>().equals(deniedTools, other.deniedTools) &&
          maxResponseBytes == other.maxResponseBytes &&
          model == other.model &&
          effort == other.effort &&
          const DeepCollectionEquality().equals(outputSchema, other.outputSchema);

  @override
  int get hashCode => Object.hash(
    id,
    description,
    prompt,
    provider,
    securityProfile,
    profileIsOperatorConfigured,
    execution,
    const SetEquality<String>().hash(allowedTools),
    const SetEquality<String>().hash(deniedTools),
    maxResponseBytes,
    model,
    effort,
    const DeepCollectionEquality().hash(outputSchema),
  );

  static const _defaultSearchPrompt =
      'You are a web search assistant. Search the web for information and '
      'return well-structured, factual answers with source attribution. '
      'Summarize content concisely. Never fabricate sources or URLs.';
}
