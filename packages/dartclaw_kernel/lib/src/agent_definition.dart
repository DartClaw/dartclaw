import 'dart:io';

import 'package:collection/collection.dart';
import 'package:path/path.dart' as p;

import 'execution_policy.dart';
import 'output_schema.dart';
import 'task_legacy_compatibility.dart';

/// An operator-configured execution home for one named agent.
///
/// The agent id is the sole source of [storagePrincipal]. The configured path
/// supplies execution context only and can never redefine that identity.
final class AgentWorkspace {
  /// Creates a trusted canonical workspace binding.
  const new({required this.agentId, required this.directory});

  /// The stable configured agent id that owns this workspace.
  final String agentId;

  /// The canonical absolute workspace directory.
  final String directory;

  /// The storage identity consumed by workspace-scoped services.
  String get storagePrincipal => 'agent:$agentId';

  /// Reconstructs a trusted binding pinned in session metadata.
  static AgentWorkspace pinned({required String agentId, required String directory}) {
    if (agentId.trim().isEmpty) throw const FormatException('Pinned workspace agent id must not be blank');
    if (!p.isAbsolute(directory)) throw FormatException('Pinned workspace path must be absolute: $directory');
    return AgentWorkspace(agentId: agentId, directory: p.normalize(directory));
  }

  /// Resolves and validates one explicit operator-configured workspace path.
  static AgentWorkspace configured({
    required String agentId,
    required String configuredPath,
    required String dataDir,
    required String ownerWorkspaceDir,
  }) {
    final trimmed = configuredPath.trim();
    if (trimmed.isEmpty) {
      throw FormatException('agent.agents.$agentId.workspace must not be blank');
    }
    final absolute = p.normalize(p.isAbsolute(trimmed) ? trimmed : p.join(dataDir, trimmed));
    final lexicalType = FileSystemEntity.typeSync(absolute, followLinks: false);
    if (lexicalType == FileSystemEntityType.notFound) {
      throw FormatException('agent.agents.$agentId.workspace does not exist: $configuredPath');
    }
    if (lexicalType != FileSystemEntityType.directory && lexicalType != FileSystemEntityType.link) {
      throw FormatException('agent.agents.$agentId.workspace is not a directory: $configuredPath');
    }

    final String canonical;
    try {
      canonical = p.normalize(Directory(absolute).resolveSymbolicLinksSync());
      Directory(canonical).listSync(followLinks: false);
    } on FileSystemException catch (error) {
      throw FormatException('agent.agents.$agentId.workspace is unreadable: $configuredPath (${error.message})');
    }
    if (!p.equals(absolute, canonical)) {
      throw FormatException(
        'agent.agents.$agentId.workspace uses a symlink alias: $configuredPath resolves to $canonical',
      );
    }

    final canonicalDataDir = _canonicalExistingDirectory(dataDir);
    final canonicalOwner = _canonicalExistingDirectory(ownerWorkspaceDir);
    if (!p.isAbsolute(trimmed) && !p.isWithin(canonicalDataDir, canonical)) {
      throw FormatException(
        'agent.agents.$agentId.workspace relative path must stay beneath the instance data directory: '
        '$configuredPath resolves to $canonical',
      );
    }
    if (p.equals(canonical, canonicalDataDir)) {
      throw FormatException('agent.agents.$agentId.workspace must not equal the instance data directory: $canonical');
    }
    if (_pathsOverlap(canonical, canonicalOwner)) {
      throw FormatException('agent.agents.$agentId.workspace overlaps the owner workspace: $canonical');
    }
    return AgentWorkspace(agentId: agentId, directory: canonical);
  }

  /// Rejects duplicate or nested agent workspaces after all entries parse.
  static void validateDistinct(Iterable<AgentWorkspace> workspaces) {
    final seen = <AgentWorkspace>[];
    for (final workspace in workspaces) {
      for (final other in seen) {
        if (_pathsOverlap(workspace.directory, other.directory)) {
          throw FormatException(
            'agent.agents.${workspace.agentId}.workspace overlaps agent "${other.agentId}" workspace: '
            '${workspace.directory} overlaps ${other.directory}',
          );
        }
      }
      seen.add(workspace);
    }
  }

