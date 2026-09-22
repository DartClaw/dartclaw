import 'package:dartclaw_core/dartclaw_core.dart' show CanonicalTool, ToolPolicyCascade;
import 'package:dartclaw_kernel/dartclaw_kernel.dart';

/// Resolves whether a named agent's configured tool policy grants
/// personal-memory access.
final class ManagedMemoryPolicy {
  /// Resolves memory access through the configured tool-policy cascade.
  new(DartclawConfig config)
    : _cascade = ToolPolicyCascade(
        globalDeny: config.agent.disallowedTools.toSet(),
        agentDeny: {
          for (final definition in config.agent.definitions)
            if (definition.deniedTools.isNotEmpty) definition.id: definition.deniedTools,
        },
        agentAllow: {
          for (final definition in config.agent.definitions)
            if (definition.allowedTools.isNotEmpty) definition.id: definition.allowedTools,
        },
      );

  final ToolPolicyCascade _cascade;

  /// Whether the resolved policy grants personal-memory retrieval.
  bool allowsRead(AgentDefinition definition) => _allowsAny(definition, _readTools);

  /// Whether the resolved policy grants personal-memory mutation.
  bool allowsWrite(AgentDefinition definition) => _allowsAny(definition, _writeTools);

  /// Whether the resolved policy grants any personal-memory operation.
  bool allowsCorpus(AgentDefinition definition) => allowsRead(definition) || allowsWrite(definition);

  bool _allowsAny(AgentDefinition definition, Set<String> tools) =>
      tools.any((tool) => _cascade.isAllowed(definition.id, tool));

  static final _readTools = {
    CanonicalTool.memorySearch.stableName,
    CanonicalTool.memoryRead.stableName,
    CanonicalTool.contextResearch.stableName,
  };

  static final _writeTools = {CanonicalTool.memoryApply.stableName, CanonicalTool.memoryObserve.stableName};
}
