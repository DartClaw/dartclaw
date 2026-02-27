/// Configuration for SDK options forwarded in the initialize handshake.
class HarnessConfig {
  final List<String> disallowedTools;
  final int? maxTurns;
  final String? model;
  final Map<String, dynamic>? agents;
  final bool context1m;

  const HarnessConfig({
    this.disallowedTools = const [],
    this.maxTurns,
    this.model,
    this.agents,
    this.context1m = false,
  });

  /// Returns non-null fields as map entries for the initialize handshake.
  Map<String, dynamic> toInitializeFields() {
    return {
      if (disallowedTools.isNotEmpty) 'disallowedTools': disallowedTools,
      if (maxTurns != null) 'maxTurns': maxTurns,
      if (model != null) 'model': model,
      if (agents != null) 'agents': agents,
      if (context1m) 'context1m': true,
    };
  }
}
