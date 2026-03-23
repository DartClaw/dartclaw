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

  /// MCP tool calls routed through an MCP server.
  mcpCall('mcp_call');

  /// Stable string name used across providers.
  final String stableName;

  const CanonicalTool(this.stableName);

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