  /// Refuses a changed, removed, or newly-added binding for an existing session.
  static void requireCurrent({
    required String sessionId,
    required String agentId,
    required AgentWorkspace? pinned,
    required AgentWorkspace? configured,
  }) {
    if (pinned == configured) return;
    throw StateError(
      'Session "$sessionId" no longer matches agent "$agentId" workspace configuration. '
      'Create a new conversation to use the current workspace.',
    );
  }

  static String _canonicalExistingDirectory(String path) {
    final absolute = p.normalize(p.absolute(path));
    try {
      return p.normalize(Directory(absolute).resolveSymbolicLinksSync());
    } on FileSystemException {
      return absolute;
    }
  }

  static bool _pathsOverlap(String left, String right) =>
      p.equals(left, right) || p.isWithin(left, right) || p.isWithin(right, left);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentWorkspace && agentId == other.agentId && p.equals(directory, other.directory);

  @override
  int get hashCode => Object.hash(agentId, p.hash(directory));
}

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

  /// Explicit execution workspace, or null when this agent keeps its existing
  /// no-workspace boundary.
  final AgentWorkspace? workspace;

  /// The preflight error that keeps an explicitly configured workspace unavailable.
  final String? workspaceConfigurationError;

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
    this.workspace,
    this.workspaceConfigurationError,
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
  factory fromYaml(
    String id,
    Map<String, dynamic> yaml,
    List<String> warns, {
    String? dataDir,
    String? ownerWorkspaceDir,
  }) {
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
    } else if (profile is String && containerSecurityProfiles.contains(profile)) {
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

    AgentWorkspace? workspace;
    String? workspaceConfigurationError;
    if (yaml.containsKey('workspace')) {
      final workspaceValue = yaml['workspace'];
      if (id == 'main') {
        workspaceConfigurationError =
            'agent.agents.main.workspace cannot bind the reserved owner identity "main"; remove this workspace key';
      } else if (workspaceValue is! String) {
        workspaceConfigurationError = 'agent.agents.$id.workspace must be a string path: $workspaceValue';
      } else {
        if (dataDir == null || ownerWorkspaceDir == null) {
          throw StateError('Workspace parsing requires the resolved instance data directory');
        }
        try {
          workspace = AgentWorkspace.configured(
            agentId: id,
            configuredPath: workspaceValue,
            dataDir: dataDir,
            ownerWorkspaceDir: ownerWorkspaceDir,
          );
        } on FormatException catch (error) {
          workspaceConfigurationError = error.message;
        }
      }
      if (workspaceConfigurationError != null) warns.add(workspaceConfigurationError);
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
      workspace: workspace,
      workspaceConfigurationError: workspaceConfigurationError,
    );
  }

  /// Returns this definition with its explicit workspace kept unavailable.
  AgentDefinition withWorkspaceConfigurationError(String error) => AgentDefinition(
    id: id,
    description: description,
    prompt: prompt,
    allowedTools: allowedTools,
    deniedTools: deniedTools,
    maxResponseBytes: maxResponseBytes,
    provider: provider,
    securityProfile: securityProfile,
    profileIsOperatorConfigured: profileIsOperatorConfigured,
    execution: execution,
    model: model,
    effort: effort,
    outputSchema: outputSchema,
    workspaceConfigurationError: error,
  );

  /// Refuses execution for an explicitly configured workspace that failed preflight.
  void requireWorkspaceAvailable() {
    final error = workspaceConfigurationError;
    if (error != null) throw StateError('$error. Fix this binding before using agent "$id".');
  }

  /// The explicit configured prompt with its output contract appended.
  ///
  /// Equals [prompt] when no [outputSchema] is declared. With one, the rendered
  /// contract is appended — or is the whole value when [prompt] is blank.
  /// Runtime workspace composition consumes [prompt] and [outputSchema]
  /// separately so a blank prompt can retain workspace `SOUL.md`.
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
          const DeepCollectionEquality().equals(outputSchema, other.outputSchema) &&
          workspace == other.workspace &&
          workspaceConfigurationError == other.workspaceConfigurationError;

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
    workspace,
    workspaceConfigurationError,
  );

  static const _defaultSearchPrompt =
      'You are a web search assistant. Search the web for information and '
      'return well-structured, factual answers with source attribution. '
      'Summarize content concisely. Never fabricate sources or URLs.';
}
