/// Configuration for SDK options forwarded in the initialize handshake.
class HarnessConfig {
  final List<String> disallowedTools;
  final int? maxTurns;
  final String? model;
  final Map<String, dynamic>? agents;
  final bool context1m;

  /// Content to pass via --append-system-prompt CLI flag at spawn.
  /// Null means no flag (replace-mode harnesses use per-turn JSONL instead).
  final String? appendSystemPrompt;

  /// URL of the internal MCP server (e.g. `http://127.0.0.1:8080/mcp`).
  /// When non-null, the harness writes an `--mcp-config` temp file pointing
  /// the claude binary at this endpoint.
  final String? mcpServerUrl;

  /// Gateway token used for MCP bearer auth.
  /// Written into the `--mcp-config` temp file alongside [mcpServerUrl].
  final String? mcpGatewayToken;

  const HarnessConfig({
    this.disallowedTools = const [],
    this.maxTurns,
    this.model,
    this.agents,
    this.context1m = false,
    this.appendSystemPrompt,
    this.mcpServerUrl,
    this.mcpGatewayToken,
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
