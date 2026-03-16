/// Configuration for SDK options forwarded in the initialize handshake.
class HarnessConfig {
  /// Tools that the runtime must refuse even if the model requests them.
  final List<String> disallowedTools;

  /// Optional hard cap on the number of turns the runtime may take.
  final int? maxTurns;

  /// Optional model override for spawned turns.
  ///
  /// Supports bare names (`opus`, `sonnet`, `haiku`) and context-window
  /// suffixes (`opus[1m]`). When null, the harness falls back to `opus[1m]`.
  final String? model;

  /// Optional reasoning effort level (`low`, `medium`, `high`, `max`).
  final String? effort;

  /// Optional sub-agent configuration forwarded during initialization.
  final Map<String, dynamic>? agents;

  /// Content to pass via --append-system-prompt CLI flag at spawn.
  /// Null means no flag (replace-mode harnesses use per-turn JSONL instead).
  final String? appendSystemPrompt;

  /// URL of the internal MCP server (e.g. `http://127.0.0.1:8080/mcp`).
  ///
  /// When non-null, the harness writes an ephemeral `--mcp-config` temp file
  /// pointing the `claude` binary at this endpoint. The temp file:
  /// - Uses `chmod 600` (owner read/write only) for credential protection
  /// - Is created in the system temp directory (NOT the workspace)
  /// - Is automatically deleted when the harness stops or is disposed
  ///
  /// The agent then discovers all tools registered on the MCP server
  /// (memory, sessions, web_fetch, search, custom) via the standard
  /// MCP `tools/list` protocol — no manual configuration needed.
  ///
  /// When null, the harness falls back to `sdkMcpServers` in the
  /// initialize handshake for memory tools (chat mode without MCP server).
  ///
  /// **Security**: Never write MCP credentials to persistent files in the
  /// workspace directory — bearer tokens would be exposed in potentially
  /// version-controlled directories.
  final String? mcpServerUrl;

  /// Gateway token used for MCP bearer auth.
  ///
  /// Written into the ephemeral `--mcp-config` temp file as
  /// `Authorization: Bearer <token>`. Only used when [mcpServerUrl] is
  /// non-null. The same token authenticates both the web UI and MCP
  /// endpoint via the gateway middleware.
  final String? mcpGatewayToken;

  /// Creates immutable initialize-handshake options for a harness.
  const HarnessConfig({
    this.disallowedTools = const [],
    this.maxTurns,
    this.model,
    this.effort,
    this.agents,
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
      if (effort != null) 'effort': effort,
      if (agents != null) 'agents': agents,
    };
  }
}
