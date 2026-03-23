import '../agents/agent_definition.dart';

/// Configuration for the agent subsystem.
class AgentConfig {
  final String provider;
  final String? model;
  final String? effort;
  final int? maxTurns;
  final List<String> disallowedTools;
  final List<AgentDefinition> definitions;

  const AgentConfig({
    this.provider = 'claude',
    this.model,
    this.effort,
    this.maxTurns,
    this.disallowedTools = const [],
    this.definitions = const [],
  });

  /// Default configuration.
  const AgentConfig.defaults() : this();
}
