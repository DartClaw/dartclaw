import 'package:collection/collection.dart';

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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentConfig &&
          provider == other.provider &&
          model == other.model &&
          effort == other.effort &&
          maxTurns == other.maxTurns &&
          const ListEquality<String>().equals(disallowedTools, other.disallowedTools) &&
          const ListEquality<AgentDefinition>().equals(definitions, other.definitions) &&
          history == other.history;

  @override
  int get hashCode => Object.hash(
    provider,
    model,
    effort,
    maxTurns,
    const ListEquality<String>().hash(disallowedTools),
    const ListEquality<AgentDefinition>().hash(definitions),
    history,
  );
}
