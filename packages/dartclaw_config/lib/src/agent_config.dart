import 'package:collection/collection.dart';
import 'package:dartclaw_models/dartclaw_models.dart' show AgentDefinition, ExecutionMode;

import 'history_config.dart';

/// Configuration for the agent subsystem.
class AgentConfig {
  /// provider.
  final String provider;

  /// model.
  final String? model;

  /// effort.
  final String? effort;

  /// maxTurns.
  final int? maxTurns;

  /// Explicit execution mode for the primary agent, inherited by logical agents
  /// without their own setting. Null uses the deployment default.
  final ExecutionMode? execution;

  /// disallowedTools.
  final List<String> disallowedTools;

  /// definitions.
  final List<AgentDefinition> definitions;

  /// history.
  final HistoryConfig history;

  /// Creates a [AgentConfig] value.
  const AgentConfig({
    this.provider = 'claude',
    this.model,
    this.effort,
    this.maxTurns,
    this.execution,
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
          execution == other.execution &&
          const ListEquality<String>().equals(disallowedTools, other.disallowedTools) &&
          const ListEquality<AgentDefinition>().equals(definitions, other.definitions) &&
          history == other.history;

  @override
  int get hashCode => Object.hash(
    provider,
    model,
    effort,
    maxTurns,
    execution,
    const ListEquality<String>().hash(disallowedTools),
    const ListEquality<AgentDefinition>().hash(definitions),
    history,
  );
}
