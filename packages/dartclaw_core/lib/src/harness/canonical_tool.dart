/// Provider-agnostic tool categories used by the harness and guard pipeline.
///
/// Each variant exposes a stable string [stableName] for guard evaluation,
/// audit logging, and configuration. Provider-specific adapters map raw tool
/// names to these canonical categories before policy evaluation.
///
/// See ADR-016 Part 1 for the canonical taxonomy decision.
enum CanonicalTool {
  /// Shell or command execution.
  shell('shell'),

  /// File read operations.
  fileRead('file_read'),

  /// File write or create operations.
  fileWrite('file_write'),

  /// File edit or modify operations.
  fileEdit('file_edit'),

  /// Web or HTTP fetch operations.
  webFetch('web_fetch'),

  /// Web search operations.
  webSearch('web_search'),

  /// Curated personal-memory writes.
  memoryApply('memory_apply'),

  /// Non-authoritative memory capture.
  memoryObserve('memory_observe'),

  /// Memory and knowledge search.
  memorySearch('memory_search'),

  /// Bounded memory and knowledge read.
  memoryRead('memory_read'),

  /// Create a new logical-agent session.
  sessionsSpawn('sessions_spawn'),

  /// Continue an existing logical-agent session.
  sessionsSend('sessions_send'),

  /// MCP tool calls routed through an MCP server.
  mcpCall('mcp_call');

  /// Stable string name used across providers.
  final String stableName;

  new(this.stableName);

  /// Returns the canonical tool for [name], or `null` when it is unknown.
  static CanonicalTool? fromName(String name) {
    for (final tool in values) {
      if (tool.stableName == name) {
        return tool;
      }
    }
    return null;
  }
}

/// MCP server name used by DartClaw's built-in tool surface.
const dartclawMcpServerName = 'dartclaw';
