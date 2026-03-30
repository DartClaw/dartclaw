import '../agents/agent_definition.dart';
import 'history_config.dart';

/// Configuration for the agent subsystem.
class AgentConfig {
  final String provider;
  final String? model;
  final String? effort;
  final int? maxTurns;
  final List<String> disallowedTools;
  final List<AgentDefinition> definitions;
  final HistoryConfig history;

  const AgentConfig({
    this.provider = 'claude',
    this.model,
    this.effort,
    this.maxTurns,
    this.disallowedTools = const [],
    this.definitions = const [],
    this.history = const HistoryConfig.defaults(),
  });

  /// Default configuration.
  const AgentConfig.defaults() : this();
}
